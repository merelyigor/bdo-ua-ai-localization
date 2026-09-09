<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Batch;

use Bdo\Translate\Api\Response as ApiResponse;
use Bdo\Translate\Api\TranslationWriter;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Pipeline\ChannelRouter;
use Bdo\Translate\Pipeline\JudgeDecisions;
use Bdo\Translate\Pipeline\JudgePolicy;
use Bdo\Translate\Pipeline\RowAttempts;
use Bdo\Translate\Quality\Defects;
use RuntimeException;

/**
 * Готує результат QA, карантин і, за явним `--write`, викликає TranslationWriter.
 *
 * Старий shell змішував маршрутизацію рядків із кількома `php -r` та викликом
 * іншої shell-команди. Клас зберігає порядок і форму його звіту, але весь
 * фактичний write проходить одним in-process service, тому counts не парсяться
 * з human stdout і жоден shell write не запускається.
 */
final class BatchCommitCommand implements Command
{
    // ПРАВИЛО: commit перевіряє benchmark і blockers до будь-якого write.
    // САБОТАЖ: обхід preflight може дозволити небезпечний або заборонений POST.

    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json');
        $candidateFile = $this->required($arguments, 1, 'Потрібен candidate.json');
        $verdictFile = $this->required($arguments, 2, 'Потрібен verdicts.json від translation-qa');
        foreach ([$rowsFile, $candidateFile, $verdictFile] as $file) {
            if (! is_file($file)) {
                $output->stderr("Немає файлу: {$file}\n");

                return 1;
            }
        }

        $candidateDirectory = realpath(dirname($candidateFile));
        if ($candidateDirectory !== false
            && basename($candidateDirectory) === 'benchmark'
            && basename(dirname($candidateDirectory)) === 'output') {
            $output->stderr("Це файл виміру (output/benchmark/), а не переклад. Записувати його не можна.\n");

            return 1;
        }

        $doWrite = in_array('--write', $arguments, true);
        $namesToModeration = in_array('--names-to-moderation', $arguments, true) ? 1 : 0;
        $channel = 'machine';
        $idempotencyPrefix = '';
        $judgeFile = '';
        $apiRejectedFile = '';
        for ($index = 3, $length = count($arguments); $index < $length; $index++) {
            switch ($arguments[$index]) {
                case '--channel':
                    if (! array_key_exists($index + 1, $arguments) || $arguments[$index + 1] === '') {
                        throw new RuntimeException('machine|manual');
                    }
                    $channel = (string) ($arguments[++$index] ?? '');
                    break;
                case '--idempotency-key-prefix':
                    if (! array_key_exists($index + 1, $arguments) || $arguments[$index + 1] === '') {
                        throw new RuntimeException('потрібен ключ');
                    }
                    $idempotencyPrefix = (string) ($arguments[++$index] ?? '');
                    break;
                case '--judge':
                    if (! array_key_exists($index + 1, $arguments) || $arguments[$index + 1] === '') {
                        throw new RuntimeException('потрібен файл вироків судді');
                    }
                    $judgeFile = (string) ($arguments[++$index] ?? '');
                    break;
                case '--api-rejected':
                    if (! array_key_exists($index + 1, $arguments) || $arguments[$index + 1] === '') {
                        throw new RuntimeException('потрібен файл відповіді validate');
                    }
                    $apiRejectedFile = (string) ($arguments[++$index] ?? '');
                    break;
            }
        }
        if (! in_array($channel, ['machine', 'manual', 'proposal'], true)) {
            $output->stderr('--channel: machine, manual або proposal\n');

            return 1;
        }

        $root = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';
        $this->ensureDirectory($stateDir);
        try {
            $environment = ApiEnvironment::load($root);
            $this->announceTarget($output, $environment);
            $remaining = $this->remainingQuota($environment);
            $runTarget = $this->readFirstLine($stateDir.'/run-target');
            $rows = RowSet::fromFile($rowsFile);
            $candidate = Candidate::fromFile($candidateFile);
            $rawVerdicts = json_decode((string) file_get_contents($verdictFile), true, 512, JSON_THROW_ON_ERROR);
            $verdicts = is_array($rawVerdicts) ? array_values(array_filter($rawVerdicts, 'is_array')) : [];
            $rowByHash = [];
            foreach ($rows->toRawList() as $row) {
                $rowByHash[(string) ($row['identity_hash'] ?? '')] = $row;
            }
            $textByHash = [];
            foreach ($candidate->all() as $hash => $text) {
                $textByHash[$hash] = $text;
            }
            $seen = [];
            foreach ($verdicts as $verdict) {
                $seen[(string) ($verdict['identity_hash'] ?? '')] = $verdict;
            }
            $missing = array_diff(array_keys($rowByHash), array_keys($seen));
            if ($missing !== []) {
                $output->stderr(sprintf(
                    "QA повернула %d вироків на %d рядків · %d без вироку йдуть до людини (REVIEW/minor)\n",
                    count($verdicts), count($rowByHash), count($missing),
                ));
                foreach ($missing as $hash) {
                    $verdicts[] = [
                        'identity_hash' => $hash,
                        'status' => 'REVIEW',
                        'severity' => 'major',
                        'issue' => sprintf('QA не винесла вирок для цього рядка (повернула %d із %d) · дивиться людина', count($seen), count($rowByHash)),
                        'fix' => '',
                    ];
                }
            }

            $judge = JudgeDecisions::fromFile($judgeFile);
            $minConfidence = JudgePolicy::minConfidence(getenv('BDO_JUDGE_MIN_CONFIDENCE') ?: null);
            $apiRejected = $apiRejectedFile !== '' && is_file($apiRejectedFile)
                ? ApiResponse::fromFile($apiRejectedFile)->rejections() : [];
            $pass = [];
            $held = [];
            $moderation = [];
            $counts = ['PASS' => 0, 'REVIEW' => 0, 'REJECT' => 0];
            $unresolvedCount = 0;
            $sameAsSource = 0;
            $mechanicalHeld = 0;
            $mechanicalLog = [];
            $judgeLog = [];
            $judgeCounts = [];

            foreach ($verdicts as $verdict) {
                $hash = (string) ($verdict['identity_hash'] ?? '');
                $status = (string) ($verdict['status'] ?? 'REJECT');
                $counts[$status] = ($counts[$status] ?? 0) + 1;
                $text = $textByHash[$hash] ?? null;
                $row = $rows->getOrEmpty($hash);
                $unresolved = ($channel !== 'machine' && $namesToModeration === 1 && $row->isItemName())
                    ? $row->unresolvedEntities() : [];
                if ($unresolved !== [] && is_string($text) && trim($text) !== '') {
                    $moderation[] = [
                        'identity_hash' => $hash,
                        'source_hash' => $rowByHash[$hash]['source_hash'] ?? '',
                        'text' => $text,
                    ];
                    $unresolvedCount++;
                    continue;
                }
                $severity = strtolower((string) ($verdict['severity'] ?? ''));
                $hasText = is_string($text) && trim($text) !== '';
                $mechanical = $hasText ? Defects::inTranslation($row, (string) $text) : [];
                if (isset($apiRejected[$hash])) {
                    $mechanical[] = $apiRejected[$hash];
                }
                $route = ChannelRouter::route($channel, $status, $severity, $hasText, $mechanical !== []);
                if ($mechanical !== [] && $route === ChannelRouter::PROPOSAL) {
                    $mechanicalHeld++;
                    $mechanicalLog[] = ['identity_hash' => $hash, 'defects' => $mechanical];
                }
                if ($hasText && $judge->has($hash)) {
                    $decision = $judge->get($hash) ?? [];
                    $destination = $judge->destination($hash, $mechanical, $minConfidence);
                    $judgeLog[] = [
                        'at' => date('c'), 'batch' => basename(dirname($candidateFile)), 'identity_hash' => $hash,
                        'verdict' => $decision['destination'] ?? '', 'confidence' => $decision['confidence'] ?? 0,
                        'reason' => $decision['reason'] ?? '', 'qa_status' => $status, 'qa_severity' => $severity,
                        'mechanical' => count($mechanical), 'applied' => $destination,
                        'min_confidence' => $minConfidence, 'channel' => $channel,
                    ];
                    $route = $destination === JudgePolicy::AI_LAYER ? ChannelRouter::PASS : ChannelRouter::PROPOSAL;
                    $judgeCounts[$destination] = ($judgeCounts[$destination] ?? 0) + 1;
                }
                if ($route === ChannelRouter::PASS) {
                    $item = [
                        'identity_hash' => $hash,
                        'source_hash' => $rowByHash[$hash]['source_hash'] ?? '',
                        'text' => $text,
                    ];
                    if ($text === ($rowByHash[$hash]['source_text'] ?? null) && $judge->has($hash)
                        && $judge->destination($hash, Defects::inTranslation($row, (string) $text), $minConfidence) === JudgePolicy::AI_LAYER) {
                        $item['same_as_source'] = true;
                        $sameAsSource++;
                    }
                    $pass[] = $item;
                } elseif ($route === ChannelRouter::PROPOSAL) {
                    $item = [
                        'identity_hash' => $hash,
                        'source_hash' => $rowByHash[$hash]['source_hash'] ?? '',
                        'text' => $text,
                    ];
                    if ($text === ($rowByHash[$hash]['source_text'] ?? null)) {
                        $item['same_as_source'] = true;
                        $sameAsSource++;
                    }
                    $moderation[] = $item;
                } else {
                    $held[] = [
                        'identity_hash' => $hash,
                        'reason' => 'empty_text',
                        'severity' => $verdict['severity'] ?? null,
                        'issue' => $verdict['issue'] ?? null,
                        'source_text' => $rowByHash[$hash]['source_text'] ?? null,
                    ];
                }
            }

            $blocked = null;
            if ($doWrite) {
                if ($runTarget === '') {
                    $blocked = 'no_run:запусти cli/run/run-start.sh';
                } elseif ($runTarget !== $environment['environment']) {
                    $blocked = 'env_mismatch:прогін='.$runTarget.',команда='.$environment['environment'];
                } elseif (count($pass) > $remaining) {
                    $blocked = 'quota:'.$remaining.'_left';
                }
            }
            if ($blocked !== null) {
                foreach ($pass as $item) {
                    $held[] = [
                        'identity_hash' => $item['identity_hash'],
                        'reason' => $blocked,
                        'source_text' => $rowByHash[$item['identity_hash']]['source_text'] ?? null,
                        'candidate' => $item['text'],
                    ];
                }
                $pass = [];
            }

            $currentWorkspace = Workspace::current($stateDir);
            $batchId = $currentWorkspace?->id() ?? basename(dirname($candidateFile));
            if ($judgeLog !== []) {
                $this->appendJsonl($stateDir.'/judge-decisions.jsonl', $judgeLog);
            }
            $this->appendHeld($stateDir, $held, $environment['environment'], $batchId, $channel, $blocked === null);
            $quarantinePath = $stateDir.'/quarantine.jsonl';
            if (! is_file($quarantinePath) && @touch($quarantinePath) === false) {
                throw new RuntimeException('Не вдалося створити файл карантину: '.$quarantinePath);
            }

            $this->report($output, $rows, $pass, $moderation, $held, $counts, $sameAsSource, $unresolvedCount, $mechanicalHeld, $mechanicalLog, $judgeCounts, $minConfidence, $remaining, $blocked);
            $worker = $this->worker($stateDir, $root, $candidateFile);
            $targetCounts = ['written' => 0, 'skipped' => 0, 'rejected' => 0];
            $moderationCounts = ['written' => 0, 'skipped' => 0, 'rejected' => 0];
            if ($doWrite && $pass !== []) {
                $key = $idempotencyPrefix === '' ? null : $idempotencyPrefix.'-pass';
                $this->announceTarget($output, $environment);
                $result = (new TranslationWriter($root))->write($pass, $channel, $worker['provider'], $worker['model'], $key);
                $targetCounts = ['written' => $result['written'], 'skipped' => $result['skipped'], 'rejected' => $result['rejected']];
                if ($result['channel_result'] !== null) {
                    $output->stderr("Канал {$channel}: результат запису · {$result['channel_result']}\n");
                }
                $this->printWriterFacts($output, $result);
                if ($result['code'] !== 0) {
                    return $result['code'];
                }
                $output->stdout("Надіслано: ".count($pass)." рядків у {$environment['environment']} (канал {$channel})\n");
            }
            if ($doWrite && $moderation !== []) {
                $key = $idempotencyPrefix === '' ? null : $idempotencyPrefix.'-proposal';
                $this->announceTarget($output, $environment);
                $result = (new TranslationWriter($root))->write($moderation, 'proposal', $worker['provider'], $worker['model'], $key);
                $moderationCounts = ['written' => $result['written'], 'skipped' => $result['skipped'], 'rejected' => $result['rejected']];
                if ($result['channel_result'] !== null) {
                    $output->stderr("Канал proposal: результат запису · {$result['channel_result']}\n");
                }
                $this->printWriterFacts($output, $result);
                if ($result['code'] !== 0) {
                    return $result['code'];
                }
                $output->stdout('У МОДЕРАЦІЮ: '.($result['written'] + $result['skipped'])." рядків (черга пропозицій, не карантин)\n");
            }
            if (! $doWrite || ($pass === [] && $moderation === [])) {
                $output->stdout("Запису не було (потрібні --write, розпочатий прогін і квота).\n");
            }
            $quarantine = $stateDir.'/quarantine.jsonl';
            $quarantineLines = is_file($quarantine) ? count(file($quarantine, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: []) : 0;
            $output->stdout(sprintf("Карантин: %s (%d рядків усього)\n", $quarantine, $quarantineLines));
            if ($doWrite) {
                $batchDir = $currentWorkspace?->dir() ?? dirname($candidateFile);
                $summary = [
                    'rows' => count($rows), 'channel' => $channel,
                    'target_written' => $targetCounts['written'], 'target_skipped' => $targetCounts['skipped'], 'target_rejected' => $targetCounts['rejected'],
                    'moderation_written' => $moderationCounts['written'], 'moderation_skipped' => $moderationCounts['skipped'], 'moderation_rejected' => $moderationCounts['rejected'],
                    'quarantine' => count($held) + $targetCounts['rejected'] + $moderationCounts['rejected'],
                ];
                file_put_contents($batchDir.'/batch-summary.json', json_encode($summary, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR)."\n", LOCK_EX);
            }

            return 0;
        } catch (RuntimeException $exception) {
            $output->stderr($exception->getMessage()."\n");

            return 1;
        }
    }

    /** @return array{provider:string,model:string} */
    private function worker(string $stateDir, string $root, string $candidateFile): array
    {
        $currentWorkspace = Workspace::current($stateDir);
        $receipt = $currentWorkspace?->path('candidate.json.session.json') ?? '';
        $route = is_file($receipt) ? (json_decode((string) file_get_contents($receipt), true)['route'] ?? '') : '';
        $route = is_string($route) ? $route : '';
        if ($route === '') {
            $config = json_decode((string) file_get_contents($root.'/config/roles.json'), true) ?: [];
            $route = (string) ($config['roles']['translation-worker']['model'] ?? $config['default_model'] ?? '');
            if ($route === '') {
                $route = 'unknown/agent';
            }
        }
        if (str_contains($route, '/')) {
            [$provider, $model] = explode('/', $route, 2);
        } else {
            $provider = $route;
            $model = $route;
        }

        return ['provider' => $provider, 'model' => $model];
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function remainingQuota(array $environment): int
    {
        try {
            $response = (new \Bdo\Translate\Http\Client())->send(
                new \Bdo\Translate\Http\Request('GET', rtrim($environment['base'], '/').'/me', ['X-API-Key: '.$environment['key']]),
                null,
                true,
            );

            return ApiResponse::fromJson($response->body, '/me')->rowsRemainingToday();
        } catch (\Throwable) {
            return 0;
        }
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function announceTarget(Output $output, array $environment): void
    {
        $env = strtoupper((string) getenv('BDO_ENV'));
        if ($env === '') {
            $env = in_array($environment['environment'], ['prod', 'hub-prod'], true) ? 'PROD' : 'DEV';
        }
        $output->stderr(getenv('BDO_API_TARGET') === 'hub'
            ? "Ціль: ХАБ {$env} ({$environment['base']})\n"
            : "Ціль: {$env} ({$environment['base']})\n");
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function appendHeld(string $stateDir, array $held, string $environment, string $batchId, string $channel, bool $recordAttempts): void
    {
        $path = $stateDir.'/quarantine.jsonl';
        $attempts = new RowAttempts($stateDir);
        foreach ($held as $item) {
            file_put_contents($path, json_encode($item + ['at' => date('c'), 'env' => $environment], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n", FILE_APPEND | LOCK_EX);
            if ($recordAttempts) {
                $attempts->record((string) ($item['identity_hash'] ?? ''), (string) ($item['reason'] ?? 'held'), $batchId, $channel);
            }
        }
    }

    /** @param list<array<string,mixed>> $entries */
    private function appendJsonl(string $path, array $entries): void
    {
        foreach ($entries as $entry) {
            file_put_contents($path, json_encode($entry, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR)."\n", FILE_APPEND | LOCK_EX);
        }
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function printWriterFacts(Output $output, array $result): void
    {
        $output->stdout(sprintf("Записано: %d  Пропущено: %d  Відкинуто: %d\n", $result['written'], $result['skipped'], $result['rejected']));
        if ($result['rejected'] > 0) {
            $output->stdout("У КАРАНТИН: {$result['rejected']} рядків, які API відхилив.\n");
        }
    }

    private function report(Output $output, RowSet $rows, array $pass, array $moderation, array $held, array $counts, int $sameAsSource, int $unresolvedCount, int $mechanicalHeld, array $mechanicalLog, array $judgeCounts, int $minConfidence, int $remaining, ?string $blocked): void
    {
        $output->stdout(sprintf("Пачка: %d рядків | PASS %d, REVIEW %d, REJECT %d\n", count($rows), $counts['PASS'], $counts['REVIEW'], $counts['REJECT']));
        if ($sameAsSource > 0) {
            $output->stdout("Переклад = джерело: {$sameAsSource} рядків із прапорцем same_as_source (у ШІ-шар лише за вироком судді, у модерацію завжди)\n");
        }
        if ($mechanicalHeld > 0) {
            $output->stdout("Механічні дефекти у фінальному тексті: {$mechanicalHeld} рядків знято з ШІ-шару до людини\n");
            foreach (array_slice($mechanicalLog, 0, 5) as $entry) {
                $output->stdout('  '.substr((string) $entry['identity_hash'], 0, 12).'  '.implode('; ', array_slice($entry['defects'], 0, 2))."\n");
            }
        }
        if ($judgeCounts !== []) {
            $output->stdout(sprintf("Суддя: у ШІ-шар %d | до людини %d (поріг %d%%)\n", $judgeCounts[JudgePolicy::AI_LAYER] ?? 0, $judgeCounts[JudgePolicy::MODERATION] ?? 0, $minConfidence));
        }
        $output->stdout(sprintf("До запису: %d | у модерацію: %d (з них нерозпізнані назви: %d) | у карантин (збої): %d | квота: %d\n", count($pass), count($moderation), $unresolvedCount, count($held), $remaining));
        if ($blocked !== null) {
            $output->stdout("ЗАПИС ЗАБЛОКОВАНО: {$blocked}\n");
        }
    }

    private function ensureDirectory(string $path): void
    {
        if (! is_dir($path) && ! @mkdir($path, 0777, true) && ! is_dir($path)) {
            throw new RuntimeException('Не вдалося створити теку стану: '.$path);
        }
    }

    private function readFirstLine(string $path): string
    {
        return is_file($path) ? trim((string) strtok((string) file_get_contents($path), "\n")) : '';
    }

    private function required(array $arguments, int $index, string $message): string
    {
        $value = $arguments[$index] ?? '';
        if (! is_string($value) || $value === '') {
            throw new RuntimeException($message);
        }

        return $value;
    }
}
