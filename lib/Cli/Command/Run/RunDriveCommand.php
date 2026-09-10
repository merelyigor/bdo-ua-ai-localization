<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Api\IdempotencyKey;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Command\Api\GlossaryConceptsCommand;
use Bdo\Translate\Cli\Command\Api\ValidateCommand;
use Bdo\Translate\Cli\Command\Api\TermNotesDescribeCommand;
use Bdo\Translate\Cli\Command\Api\TermNotesSubmitCommand;
use Bdo\Translate\Cli\Command\Api\TermNotesQueueCommand;
use Bdo\Translate\Cli\Command\Batch\BatchCleanCommand;
use Bdo\Translate\Cli\Command\Batch\BatchCommitCommand;
use Bdo\Translate\Cli\Command\Batch\SubsetRowsCommand;
use Bdo\Translate\Cli\Command\Prepare\BuildSchemaCommand;
use Bdo\Translate\Cli\Command\Prepare\JudgePayloadCommand;
use Bdo\Translate\Cli\Command\Prepare\MemoryApplyCommand;
use Bdo\Translate\Cli\Command\Prepare\MemoryExpandCommand;
use Bdo\Translate\Cli\Command\Prepare\MemoryLookupCommand;
use Bdo\Translate\Cli\Command\Prepare\NamesPayloadCommand;
use Bdo\Translate\Cli\Command\Prepare\QaPayloadCommand;
use Bdo\Translate\Cli\Command\Prepare\TerminologyPayloadCommand;
use Bdo\Translate\Cli\Command\Prepare\WorkerPayloadCommand;
use Bdo\Translate\Cli\Command\Quality\BuildItemsCommand;
use Bdo\Translate\Cli\Command\Quality\CheckRussianismsCommand;
use Bdo\Translate\Cli\Command\Quality\MechanicalSplitCommand;
use Bdo\Translate\Cli\Command\Quality\MergeItemsCommand;
use Bdo\Translate\Cli\Command\Quality\NormalizeCandidateCommand;
use Bdo\Translate\Cli\Command\Quality\QaCoverageFillCommand;
use Bdo\Translate\Cli\Command\Heal\HealPlanCommand;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Http\Client;
use Bdo\Translate\Http\Request;
use Bdo\Translate\Payload\Chunks;
use Bdo\Translate\Payload\Items;
use Bdo\Translate\Payload\TermIndex;
use Bdo\Translate\Pipeline\JudgeDecisions;
use Bdo\Translate\Pipeline\RunSpec;
use Bdo\Translate\Quality\VerdictSet;
use Bdo\Translate\Run\StepTimes;
use RuntimeException;

/** One deterministic state-machine step for the current batch. */
final class RunDriveCommand implements Command
{
    // ПРАВИЛО: child roles і timed steps мають одне live PHP source of truth.
    // САБОТАЖ: роль поза allowlist або subprocess у цьому класі має валити gate.
    private const ROLES = [
        'translation-terminology', 'translation-worker', 'translation-qa',
        'translation-repair', 'translation-judge', 'translation-names',
    ];

    private const TIMED_STEPS = ['validate.early', 'validate.final', 'commit'];

    private string $root;
    private string $stateDir;
    private ?Workspace $workspace = null;
    /** @var resource|null */
    private $lock = null;

    /** @return list<string> */
    public static function roles(): array
    {
        return self::ROLES;
    }

    /** @return list<string> */
    public static function timedSteps(): array
    {
        return self::TIMED_STEPS;
    }

    public function execute(array $arguments, Output $output): int
    {
        $this->root = dirname(__DIR__, 4);
        $this->stateDir = getenv('BDO_STATE_DIR') ?: $this->root.'/state';
        $this->workspace = Workspace::current($this->stateDir);
        if ($this->workspace === null) {
            $this->json($output, ['ok' => false, 'state' => 'no_batch', 'next' => ['kind' => 'blocked', 'reason' => 'no_current_batch'], 'hint' => 'пачки немає; почни її: ./bdo mode start <mode> <N 20-100> [patch]']);

            return 1;
        }

        $state = (string) ($this->workspace->manifest()['state'] ?? '');
        if (! $this->acquireLock($output, $state)) {
            return 75;
        }
        try {
            @unlink($this->stateDir.'/next-child.json');
            return $this->dispatch($state, $output);
        } finally {
            $this->releaseLock();
        }
    }

    private function dispatch(string $state, Output $output): int
    {
        return match ($state) {
            'selected' => $this->selected($output),
            'awaiting_terminology' => $this->awaitingTerminology($output),
            'awaiting_worker' => $this->awaitingWorker($output),
            'candidate_valid' => is_file($this->workspace->path('candidate.json')) && filesize($this->workspace->path('candidate.json')) > 0
                ? $this->candidateToQa($output)
                : $this->blocked($output, 'candidate_valid', 'candidate_missing'),
            'deterministic_valid' => is_file($this->workspace->path('clean.json')) && filesize($this->workspace->path('clean.json')) > 0
                ? $this->dispatchQa($output)
                : $this->blocked($output, 'deterministic_valid', 'clean_candidate_missing'),
            'awaiting_qa' => $this->awaitingQa($output),
            'healing' => $this->healing($output),
            'awaiting_control_qa' => $this->awaitingControlQa($output),
            'awaiting_judge' => $this->awaitingJudge($output),
            'ready_to_commit', 'committing' => $this->commit($state, $output),
            'names_pass' => $this->namesPass($output),
            'verified' => $this->verified($output),
            default => $this->blocked($output, $state, $state),
        };
    }

    private function selected(Output $output): int
    {
        $manifest = $this->manifest();
        $termPayload = $this->stateDir.'/term-notes-payload.json';
        $termResponse = $this->stateDir.'/term-notes-response.json';
        if (is_file($termPayload) && ! is_file($termResponse)) {
            @unlink($termPayload);
        }
        if (getenv('BDO_TERM_NOTES_AUTO') !== 'off' && getenv('BDO_PIPELINE_OFFLINE') !== '1') {
            $queue = $this->stateDir.'/term-notes-queue.json';
            if (is_file($termResponse) && filesize($termResponse) > 0) {
                try {
                    ApiEnvironment::load($this->root);
                    $submit = $this->capture(new TermNotesSubmitCommand(), []);
                    $output->stderr($submit['stdout'].$submit['stderr']);
                } catch (\Throwable) {
                    // Term-note submission is an optional side effect; the batch remains runnable.
                }
            } elseif (is_file($queue)) {
                $ready = $this->eligibleTermNotes($queue, $this->stateDir.'/proposed-term-notes.json');
                if ($ready >= (int) (getenv('BDO_TERM_NOTES_MIN_QUEUE') ?: 5)) {
                    $capture = $this->optionalCapture(new TermNotesDescribeCommand(), []);
                    if ($capture['code'] === 0 && str_contains($capture['stdout'], '"kind":"child"')) {
                        $output->stdout($capture['stdout']);
                        return 0;
                    }
                }
            }
        }

        $layers = (string) ($manifest['memory_layers'] ?? '');
        if ($layers === '' && ($manifest['mode'] ?? '') === 'improve') {
            $layers = 'manual';
        }
        if (getenv('BDO_MEMORY_LAYERS') === false && $layers !== '') {
            putenv('BDO_MEMORY_LAYERS='.$layers);
        }
        $rowsPath = $this->workspace->path('rows.json');
        if (getenv('BDO_PIPELINE_OFFLINE') !== '1') {
            try { $this->capture(new MemoryLookupCommand(), [$rowsPath]); }
            catch (\Throwable) { /* memory is an optional enrichment, as in rollback */ }
        }
        $memoryPath = $this->workspace->path('memory.json');
        if (is_file($memoryPath) && filesize($memoryPath) > 0) {
            $this->optionalCapture(new MemoryApplyCommand(), [$rowsPath, $memoryPath]);
        }
        $rows = is_file($this->workspace->path('to-translate.json'))
            ? $this->jsonRows($this->workspace->path('to-translate.json'))
            : $this->jsonRows($rowsPath);
        $selectedRows = $this->workspace->path('to-translate.json');
        if ($rows === 0 || ! is_file($selectedRows)) {
            $selectedRows = $rowsPath;
        }

        $termProposals = $this->workspace->path('term-proposals.json');
        if (getenv('BDO_PIPELINE_OFFLINE') !== '1' && (! is_file($termProposals) || filesize($termProposals) === 0)) {
            $gaps = $this->termGaps($selectedRows);
            if ($gaps > 0) {
                $terms = $this->optionalCapture(new TerminologyPayloadCommand(), [$selectedRows]);
                if ($terms['code'] === 0) {
                    $this->write($this->workspace->path('terminology-payload.full.json'), $this->lastJson($terms['stdout'])."\n");
                    if (Items::count($this->workspace->path('terminology-payload.full.json')) > 0) {
                        file_put_contents($this->workspace->path('terminology-answers.json'), "[]\n");
                        file_put_contents($this->workspace->path('terminology-chunk'), "0\n");
                        if ($this->termChunkWrite(0) > 0) {
                            $this->transition('awaiting_terminology');
                            return $this->child($output, 'awaiting_terminology', 'translation-terminology', $this->workspace->path('terminology-payload.json'), $this->workspace->path('term-proposals.json'));
                        }
                    }
                }
            }
        }

        return $this->prepareWorker($output);
    }

    private function prepareWorker(Output $output): int
    {
        $rowsPath = $this->workspace->path('rows.json');
        $selected = $rowsPath;
        $count = $this->jsonRows($rowsPath);
        $toTranslate = $this->workspace->path('to-translate.json');
        if (is_file($toTranslate)) {
            $candidateCount = $this->jsonRows($toTranslate);
            $count = $candidateCount;
            if ($candidateCount > 0) {
                $selected = $toTranslate;
            }
        }
        $payload = $this->workspace->path('worker-payload.json');
        if ($count > 0) {
            $this->call(new BuildSchemaCommand(), [$selected]);
            $args = [$selected];
            if (($this->manifest()['mode'] ?? '') === 'improve') {
                $args[] = '--with-current';
                $args[] = '--with-reference';
            }
            if (getenv('BDO_PIPELINE_OFFLINE') === '1') {
                $args[] = '--no-context';
            }
            if (getenv('BDO_PIPELINE_OFFLINE') !== '1') {
                $this->optionalCapture(new GlossaryConceptsCommand(), []);
            }
            $result = $this->capture(new WorkerPayloadCommand(), $args);
            if ($result['code'] !== 0) {
                return $this->emit($output, false, (string) $this->manifest()['state'], ['kind' => 'retry', 'reason' => 'context_unavailable', 'hint' => 'Контекст пачки недоступний.']);
            }
            $this->write($payload.'.new', $this->lastJson($result['stdout'])."\n");
            rename($payload.'.new', $payload);
            if (is_file($this->workspace->path('terms.json'))) {
                $this->optionalCapture(new TermNotesQueueCommand(), [$this->workspace->path('terms.json'), $selected]);
            }
        } else {
            $this->write($payload, "[]\n");
            if (is_file($this->workspace->path('memory-candidate.json'))) {
                copy($this->workspace->path('memory-candidate.json'), $this->workspace->path('candidate.json'));
            }
        }
        $this->complete('prepared', $payload);
        $this->transition('prepared');
        $this->transition('awaiting_worker');
        if ($count === 0) {
            return $this->emit($output, true, 'awaiting_worker', ['kind' => 'continue', 'reason' => 'memory_covered_all_rows']);
        }

        return $this->child($output, 'awaiting_worker', 'translation-worker', $payload, $this->workspace->path('candidate.json'));
    }

    private function awaitingTerminology(Output $output): int
    {
        $chunk = $this->intFile($this->workspace->path('terminology-chunk'));
        $total = is_file($this->workspace->path('terminology-payload.full.json')) ? Chunks::count($this->workspace->path('terminology-payload.full.json')) : 0;
        if (! is_file($this->workspace->path('term-proposals.json')) || filesize($this->workspace->path('term-proposals.json')) === 0) {
            $retry = $this->retryExceeded('awaiting_terminology:'.$chunk, $output);
            if ($retry === null) return 1;
            if ($retry !== 'exhausted') return $this->child($output, 'awaiting_terminology', 'translation-terminology', $this->workspace->path('terminology-payload.json'), $this->workspace->path('term-proposals.json'));
            file_put_contents($this->workspace->path('terminology-chunk'), ($chunk + 1)."\n");
        } else {
            $proposalFile = $this->workspace->path('term-proposals.json');
            $valid = false;
            try {
                $decoded = json_decode((string) file_get_contents($proposalFile), true, 512, JSON_THROW_ON_ERROR);
                $valid = is_array($decoded);
            } catch (\Throwable) {
                $valid = false;
            }
            if (! $valid) {
                @rename($proposalFile, $this->workspace->path('term-proposals.invalid.'.time().'.json'));
                $retry = $this->retryExceeded('awaiting_terminology:'.$chunk, $output);
                if ($retry === null) return 1;
                if ($retry !== 'exhausted') return $this->child($output, 'awaiting_terminology', 'translation-terminology', $this->workspace->path('terminology-payload.json'), $proposalFile);
                $this->write($this->workspace->path('terminology-chunk'), ($chunk + 1)."\n");
            } else {
                try { Chunks::append($proposalFile, $this->workspace->path('terminology-answers.json')); }
                catch (\Throwable) { /* legacy non-gating merge */ }
                @unlink($proposalFile);
                $this->write($this->workspace->path('terminology-chunk'), ($chunk + 1)."\n");
            }
        }
        $next = $this->intFile($this->workspace->path('terminology-chunk'));
        if ($next < $total && $this->termChunkWrite($next) > 0) {
            return $this->emit($output, true, 'awaiting_terminology', ['kind' => 'continue', 'reason' => "terminology_chunk_{$next}_of_{$total}"]);
        }
        if (is_file($this->workspace->path('terminology-answers.json'))) {
            copy($this->workspace->path('terminology-answers.json'), $this->workspace->path('term-proposals.json'));
        } else {
            $this->write($this->workspace->path('term-proposals.json'), "[]\n");
        }
        try {
            $proposals = Items::fromFile($this->workspace->path('term-proposals.json'));
            $indexed = TermIndex::attachIdentity($proposals, TermIndex::forRows(RowSet::fromFile($this->workspace->path('rows.json'))));
            $this->write($this->workspace->path('term-proposals.json'), json_encode($indexed, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR)."\n");
        } catch (\Throwable) {
            // Identity enrichment is legacy non-gating telemetry; preserve proposals on failure.
        }
        $this->complete('terminology', $this->workspace->path('term-proposals.json'));

        return $this->prepareWorker($output);
    }

    private function awaitingWorker(Output $output): int
    {
        $candidate = $this->workspace->path('candidate.json');
        $memoryCandidate = $this->workspace->path('memory-candidate.json');
        $toTranslate = $this->workspace->path('to-translate.json');
        if (is_file($toTranslate) && $this->jsonRows($toTranslate) === 0 && is_file($memoryCandidate) && filesize($memoryCandidate) > 0) {
            copy($memoryCandidate, $candidate);
        }
        if (! is_file($candidate) || filesize($candidate) === 0) {
            $retry = $this->retryExceeded('awaiting_worker', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') return $this->giveUp($output, 'awaiting_worker');
            $this->ensureSchema('rows');
            return $this->child($output, 'awaiting_worker', 'translation-worker', $this->workspace->path('worker-payload.json'), $candidate);
        }
        $rows = is_file($this->workspace->path('to-translate.json')) && $this->jsonRows($this->workspace->path('to-translate.json')) > 0 ? $this->workspace->path('to-translate.json') : $this->workspace->path('rows.json');
        try { $this->call(new BuildItemsCommand(), [$rows, $candidate, $this->workspace->path('model-items.json'), '', '--require-all']); }
        catch (\Throwable) {
            $invalid = $this->workspace->path('candidate.invalid.'.time().'.json');
            @rename($candidate, $invalid);
            $retry = $this->retryExceeded('awaiting_worker', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') return $this->giveUp($output, 'awaiting_worker');
            $this->ensureSchema('rows');
            return $this->child($output, 'awaiting_worker', 'translation-worker', $this->workspace->path('worker-payload.json'), $candidate);
        }
        $this->complete('worker', $candidate);
        $this->transition('candidate_valid');

        return $this->candidateToQa($output);
    }

    private function candidateToQa(Output $output): int
    {
        $modelRows = is_file($this->workspace->path('to-translate.json')) && $this->jsonRows($this->workspace->path('to-translate.json')) > 0 ? $this->workspace->path('to-translate.json') : $this->workspace->path('rows.json');
        if (is_file($this->workspace->path('twins.json')) && is_file($this->workspace->path('memory-candidate.json'))) {
            $expanded = $this->capture(new MemoryExpandCommand(), [$this->workspace->path('candidate.json'), $this->workspace->path('twins.json'), $this->workspace->path('memory-candidate.json')]);
            $this->write($this->workspace->path('full.json'), $this->lastJson($expanded['stdout'])."\n");
        } else {
            copy($this->workspace->path('candidate.json'), $this->workspace->path('full.json'));
        }
        $normalized = $this->capture(new NormalizeCandidateCommand(), [$this->workspace->path('full.json'), $this->workspace->path('rows.json')]);
        $this->write($this->workspace->path('clean.json'), $this->lastJson($normalized['stdout'])."\n");
        $this->call(new BuildItemsCommand(), [$this->workspace->path('rows.json'), $this->workspace->path('clean.json'), $this->workspace->path('items.json'), '', '--require-all']);
        $this->optionalCapture(new CheckRussianismsCommand(), [$this->workspace->path('clean.json'), $this->workspace->path('rows.json')]);
        if (getenv('BDO_PIPELINE_OFFLINE') !== '1') {
            $validate = new ValidateCommand();
            $this->timedCapture('validate.early', $validate, [$this->workspace->path('items.json')]);
            if ($validate->resultPath() !== null && is_file($validate->resultPath())) {
                $this->write($this->workspace->path('validate-path'), $validate->resultPath()."\n");
            }
        }
        $this->complete('deterministic', $this->workspace->path('clean.json'));
        $this->transition('deterministic_valid');

        return $this->dispatchQa($output);
    }

    private function dispatchQa(Output $output): int
    {
        $args = [$this->workspace->path('rows.json'), $this->workspace->path('clean.json'), $this->workspace->path('pre-verdicts.json'), $this->workspace->path('qa-subset.json')];
        if (is_file($this->workspace->path('memory-candidate.json'))) { $args[] = '--memory'; $args[] = $this->workspace->path('memory-candidate.json'); }
        try { $this->call(new MechanicalSplitCommand(), $args); }
        catch (\Throwable) {
            copy($this->workspace->path('rows.json'), $this->workspace->path('qa-subset.json'));
            $this->write($this->workspace->path('pre-verdicts.json'), "[]\n");
        }
        $cleanRows = $this->jsonRows($this->workspace->path('qa-subset.json'));
        if ($cleanRows === 0) {
            copy($this->workspace->path('pre-verdicts.json'), $this->workspace->path('verdicts.json'));
            $this->transitionOrStay('awaiting_qa');
            $reason = str_contains((string) file_get_contents($this->workspace->path('pre-verdicts.json')), '"status":"REJECT"') ? 'mechanical_only' : 'memory_only';

            return $this->emit($output, true, 'awaiting_qa', ['kind' => 'continue', 'reason' => $reason]);
        }
        $this->call(new BuildSchemaCommand(), ['--qa', $this->workspace->path('qa-subset.json')]);
        $args = [$this->workspace->path('qa-subset.json'), $this->workspace->path('clean.json')];
        if (($this->manifest()['mode'] ?? '') === 'improve') $args[] = '--with-current';
        $qa = $this->capture(new QaPayloadCommand(), $args);
        $this->write($this->workspace->path('qa-payload.json'), $this->lastJson($qa['stdout'])."\n");
        $this->transitionOrStay('awaiting_qa');

        return $this->child($output, 'awaiting_qa', 'translation-qa', $this->workspace->path('qa-payload.json'), $this->workspace->path('verdicts.json'));
    }

    private function awaitingQa(Output $output): int
    {
        $verdicts = $this->workspace->path('verdicts.json');
        if (! is_file($verdicts) || filesize($verdicts) === 0) {
            $retry = $this->retryExceeded('awaiting_qa', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') return $this->giveUp($output, 'awaiting_qa');
        if (! is_file($this->workspace->path('qa-payload.json')) || filesize($this->workspace->path('qa-payload.json')) === 0) return $this->dispatchQa($output);
            $this->ensureSchema('qa');
            return $this->child($output, 'awaiting_qa', 'translation-qa', $this->workspace->path('qa-payload.json'), $verdicts);
        }
        $scope = $this->jsonRows($this->workspace->path('qa-subset.json')) > 0
            ? $this->workspace->path('qa-subset.json')
            : $this->workspace->path('rows.json');
        if (! $this->validQa($verdicts, $scope)) {
            $retry = $this->retryExceeded('awaiting_qa', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') {
                $fill = $this->capture(new QaCoverageFillCommand(), [$scope, $verdicts]);
                if ($fill['code'] !== 0 || ! $this->validQa($verdicts, $scope)) {
                    @rename($verdicts, $this->workspace->path('verdicts.invalid.'.time().'.json'));
                    return $this->giveUp($output, 'awaiting_qa');
                }
            } else {
                @rename($verdicts, $this->workspace->path('verdicts.invalid.'.time().'.json'));
                $this->ensureSchema('qa');
                return $this->child($output, 'awaiting_qa', 'translation-qa', $this->workspace->path('qa-payload.json'), $verdicts);
            }
        }
        $this->mergePreVerdicts($verdicts);
        $this->complete('qa', $verdicts);
        $this->transition('qa_valid');
        $validate = is_file($this->workspace->path('validate-path')) ? trim((string) file_get_contents($this->workspace->path('validate-path'))) : '';
        try { $this->call(new HealPlanCommand(), [$this->workspace->path('rows.json'), $this->workspace->path('clean.json'), $verdicts, $validate]); }
        catch (\Throwable) { /* heal-plan preserves its legacy non-gating behavior */ }
        $repairPath = $this->workspace->path('heal-repair-payload.json');
        if (is_file($repairPath) && Items::count($repairPath) > 0) {
            $this->transition('healing');
            return $this->child($output, 'healing', 'translation-repair', $repairPath, $this->workspace->path('fixes.json'));
        }
        copy($this->workspace->path('heal-merged.json'), $this->workspace->path('final-candidate.json'));
        copy($verdicts, $this->workspace->path('final-verdicts.json'));

        return $this->judgeOrCommit($output);
    }

    private function healing(Output $output): int
    {
        $fixes = $this->workspace->path('fixes.json');
        if (! is_file($fixes) || filesize($fixes) === 0) {
            $retry = $this->retryExceeded('healing', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') return $this->giveUp($output, 'healing');
            return $this->child($output, 'healing', 'translation-repair', $this->workspace->path('heal-repair-payload.json'), $fixes);
        }
        try { $this->call(new MergeItemsCommand(), [$this->workspace->path('heal-merged.json'), $fixes, $this->workspace->path('healed.json')]); }
        catch (\Throwable) {
            @rename($fixes, $this->workspace->path('fixes.invalid.'.time().'.json'));
            $retry = $this->retryExceeded('healing', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') return $this->giveUp($output, 'healing');
            return $this->child($output, 'healing', 'translation-repair', $this->workspace->path('heal-repair-payload.json'), $fixes);
        }
        copy($this->workspace->path('healed.json'), $this->workspace->path('final-candidate.json'));
        copy($this->workspace->path('verdicts.json'), $this->workspace->path('final-verdicts.json'));

        return $this->judgeOrCommit($output);
    }

    private function awaitingControlQa(Output $output): int
    {
        $file = $this->workspace->path('verdicts-control.json');
        if (! is_file($file) || filesize($file) === 0) {
            $retry = $this->retryExceeded('awaiting_control_qa', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') return $this->giveUp($output, 'awaiting_control_qa');
            return $this->child($output, 'awaiting_control_qa', 'translation-qa', $this->workspace->path('control-qa-payload.json'), $file);
        }
        if (! $this->validQa($file, $this->workspace->path('heal-repair-subset.json'))) {
            @rename($file, $this->workspace->path('verdicts-control.invalid.'.time().'.json'));
            $retry = $this->retryExceeded('awaiting_control_qa', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') return $this->giveUp($output, 'awaiting_control_qa');
            return $this->child($output, 'awaiting_control_qa', 'translation-qa', $this->workspace->path('control-qa-payload.json'), $file);
        }
        $a = json_decode((string) file_get_contents($this->workspace->path('verdicts.json')), true, 512, JSON_THROW_ON_ERROR);
        $b = json_decode((string) file_get_contents($file), true, 512, JSON_THROW_ON_ERROR);
        $indexed = [];
        foreach (array_merge(is_array($a) ? $a : [], is_array($b) ? $b : []) as $v) if (is_array($v)) $indexed[(string) ($v['identity_hash'] ?? '')] = $v;
        $this->write($this->workspace->path('final-verdicts.json'), json_encode(array_values($indexed), JSON_UNESCAPED_UNICODE)."\n");
        copy($this->workspace->path('healed.json'), $this->workspace->path('final-candidate.json'));

        return $this->judgeOrCommit($output);
    }

    private function judgeOrCommit(Output $output): int
    {
        if (getenv('BDO_JUDGE') === 'off') {
            $this->transition('ready_to_commit');
            return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'judge_disabled']);
        }
        $validate = is_file($this->workspace->path('validate-path')) ? trim((string) file_get_contents($this->workspace->path('validate-path'))) : '';
        $judge = $this->optionalCapture(new JudgePayloadCommand(), [$this->workspace->path('rows.json'), $this->workspace->path('final-candidate.json'), $this->workspace->path('final-verdicts.json'), $validate]);
        $judgePayload = '[]';
        if ($judge['code'] === 0) {
            try { $judgePayload = $this->lastJson($judge['stdout']); } catch (\Throwable) { $judgePayload = '[]'; }
        }
        $this->write($this->workspace->path('judge-payload.json'), $judgePayload."\n");
        $items = json_decode((string) file_get_contents($this->workspace->path('judge-payload.json')), true) ?: [];
        if (count($items['items'] ?? $items) > 0) {
            $this->transition('awaiting_judge');
            return $this->child($output, 'awaiting_judge', 'translation-judge', $this->workspace->path('judge-payload.json'), $this->workspace->path('judge-verdicts.json'));
        }
        $this->transition('ready_to_commit');

        return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'no_disputed_rows']);
    }

    private function awaitingJudge(Output $output): int
    {
        $file = $this->workspace->path('judge-verdicts.json');
        if (! is_file($file) || filesize($file) === 0) {
            $retry = $this->retryExceeded('awaiting_judge', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') { $this->transition('ready_to_commit'); return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'judge_retry_exhausted']); }
            return $this->child($output, 'awaiting_judge', 'translation-judge', $this->workspace->path('judge-payload.json'), $file);
        }
        try { JudgeDecisions::fromFile($file); }
        catch (\Throwable) {
            @rename($file, $this->workspace->path('judge-verdicts.invalid.'.time().'.json'));
            $retry = $this->retryExceeded('awaiting_judge', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') { $this->transition('ready_to_commit'); return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'judge_answer_invalid']); }
            return $this->child($output, 'awaiting_judge', 'translation-judge', $this->workspace->path('judge-payload.json'), $file);
        }
        $this->complete('judge', $file);
        $this->transition('ready_to_commit');

        return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'judge_done']);
    }

    private function commit(string $state, Output $output): int
    {
        $this->call(new BuildItemsCommand(), [$this->workspace->path('rows.json'), $this->workspace->path('final-candidate.json'), $this->workspace->path('final-items.json'), '', '--require-all']);
        $finalValidate = '';
        if (getenv('BDO_PIPELINE_OFFLINE') !== '1') {
            $validate = new ValidateCommand();
            $this->timedCapture('validate.final', $validate, [$this->workspace->path('final-items.json')]);
            $finalValidate = $validate->resultPath() ?? '';
        }
        if (($stub = getenv('BDO_FINAL_VALIDATE_STUB')) !== false && $stub !== '' && is_file($stub)) $finalValidate = $stub;
        if ($state === 'ready_to_commit' && $finalValidate !== '' && ! is_file($this->workspace->path('names-pass.done')) && getenv('BDO_NAMES_PASS') !== 'off') {
            $names = $this->optionalCapture(new NamesPayloadCommand(), [$this->workspace->path('rows.json'), $this->workspace->path('final-candidate.json'), $finalValidate]);
            $namesPayload = '[]';
            if ($names['code'] === 0) {
                try { $namesPayload = $this->lastJson($names['stdout']); } catch (\Throwable) { $namesPayload = '[]'; }
            }
            $this->write($this->workspace->path('names-payload.json'), $namesPayload."\n");
            if (Items::count($this->workspace->path('names-payload.json')) > 0) {
                $hashes = Items::hashes($this->workspace->path('names-payload.json'));
                $this->call(new SubsetRowsCommand(), [$this->workspace->path('rows.json'), implode(',', $hashes), $this->workspace->path('names-subset.json')]);
                $this->call(new BuildSchemaCommand(), [$this->workspace->path('names-subset.json')]);
                $this->write($this->workspace->path('names-pass.done'), "\n");
                $this->transition('names_pass');
                return $this->child($output, 'names_pass', 'translation-names', $this->workspace->path('names-payload.json'), $this->workspace->path('names-fixes.json'));
            }
        }
        $environment = ApiEnvironment::load($this->root);
        $channel = (string) ($this->manifest()['channel'] ?? 'machine');
        $items = json_decode((string) file_get_contents($this->workspace->path('final-items.json')), true, 512, JSON_THROW_ON_ERROR);
        $key = IdempotencyKey::forBatch(strtoupper($environment['environment'] === 'prod' ? 'PROD' : 'DEV'), $channel, $this->workspace->id(), $items);
        $args = [$this->workspace->path('rows.json'), $this->workspace->path('final-candidate.json'), $this->workspace->path('final-verdicts.json'), '--channel', $channel, '--idempotency-key-prefix', $key];
        if (is_file($this->workspace->path('judge-verdicts.json'))) { $args[] = '--judge'; $args[] = $this->workspace->path('judge-verdicts.json'); }
        if ($finalValidate !== '') { $args[] = '--api-rejected'; $args[] = $finalValidate; }
        if (getenv('BDO_DRY_RUN') !== '1') $args[] = '--write';
        else $output->stderr("ТЕСТОВИЙ ПРОГІН: запису в API не буде (BDO_DRY_RUN=1)\n");
        if ($state === 'ready_to_commit') $this->transition('committing');
        $started = microtime(true);
        $report = $this->capture(new BatchCommitCommand(), $args);
        $this->recordTime('commit', (int) round((microtime(true) - $started) * 1000), $report['code']);
        $this->write($this->workspace->path('commit-report.txt'), $report['stdout'].$report['stderr']);
        if ($report['code'] !== 0) return $this->emit($output, false, 'committing', ['kind' => 'retry', 'reason' => 'api_write_failed']);
        $this->complete('commit', $this->workspace->path('commit-report.txt'));
        $this->transition('committed');
        $this->transition('verified');
        $this->call(new BuildSchemaCommand(), ['--clear']);
        $completion = $this->completion($output);
        if ($completion === null) return 1;
        $this->prune();
        $this->autoClean();

        return $this->emit($output, true, 'verified', $completion);
    }

    private function namesPass(Output $output): int
    {
        $fixes = $this->workspace->path('names-fixes.json');
        if (! is_file($fixes) || filesize($fixes) === 0) {
            $retry = $this->retryExceeded('names_pass', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') { $this->transition('ready_to_commit'); return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'names_pass_retry_exhausted']); }
            $this->call(new BuildSchemaCommand(), [$this->workspace->path('names-subset.json')]);
            return $this->child($output, 'names_pass', 'translation-names', $this->workspace->path('names-payload.json'), $fixes);
        }
        try { $this->call(new MergeItemsCommand(), [$this->workspace->path('final-candidate.json'), $fixes, $this->workspace->path('final-candidate.named.json')]); }
        catch (\Throwable) {
            @rename($fixes, $this->workspace->path('names-fixes.invalid.'.time().'.json'));
            $retry = $this->retryExceeded('names_pass', $output);
            if ($retry === null) return 1;
            if ($retry === 'exhausted') { $this->transition('ready_to_commit'); return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'names_pass_answer_invalid']); }
            $this->call(new BuildSchemaCommand(), [$this->workspace->path('names-subset.json')]);
            return $this->child($output, 'names_pass', 'translation-names', $this->workspace->path('names-payload.json'), $fixes);
        }
        rename($this->workspace->path('final-candidate.named.json'), $this->workspace->path('final-candidate.json'));
        $this->complete('names', $this->workspace->path('final-candidate.json'));
        $this->transition('ready_to_commit');

        return $this->emit($output, true, 'ready_to_commit', ['kind' => 'continue', 'reason' => 'names_fixed']);
    }

    private function verified(Output $output): int
    {
        $completion = $this->completion($output);
        if ($completion === null) return 1;
        $this->prune();
        $this->autoClean();

        return $this->emit($output, true, 'verified', $completion);
    }

    /** @return array<string,mixed>|null */
    private function completion(Output $output): ?array
    {
        $batch = $this->workspace->path('batch-summary.json');
        if (is_file($batch)) {
            $summary = $this->readArray($batch);
            if ($summary === null) return $this->completionError($output, 'batch_summary_unavailable', $batch);
        } else {
            $report = is_file($this->workspace->path('commit-report.txt')) ? (string) file_get_contents($this->workspace->path('commit-report.txt')) : '';
            $summary = [
                'rows' => $this->manifest()['rows'] ?? 0, 'channel' => $this->manifest()['channel'] ?? '',
                'target_written' => $this->number($report, '/Записано: ([0-9]+)/u'), 'target_skipped' => $this->number($report, '/Записано: [0-9]+  Пропущено: ([0-9]+)/u'), 'target_rejected' => $this->number($report, '/Записано: [0-9]+  Пропущено: [0-9]+  Відкинуто: ([0-9]+)/u'),
                'moderation_written' => $this->number($report, '/У МОДЕРАЦІЮ: ([0-9]+)/u'), 'moderation_skipped' => 0, 'moderation_rejected' => 0,
                'quarantine' => $this->number($report, '/у карантин \(збої\): ([0-9]+)/u') + $this->number($report, '/У КАРАНТИН: ([0-9]+)/u'),
            ];
            if (! $this->writeJsonAtomic($batch, $summary)) return $this->completionError($output, 'batch_summary_unavailable', $batch);
        }
        $runFile = $this->stateDir.'/run-summary.json';
        $manifest = $this->manifest();
        $scope = implode(':', [(string) ($manifest['mode'] ?? ''), (string) ($manifest['patch'] ?? ''), (string) ($manifest['channel'] ?? '')]);
        if (is_file($runFile)) {
            $run = $this->readArray($runFile);
            if ($run === null) return $this->completionError($output, 'run_summary_unavailable', $runFile);
        } else {
            $run = [];
        }
        if (($run['scope'] ?? null) !== $scope) $run = ['scope' => $scope, 'batches' => [], 'totals' => []];
        if (! isset($run['batches'][$this->workspace->id()])) {
            $run['batches'][$this->workspace->id()] = $summary;
            foreach (['rows','target_written','target_skipped','target_rejected','moderation_written','moderation_skipped','moderation_rejected','quarantine'] as $key) $run['totals'][$key] = (int) ($run['totals'][$key] ?? 0) + (int) ($summary[$key] ?? 0);
        }
        if (! $this->writeJsonAtomic($runFile, $run)) return $this->completionError($output, 'run_summary_unavailable', $runFile);
        $envelope = ['kind' => 'complete', 'batch' => $summary, 'run' => $run['totals']];
        $goalPath = $this->stateDir.'/run-goal.json';
        if (! is_file($goalPath)) return $envelope;
        $goal = $this->readArray($goalPath);
        if ($goal === null || ! is_string($goal['query'] ?? null) || $goal['query'] === '') return $this->completionError($output, 'run_goal_invalid', $goalPath);
        $remaining = $this->goalRemaining((string) $goal['query']);
        if ($remaining === null) {
            if (getenv('BDO_PIPELINE_OFFLINE') === '1') return $envelope;
            $this->emit($output, false, 'verified', ['kind' => 'retry', 'reason' => 'goal_status_unavailable', 'path' => $goalPath]); return null;
        }
        $excluded = $this->readArray($this->stateDir.'/run-excluded.json') ?? [];
        $waiting = (($excluded['query'] ?? null) === $goal['query']) ? count($excluded['identities'] ?? []) : 0;
        $remaining = max(0, $remaining - $waiting);
        if ($waiting > 0) $envelope['waiting_human'] = $waiting;
        if ($remaining > 0) {
            $envelope['kind'] = 'continue_run'; $envelope['remaining'] = $remaining; $envelope['goal'] = ['mode' => $goal['mode'] ?? '', 'patch' => $goal['patch'] ?? '', 'domain' => $goal['domain'] ?? '']; $envelope['hint'] = "Ціль ще не досягнута: лишилось {$remaining} рядків.";
            return $envelope;
        }
        $patchRemaining = 0;
        if (($goal['domain'] ?? '') !== '') {
            $patchRemaining = $this->patchRemaining((string) ($goal['patch'] ?? '')) ?? -1;
            if ($patchRemaining < 0) { $this->emit($output, false, 'verified', ['kind' => 'retry', 'reason' => 'goal_status_unavailable', 'path' => $goalPath]); return null; }
        }
        if (($goal['domain'] ?? '') !== '' && $patchRemaining > 0) {
            $envelope['kind'] = 'continue_run'; $envelope['remaining'] = $patchRemaining; $envelope['goal'] = ['mode' => $goal['mode'] ?? '', 'patch' => $goal['patch'] ?? '', 'domain' => '']; $envelope['hint'] = sprintf('Категорію %s завершено, але в патчі лишилось %d рядків · далі патчем без категорії.', (string) $goal['domain'], $patchRemaining);
            return $envelope;
        }
        $envelope['kind'] = 'goal_complete'; $envelope['goal'] = ['mode' => $goal['mode'] ?? '', 'patch' => $goal['patch'] ?? '', 'domain' => $goal['domain'] ?? '']; $envelope['hint'] = $waiting > 0 ? "Ціль досягнута для машини: лишилось лише {$waiting} рядків із вичерпаними спробами · вони чекають людину (./bdo quarantine)." : 'Ціль досягнута: рядків за цим фільтром більше немає.';

        return $envelope;
    }

    private function completionError(Output $output, string $reason, string $path): ?array
    {
        $this->emit($output, false, (string) ($this->manifest()['state'] ?? 'verified'), ['kind' => 'blocked', 'reason' => $reason, 'path' => $path]);
        return null;
    }

    private function goalRemaining(string $query): ?int
    {
        if (getenv('BDO_GOAL_REMAINING_STUB') !== false) return is_numeric(getenv('BDO_GOAL_REMAINING_STUB')) ? (int) getenv('BDO_GOAL_REMAINING_STUB') : null;
        if (getenv('BDO_PIPELINE_OFFLINE') === '1') return null;
        return $this->remainingRequest('/rows?'.$query.'&exclude_proposed=1&limit=1&include_total=1&fields=core');
    }

    private function patchRemaining(string $patch): ?int
    {
        if (getenv('BDO_PATCH_REMAINING_STUB') !== false) return is_numeric(getenv('BDO_PATCH_REMAINING_STUB')) ? (int) getenv('BDO_PATCH_REMAINING_STUB') : null;
        if (getenv('BDO_PIPELINE_OFFLINE') === '1') return 0;
        return $this->remainingRequest('/rows?patch='.rawurlencode($patch).'&missing=machine&exclude_proposed=1&limit=1&include_total=1&fields=core');
    }

    private function remainingRequest(string $path): ?int
    {
        try {
            $environment = ApiEnvironment::load($this->root);
            $response = (new Client())->send(new Request('GET', rtrim($environment['base'], '/').$path, ['X-API-Key: '.$environment['key']]), null, true);
            $data = json_decode($response->body, true, 512, JSON_THROW_ON_ERROR);
            return isset($data['meta']['total_matching']) && is_numeric($data['meta']['total_matching']) ? (int) $data['meta']['total_matching'] : null;
        } catch (\Throwable) { return null; }
    }

    private function prune(): void
    {
        foreach (glob($this->workspace->dir().'/*') ?: [] as $path) {
            if (in_array(basename($path), ['manifest.json','journal.jsonl','batch-summary.json','drive.lock'], true)) continue;
            $this->removeTree($path);
        }
        $outputDir = getenv('BDO_STATE_DIR') ? dirname($this->stateDir).'/output' : $this->root.'/output';
        $manifest = $this->workspace->path('manifest.json');
        $manifestTime = is_file($manifest) ? (int) filemtime($manifest) : PHP_INT_MAX;
        foreach (array_merge(glob($outputDir.'/rows_*.json') ?: [], glob($outputDir.'/validate_*.json') ?: []) as $path) {
            if (is_file($path) && (int) filemtime($path) <= $manifestTime) @unlink($path);
        }
    }

    private function autoClean(): void
    {
        if (getenv('BDO_AUTO_CLEAN') === '0') return;
        $this->capture(new BatchCleanCommand(), ['--apply','--quiet','--days',(string) (getenv('BDO_KEEP_DAYS') ?: 7),'--keep',(string) (getenv('BDO_KEEP_RECEIPTS') ?: 50)]);
    }

    private function acquireLock(Output $output, string $state): bool
    {
        $path = $this->workspace->path('drive.lock');
        if (is_link($path)) {
            $owner = readlink($path);
            if ($owner === false || ! preg_match('/^[0-9]+$/', $owner)) return $this->busy($output, $state);
            if (function_exists('posix_kill') && posix_kill((int) $owner, 0)) return $this->busy($output, $state);
            if (! function_exists('posix_kill')) return $this->busy($output, $state);
            if (! @unlink($path)) return $this->busy($output, $state);
        }
        $handle = @fopen($path, 'c+b');
        if ($handle === false || ! @flock($handle, LOCK_EX | LOCK_NB)) {
            if (is_resource($handle)) fclose($handle);
            return $this->busy($output, $state);
        }
        $this->lock = $handle;
        return true;
    }

    private function busy(Output $output, string $state): bool
    {
        $this->emit($output, false, $state, ['kind' => 'retry', 'reason' => 'driver_busy']);
        return false;
    }

    private function releaseLock(): void
    {
        $path = $this->workspace?->path('drive.lock');
        if (is_resource($this->lock)) { @flock($this->lock, LOCK_UN); fclose($this->lock); }
        if (is_string($path) && is_file($path) && ! is_link($path)) @unlink($path);
        $this->lock = null;
    }

    /** @return 'wait'|'exhausted'|null */
    private function retryExceeded(string $key, Output $output): ?string
    {
        $path = $this->workspace->path('drive-retries.json');
        $state = [];
        if (is_file($path)) {
            $state = $this->readArray($path);
            if ($state === null) { $this->emit($output, false, (string) $this->manifest()['state'], ['kind' => 'blocked', 'reason' => 'retry_state_unavailable', 'path' => $path]); return null; }
        }
        $now = time(); $window = max(1, (int) (getenv('BDO_CHILD_RETRY_WINDOW_SECONDS') ?: 600)); $budget = max($window, (int) (getenv('BDO_CHILD_RETRY_TOTAL_SECONDS') ?: 86400));
        $entry = is_array($state[$key] ?? null) ? $state[$key] : [];
        $overall = (int) ($entry['overall_first_at'] ?? 0) ?: $now; $first = (int) ($entry['first_at'] ?? 0) ?: $now; $rollovers = (int) ($entry['window_rollovers'] ?? 0);
        $exhausted = $now - $overall >= $budget;
        if (! $exhausted && $now - $first >= $window) { $first = $now; $rollovers++; }
        $count = (int) ($entry['count'] ?? 0) + 1; $delay = min(60, 2 ** min(6, $count - 1));
        $state[$key] = ['count' => $count, 'first_at' => $first, 'overall_first_at' => $overall, 'window_rollovers' => $rollovers, 'last_at' => $now, 'delay' => $delay];
        if (! $this->writeJsonAtomic($path, $state)) { $this->emit($output, false, (string) $this->manifest()['state'], ['kind' => 'blocked', 'reason' => 'retry_state_unavailable', 'path' => $path]); return null; }
        if ($exhausted) return 'exhausted';
        sleep($delay);
        return 'wait';
    }

    private function giveUp(Output $output, string $state): int
    {
        $path = $this->workspace->path('drive-retries.json'); $data = $this->readArray($path);
        if ($data === null) { $this->emit($output, false, $state, ['kind' => 'blocked', 'reason' => 'retry_state_unavailable', 'path' => $path]); return 1; }
        $entry = is_array($data[$state] ?? null) ? $data[$state] : [];
        @unlink($path);
        return $this->emit($output, false, $state, ['kind' => 'retry', 'reason' => 'child_retry_budget_exhausted', 'attempts' => (int) ($entry['count'] ?? 0), 'windows' => (int) ($entry['window_rollovers'] ?? 0) + 1, 'unavailable_seconds' => max(0, time() - (int) ($entry['overall_first_at'] ?? time()))]);
    }

    private function child(Output $output, string $state, string $role, string $payload, string $response): int
    {
        if (! in_array($role, self::ROLES, true)) throw new RuntimeException('Невідома роль: '.$role);
        $next = ['kind' => 'child', 'role' => $role, 'payload_path' => $payload, 'response_path' => $response, 'prompt' => 'payload:'.$payload];
        $this->write($this->stateDir.'/next-child.json', json_encode($next, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");
        try {
            $items = is_file($payload) ? json_decode((string) file_get_contents($payload), true) : [];
            $this->workspace->recordChild($role, is_array($items) ? count($items['items'] ?? $items) : 0);
        } catch (\Throwable) { /* telemetry is non-gating */ }
        return $this->emit($output, true, $state, $next);
    }

    private function emit(Output $output, bool $ok, string $state, array $next): int
    {
        $this->json($output, ['ok' => $ok, 'state' => $state, 'next' => $next]);
        return $ok ? 0 : 1;
    }

    private function blocked(Output $output, string $state, string $reason): int
    {
        return $this->emit($output, false, $state, ['kind' => 'blocked', 'reason' => $reason]);
    }

    private function transition(string $state): void { $this->workspace->transition($state); }
    private function transitionOrStay(string $state): void { if (($this->manifest()['state'] ?? '') !== $state) $this->transition($state); }
    private function manifest(): array { return $this->workspace->manifest(); }

    private function complete(string $name, string $path): void
    {
        $hash = hash_file('sha256', $path);
        if ($hash === false) throw new RuntimeException('Не вдалося хешувати artifact: '.$path);
        $manifest = $this->manifest();
        if (isset($manifest['steps'][$name])) return;
        $this->workspace->completeStep($name, basename($path), $hash);
    }

    private function ensureSchema(string $kind): void
    {
        $rows = $this->workspace->path('rows.json');
        if ($kind === 'rows' && is_file($this->workspace->path('to-translate.json')) && $this->jsonRows($this->workspace->path('to-translate.json')) > 0) $rows = $this->workspace->path('to-translate.json');
        $this->call(new BuildSchemaCommand(), $kind === 'qa' ? ['--qa', $rows] : [$rows]);
    }

    private function validQa(string $verdicts, string $rows): bool
    {
        try { VerdictSet::fromFile($verdicts)->assertCoverage(RowSet::fromFile($rows)); return true; }
        catch (\Throwable) { return false; }
    }

    private function mergePreVerdicts(string $verdicts): void
    {
        $pre = $this->workspace->path('pre-verdicts.json'); if (! is_file($pre) || filesize($pre) === 0) return;
        $qa = json_decode((string) file_get_contents($verdicts), true) ?: []; $extra = json_decode((string) file_get_contents($pre), true) ?: []; $index = [];
        foreach ($qa as $v) if (is_array($v) && isset($v['identity_hash'])) $index[$v['identity_hash']] = $v;
        foreach ($extra as $v) if (is_array($v) && isset($v['identity_hash'])) $index[$v['identity_hash']] = $v;
        $this->write($verdicts, json_encode(array_values($index), JSON_UNESCAPED_UNICODE)."\n");
    }

    private function termChunkWrite(int $index): int
    {
        return Chunks::write($this->workspace->path('terminology-payload.full.json'), $index, $this->workspace->path('terminology-payload.json'));
    }

    private function eligibleTermNotes(string $queuePath, string $donePath): int
    {
        $queueData = json_decode((string) file_get_contents($queuePath), true) ?: [];
        $doneData = is_file($donePath) ? (json_decode((string) file_get_contents($donePath), true) ?: []) : [];
        $done = is_array($doneData) ? ($doneData['terms'] ?? []) : [];
        $count = 0;
        foreach (is_array($queueData['terms'] ?? null) ? $queueData['terms'] : [] as $term) {
            if (! is_array($term) || ! isset($term['identity_hash'], $term['snapshot_id'])) continue;
            $name = (string) ($term['canonical_source'] ?? '');
            if ($name !== '' && ! in_array($name, $done, true)) $count++;
        }

        return $count;
    }

    private function termGaps(string $rows): int
    {
        $count = 0; foreach (RowSet::fromFile($rows) as $row) $count += count($row->pendingTerms()) + count($row->unresolvedEntities()); return $count;
    }

    private function jsonRows(string $path): int
    {
        if (! is_file($path)) return 0; $data = json_decode((string) file_get_contents($path), true); return is_array($data['data']['rows'] ?? null) ? count($data['data']['rows']) : 0;
    }

    private function intFile(string $path): int { return is_file($path) ? (int) trim((string) file_get_contents($path)) : 0; }
    private function number(string $text, string $pattern): int { return preg_match($pattern, $text, $m) ? (int) ($m[1] ?? 0) : 0; }

    /** @return array<string,mixed>|null */
    private function readArray(string $path): ?array
    {
        if (! is_file($path) || ! is_readable($path)) return null;
        try { $data = json_decode((string) file_get_contents($path), true, 512, JSON_THROW_ON_ERROR); return is_array($data) ? $data : null; }
        catch (\Throwable) { return null; }
    }

    private function write(string $path, string $content): void
    {
        if (file_put_contents($path, $content, LOCK_EX) === false) throw new RuntimeException('Не вдалося записати файл: '.$path);
    }

    private function writeJsonAtomic(string $path, array $data): bool
    {
        $tmp = $path.'.tmp.'.bin2hex(random_bytes(5)); $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR)."\n";
        if (@file_put_contents($tmp, $json, LOCK_EX) === false || ! @rename($tmp, $path)) { @unlink($tmp); return false; }
        return true;
    }

    /** @return array{code:int,stdout:string,stderr:string} */
    private function capture(Command $command, array $arguments): array
    {
        $stdout = tmpfile(); $stderr = tmpfile(); if ($stdout === false || $stderr === false) throw new RuntimeException('Не вдалося відкрити тимчасовий потік.');
        try { $code = $command->execute($arguments, new Output($stdout, $stderr)); rewind($stdout); rewind($stderr); return ['code' => $code, 'stdout' => stream_get_contents($stdout) ?: '', 'stderr' => stream_get_contents($stderr) ?: '']; }
        finally { if (is_resource($stdout)) fclose($stdout); if (is_resource($stderr)) fclose($stderr); }
    }

    private function call(Command $command, array $arguments): void
    {
        $result = $this->capture($command, $arguments); if ($result['code'] !== 0) throw new RuntimeException(trim($result['stderr']) ?: 'Внутрішня команда завершилась із помилкою.');
    }

    /** Optional helper boundaries preserve rollback's non-gating failure semantics. */
    private function optionalCapture(Command $command, array $arguments): array
    {
        try {
            return $this->capture($command, $arguments);
        } catch (\Throwable $error) {
            return ['code' => 1, 'stdout' => '', 'stderr' => $error->getMessage()];
        }
    }

    private function lastJson(string $text): string
    {
        $trimmed = trim($text);
        $decoded = json_decode($trimmed, true);
        if ($decoded !== null) return $trimmed;
        $first = min(array_filter([
            strpos($trimmed, '{'),
            strpos($trimmed, '['),
        ], static fn ($position): bool => $position !== false) ?: [0]);
        $last = max(strrpos($trimmed, '}') ?: 0, strrpos($trimmed, ']') ?: 0);
        if ($last >= $first) {
            $candidate = substr($trimmed, $first, $last - $first + 1);
            if (json_decode($candidate, true) !== null) return $candidate;
        }
        foreach (array_reverse(preg_split('/\R/', trim($text)) ?: []) as $line) { $line = trim($line); if ($line !== '' && in_array($line[0], ['{', '['], true) && json_decode($line, true) !== null) return $line; }
        throw new RuntimeException('Внутрішня команда не повернула JSON artifact.');
    }

    private function timed(string $step, callable $call): int
    {
        $started = microtime(true); $code = 1; try { $code = (int) $call(); } catch (\Throwable) { $code = 1; } finally { $this->recordTime($step, (int) round((microtime(true) - $started) * 1000), $code); }
        return $code;
    }

    /** @return array{code:int,stdout:string,stderr:string} */
    private function timedCapture(string $step, Command $command, array $arguments): array
    {
        $started = microtime(true);
        try {
            $result = $this->capture($command, $arguments);
        } catch (\Throwable $exception) {
            $result = ['code' => 1, 'stdout' => '', 'stderr' => $exception->getMessage()];
        }
        $this->recordTime($step, (int) round((microtime(true) - $started) * 1000), $result['code']);

        return $result;
    }

    private function recordTime(string $step, int $ms, int $code): void
    {
        if (in_array($step, self::TIMED_STEPS, true)) (new StepTimes($this->stateDir))->record($step, $ms, $code, $this->workspace?->id() ?? '');
    }

    private function json(Output $output, array $data): void { $output->stdout(json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n"); }

    private function removeTree(string $path): void
    {
        if (is_link($path) || is_file($path)) { @unlink($path); return; }
        if (is_dir($path)) { foreach (glob($path.'/*') ?: [] as $child) $this->removeTree($child); @rmdir($path); }
    }
}
