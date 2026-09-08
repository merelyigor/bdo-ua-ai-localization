<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Heal;

use Bdo\Translate\Api\ErrorCodes;
use Bdo\Translate\Api\Response;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Batch\SubsetRowsCommand;
use Bdo\Translate\Cli\Command\Prepare\BuildSchemaCommand;
use Bdo\Translate\Cli\Command\Quality\QaFixesCommand;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Payload\Items;
use Bdo\Translate\Quality\Defects;
use Bdo\Translate\Quality\VerdictSet;
use RuntimeException;

/**
 * Складає план лікування пачки без виклику моделі або Agent API.
 *
 * Причина переносу: heal-plan є оркестрацією локальних PHP domain objects,
 * тому batch ownership, QA FixPolicy і підмножина мають одну реалізацію й не
 * можуть розійтися через shell-підпроцеси вже перенесених команд.
 */
final class HealPlanCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $rowsFile = $this->required($arguments, 0, 'Потрібен rows.json');
        $candidateFile = $this->required($arguments, 1, 'Потрібен candidate.json');
        $verdictFile = $this->required($arguments, 2, 'Потрібен verdicts.json від translation-qa');
        $validateFile = (string) ($arguments[3] ?? '');
        foreach ([$rowsFile, $candidateFile, $verdictFile] as $file) {
            if (! is_file($file)) {
                $output->stderr("Немає файлу: {$file}\n");

                return 1;
            }
        }

        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        $workspace = Workspace::current($stateDir);
        if ($workspace === null) {
            $output->stderr("Пачку не розпочато: ./bdo batch new rows.json\n");
            $output->stderr("Без теки пачки файли лікування змішалися б із чужими.\n");

            return 1;
        }

        try {
            $rows = RowSet::fromFile($rowsFile);
            $candidate = Candidate::fromFile($candidateFile);
            $workspace->assertRows($rows);
            $workspace->assertCandidate($rows, $candidate);
        } catch (\Throwable $exception) {
            $output->stderr('ПОМИЛКА: '.$exception->getMessage()."\n");

            return 1;
        }

        $qaFixes = $this->qaFixes($verdictFile, $rowsFile, $candidateFile);
        $verdicts = VerdictSet::fromFile($verdictFile);
        $validate = $validateFile !== '' && file_exists($validateFile)
            ? Response::fromFile($validateFile, 'validate')
            : null;
        $attemptsFile = $workspace->path('heal-attempts.json');
        $maxAttempts = max(1, (int) (getenv('BDO_HEAL_MAX_ATTEMPTS') ?: '1'));
        $mergedFile = $workspace->path('heal-merged.json');
        $repairFile = $workspace->path('heal-repair-payload.json');

        $batchKey = $rows->key();
        $state = is_file($attemptsFile)
            ? (json_decode((string) file_get_contents($attemptsFile), true) ?: [])
            : [];
        $attempts = (($state['batch'] ?? '') === $batchKey) ? ($state['attempts'] ?? []) : [];

        $serverFixed = [];
        foreach ($validate?->serverRepairs() ?? [] as $hash => $text) {
            if ($rows->has($hash)) {
                $serverFixed[$hash] = $text;
            }
        }

        $qaFixed = [];
        foreach ($qaFixes as $fix) {
            $hash = $fix['identity_hash'] ?? '';
            if (isset($serverFixed[$hash])) {
                continue;
            }
            $qaFixed[$hash] = (string) ($fix['text'] ?? '');
        }

        $defects = [];
        foreach ($verdicts->nonPass() as $verdict) {
            $hash = $verdict['identity_hash'] ?? '';
            $defects[$hash][] = trim((string) ($verdict['issue'] ?? '')) ?: 'QA: '.($verdict['status'] ?? '?');
        }
        foreach ($candidate->all() as $hash => $text) {
            foreach (Defects::inTranslation($rows->getOrEmpty($hash), $text) as $defect) {
                $defects[$hash][] = $defect;
            }
        }
        foreach ($validate?->rejections() ?? [] as $hash => $why) {
            $defects[$hash][] = $why;
        }

        $merged = [];
        $forRepair = [];
        $hopeless = [];
        $permanent = [];
        foreach (array_keys($defects) as $hash) {
            if (isset($serverFixed[$hash])) {
                $merged[$hash] = ['сервер', $serverFixed[$hash]];
                continue;
            }
            if (isset($qaFixed[$hash])) {
                $merged[$hash] = ['QA-fix', $qaFixed[$hash]];
                continue;
            }
            if (array_filter($defects[$hash], static fn (string $defect): bool => ErrorCodes::isPermanent($defect)) !== []) {
                $permanent[$hash] = true;
                continue;
            }
            $actionable = array_filter(
                $defects[$hash],
                static fn (string $defect): bool => str_contains($defect, 'ужий «') || str_contains($defect, 'збережи токен «'),
            ) !== [];
            $limit = $actionable ? $maxAttempts + 1 : $maxAttempts;
            $done = (int) ($attempts[$hash] ?? 0);
            if ($done >= $limit) {
                $hopeless[$hash] = $done;
                continue;
            }
            $forRepair[$hash] = array_values(array_unique($defects[$hash]));
        }

        $fixes = [];
        foreach ($merged as $hash => [$source, $text]) {
            $fixes[$hash] = $text;
        }
        $this->writeJson($mergedFile, $candidate->withFixes($fixes)->toList());

        $payload = [];
        foreach ($forRepair as $hash => $why) {
            $row = $rows->getOrEmpty($hash);
            usort($why, static function (string $left, string $right): int {
                $rank = static fn (string $defect): int => str_contains($defect, 'ужий «') || str_contains($defect, 'збережи токен «') ? 0 : 1;

                return $rank($left) <=> $rank($right);
            });
            $item = [
                'identity_hash' => $hash,
                'source_text' => $row->sourceText(),
                'current' => $candidate->text($hash),
                'defects' => $why,
            ];
            if ($row->semanticType() !== null) {
                $item['semantic_type'] = $row->semanticType();
            }
            if ($row->domain() !== null) {
                $item['domain'] = $row->domain();
            }
            $keep = $row->keepTokens();
            if ($keep !== []) {
                $item['keep'] = $keep;
            }
            $terms = $row->glossary();
            if ($terms !== []) {
                $item['glossary'] = $terms;
            }
            $limits = $row->limits();
            if ($limits !== null) {
                $item['limits'] = $limits;
            }
            $payload[] = $item;
            $attempts[$hash] = (int) ($attempts[$hash] ?? 0) + 1;
        }

        $repairOut = $payload;
        if ($payload !== []) {
            $picked = \Bdo\Translate\Payload\Concepts::forTexts(array_column($payload, 'source_text'));
            if ($picked['concepts'] !== []) {
                $repairOut = ['concepts' => $picked['concepts'], 'items' => $payload];
            }
        }
        $this->writeJson($repairFile, $repairOut);
        $this->writeJson($attemptsFile, ['batch' => $batchKey, 'attempts' => $attempts]);

        $this->report($output, $candidate, $merged, $qaFixed, $forRepair, $permanent, $hopeless, $maxAttempts, $mergedFile, $repairFile);

        if (is_file($repairFile) && filesize($repairFile) > 0) {
            $hashes = Items::hashes($repairFile);
            if ($hashes !== []) {
                $subset = $workspace->path('heal-repair-subset.json');
                $subsetOutput = $this->capture(new SubsetRowsCommand(), [$rowsFile, implode(',', $hashes), $subset]);
                $repairSchema = $this->capture(new BuildSchemaCommand(), [$subset]);
                $qaSchema = $this->capture(new BuildSchemaCommand(), ['--qa', $subset]);
                if ($subsetOutput['code'] === 0 && $repairSchema['code'] === 0 && $qaSchema['code'] === 0) {
                    $output->stdout("Схеми repair і контрольного QA переставлено на підмножину: {$subset}\n");
                    $output->stdout("Наступна пачка перезапише їх сама (кроки build-schema на її rows).\n");
                } else {
                    $output->stderr("УВАГА: не вдалося поставити схему підмножини · зроби вручну:\n");
                    $output->stderr("  ./bdo subset {$rowsFile} ".implode(',', $hashes)." {$workspace->path('heal-repair-subset.json')}\n");
                    $output->stderr("  ./bdo schema build {$workspace->path('heal-repair-subset.json')}\n");
                    $output->stderr("  ./bdo schema qa {$workspace->path('heal-repair-subset.json')}\n");

                    return 1;
                }
            }
        }

        return 0;
    }

    /** @return list<array<string,mixed>> */
    private function qaFixes(string $verdictFile, string $rowsFile, string $candidateFile): array
    {
        $result = $this->capture(new QaFixesCommand(), [$verdictFile, $rowsFile, $candidateFile]);
        $decoded = json_decode($result['stdout'], true);

        return is_array($decoded) ? $decoded : [];
    }

    /** @return array{code:int,stdout:string,stderr:string} */
    private function capture(Command $command, array $arguments): array
    {
        $stdout = fopen('php://temp', 'w+b');
        $stderr = fopen('php://temp', 'w+b');
        if ($stdout === false || $stderr === false) {
            throw new RuntimeException('Не вдалося підготувати внутрішній вивід команди.');
        }
        try {
            try {
                $code = $command->execute($arguments, new Output($stdout, $stderr));
            } catch (\Throwable $exception) {
                $code = 1;
                fwrite($stderr, $exception->getMessage()."\n");
            }
            rewind($stdout);
            rewind($stderr);

            return [
                'code' => $code,
                'stdout' => (string) stream_get_contents($stdout),
                'stderr' => (string) stream_get_contents($stderr),
            ];
        } finally {
            fclose($stdout);
            fclose($stderr);
        }
    }

    private function writeJson(string $path, mixed $value): void
    {
        $json = json_encode($value, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR);
        if (file_put_contents($path, $json) === false) {
            throw new RuntimeException('Не вдалося записати файл: '.$path);
        }
    }

    private function report(
        Output $output,
        Candidate $candidate,
        array $merged,
        array $qaFixed,
        array $forRepair,
        array $permanent,
        array $hopeless,
        int $maxAttempts,
        string $mergedFile,
        string $repairFile,
    ): void {
        $total = $candidate->count();
        $broken = count($merged) + count($forRepair) + count($permanent) + count($hopeless);
        $serverCount = count(array_filter($merged, static fn (array $item): bool => $item[0] === 'сервер'));
        $qaCount = count(array_filter($merged, static fn (array $item): bool => $item[0] === 'QA-fix'));
        $output->stdout(sprintf("Рядків у пачці: %d | з дефектами: %d\n", $total, $broken));
        $output->stdout(sprintf("  вилікувано сервером (repaired_text): %d\n", $serverCount));
        $output->stdout(sprintf("  вилікувано дрібним fix QA:           %d\n", $qaCount));
        $output->stdout(sprintf("  у translation-repair:                %d\n", count($forRepair)));
        $output->stdout(sprintf("  API не приймає, модель не поможе:    %d\n", count($permanent)));
        $output->stdout(sprintf("  у модерацію (після %d кола лікування): %d\n", $maxAttempts, count($hopeless)));
        foreach ($hopeless as $hash => $done) {
            $output->stdout(sprintf("    %s  спроб: %d\n", substr($hash, 0, 12), $done));
        }
        $output->stdout("\nЗлитий кандидат: {$mergedFile}\n");
        if ($forRepair !== []) {
            $output->stdout("Payload для repair: {$repairFile}\n");
            $output->stdout(sprintf("\nВИРОК: віддай %s агенту translation-repair, потім КОНТРОЛЬНИЙ QA лише по цих %d рядках - і одразу cli/batch/batch-commit.sh.\n", basename($repairFile), count($forRepair)));
            $output->stdout("Третього кола не буде: те, що лишиться не-PASS, іде в модерацію.\n");
        } elseif ($hopeless !== []) {
            $output->stdout("\nВИРОК: коло лікування вичерпано. cli/batch/batch-commit.sh: PASS у ШІ-шар, решта в модерацію.\n");
        } else {
            $output->stdout("\nВИРОК: дефектів не лишилось. Злитий кандидат готовий до cli/batch/batch-commit.sh.\n");
        }
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
