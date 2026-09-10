<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Command\Api\FetchRowsCommand;
use Bdo\Translate\Cli\Command\Batch\BatchNewCommand;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Pipeline\RunSpec;
use RuntimeException;

/** Оркеструє одну пачку прогону без shell-посередника. */
final class RunModeCommand implements Command
{
    // ПРАВИЛО: порядок env/spec/lock/resume/fetch/budget/goal/batch тримає код.
    // САБОТАЖ: будь-який зовнішній process call у цій команді має зупинити gate.
    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $mode = (string) ($arguments[0] ?? '');
        $size = (string) ($arguments[1] ?? '50');
        $patch = (string) ($arguments[2] ?? 'active');
        $domain = (string) ($arguments[3] ?? '');
        if ($size === '') {
            $size = '50';
        }
        if ($patch === '') {
            $patch = 'active';
        }

        $environment = ApiEnvironment::load($root);
        $this->announce($environment, $output);
        // Shell run-spec sources select-env as a command substitution; its
        // target announcement remains observable on the parent stderr.
        $this->announce($environment, $output);
        $preset = RunSpec::preset($mode);
        $query = RunSpec::filterFor($mode, $patch, $domain);
        $channel = (string) $preset['channel'];
        $memoryLayers = $preset['memory_layers'] === ['manual'] ? 'manual' : 'all';
        $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';

        $startCode = $this->runStart($output);
        if ($startCode !== 0) {
            return $startCode;
        }

        $current = Workspace::current($stateDir);
        if ($current !== null) {
            $manifest = $current->manifest();
            $state = (string) ($manifest['state'] ?? '');
            if (! in_array($state, ['verified', 'failed_terminal'], true)) {
                if ((string) ($manifest['mode'] ?? '') === '') {
                    $manifest = $current->updateManifest(static function (array $value) use ($mode, $channel, $query, $memoryLayers, $patch, $domain): array {
                        $value['mode'] = $mode;
                        $value['channel'] = $channel;
                        $value['query'] = $query;
                        $value['memory_layers'] = $memoryLayers;
                        $value['patch'] = $patch;
                        $value['domain'] = $domain;

                        return $value;
                    }, 'run_spec_recovered');
                }
                $output->stdout(json_encode([
                    'ok' => true,
                    'resume' => true,
                    'mode' => $manifest['mode'] ?? null,
                    'patch' => $manifest['patch'] ?? null,
                    'state' => $state,
                    'rows' => $manifest['rows'] ?? null,
                    'batch_dir' => $current->dir(),
                ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));

                return 0;
            }
        }

        $fetch = new FetchRowsCommand();
        $fetchStream = tmpfile();
        if ($fetchStream === false) {
            return $this->fetchFailure($output, $size, 'Не вдалося відкрити тимчасовий потік для fetch.');
        }
        $fetchOutput = new Output($fetchStream, $fetchStream);
        try {
            $fetchCode = $fetch->execute([$size, $query], $fetchOutput);
            rewind($fetchStream);
            $fetchDetail = stream_get_contents($fetchStream);
            $fetchDetail = $fetchDetail === false ? '' : trim($fetchDetail);
        } catch (\Throwable $exception) {
            rewind($fetchStream);
            $fetchDetail = stream_get_contents($fetchStream);
            fclose($fetchStream);

            return $this->fetchFailure(
                $output,
                $size,
                trim(($fetchDetail === false ? '' : $fetchDetail).($fetchDetail === '' ? '' : "\n").$exception->getMessage()),
            );
        }
        fclose($fetchStream);
        if ($fetchCode !== 0) {
            return $this->fetchFailure($output, $size, $fetchDetail);
        }

        $rowsPath = $fetch->resultPath();
        if ($rowsPath === null || ! is_file($rowsPath)) {
            return $this->fetchFailure($output, $size, 'fetch не повернув наявний structured rows path.');
        }
        $rowsRaw = @file_get_contents($rowsPath);
        if ($rowsRaw === false) {
            return $this->fetchFailure($output, $size, 'Не вдалося прочитати structured rows file: '.$rowsPath);
        }
        try {
            $rowsData = json_decode($rowsRaw, true, 512, JSON_THROW_ON_ERROR);
        } catch (\Throwable) {
            return $this->fetchFailure($output, $size, 'Невалідний JSON rows file: '.$rowsPath);
        }
        $rows = $rowsData['data']['rows'] ?? null;
        if (! is_array($rows)) {
            return $this->fetchFailure($output, $size, 'У rows file немає масиву data.rows: '.$rowsPath);
        }
        $count = count($rows);
        if ($count === 0) {
            $run = [];
            $summaryPath = $stateDir.'/run-summary.json';
            if (is_file($summaryPath)) {
                $summaryRaw = @file_get_contents($summaryPath);
                if ($summaryRaw !== false) {
                    try {
                        $decoded = json_decode($summaryRaw, true, 512, JSON_THROW_ON_ERROR);
                        $run = is_array($decoded) ? $decoded : [];
                    } catch (\Throwable) {
                        $run = [];
                    }
                }
            }
            $this->json($output, [
                'ok' => true,
                'mode' => $mode,
                'patch' => $patch,
                'state' => 'complete',
                'rows' => 0,
                'run' => $run['totals'] ?? [],
            ]);

            return 0;
        }

        $budget = $this->advanceBudget($stateDir.'/run-batches.json', $environment['environment'].':'.$mode.':'.$patch.':'.$domain, $output);
        if ($budget !== true) {
            return 1;
        }
        $goalPath = $stateDir.'/run-goal.json';
        $goal = json_encode([
            'mode' => $mode,
            'patch' => $patch,
            'domain' => $domain,
            'channel' => $channel,
            'query' => $query,
        ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
        if (@file_put_contents($goalPath, $goal, LOCK_EX) === false) {
            $output->stderr('Не вдалося записати файл стану: '.$goalPath."\n");
            return 1;
        }

        $batchOutput = tmpfile();
        if ($batchOutput === false) {
            throw new RuntimeException('Не вдалося відкрити тимчасовий потік для batch new.');
        }
        $batchCommand = new BatchNewCommand();
        try {
            $batchCode = $batchCommand->execute([$rowsPath], new Output($batchOutput, $batchOutput));
        } finally {
            fclose($batchOutput);
        }
        if ($batchCode !== 0) {
            return $batchCode;
        }

        $workspace = Workspace::requireCurrent($stateDir);
        $workspace->updateManifest(static function (array $manifest) use ($mode, $channel, $query, $memoryLayers, $patch, $domain): array {
            $manifest['mode'] = $mode;
            $manifest['channel'] = $channel;
            $manifest['query'] = $query;
            $manifest['memory_layers'] = $memoryLayers;
            $manifest['patch'] = $patch;
            $manifest['domain'] = $domain;

            return $manifest;
        }, 'run_spec');
        $this->json($output, [
            'ok' => true,
            'mode' => $mode,
            'patch' => $patch,
            'domain' => $domain,
            'state' => 'selected',
            'rows' => $count,
            'batch_dir' => $workspace->dir(),
        ]);

        return 0;
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function announce(array $environment, Output $output): void
    {
        $env = in_array($environment['environment'], ['prod', 'hub-prod'], true) ? 'PROD' : 'DEV';
        $prefix = str_starts_with($environment['environment'], 'hub-') ? 'ХАБ ' : '';
        $output->stderr("Ціль: {$prefix}{$env} ({$environment['base']})\n");
    }

    private function runStart(Output $output): int
    {
        $stdout = tmpfile();
        $stderr = tmpfile();
        if ($stdout === false || $stderr === false) {
            if (is_resource($stdout)) {
                fclose($stdout);
            }
            if (is_resource($stderr)) {
                fclose($stderr);
            }
            throw new RuntimeException('Не вдалося відкрити тимчасовий потік для run-start.');
        }
        try {
            $code = (new RunStartCommand())->execute([], new Output($stdout, $stderr));
            $this->forward($stderr, $output);

            return $code;
        } catch (\Throwable $exception) {
            $this->forward($stderr, $output);
            throw $exception;
        } finally {
            fclose($stdout);
            fclose($stderr);
        }
    }

    /** @param resource $stream */
    private function forward(mixed $stream, Output $output): void
    {
        rewind($stream);
        $text = stream_get_contents($stream);
        if ($text !== false && $text !== '') {
            $output->stderr($text);
        }
    }

    private function advanceBudget(string $path, string $scope, Output $output): ?bool
    {
        if (! file_exists($path) && ! is_link($path)) {
            $run = [];
        } else {
            $raw = @file_get_contents($path);
            if ($raw === false) {
                $output->stderr('Не вдалося прочитати файл стану: '.$path."\n");
                return null;
            }
            try {
                $run = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
            } catch (\Throwable) {
                $output->stderr('Пошкоджений файл стану: '.$path."\n");
                return null;
            }
            if (! is_array($run)) {
                $output->stderr('Пошкоджений файл стану: '.$path."\n");
                return null;
            }
        }
        $count = (($run['scope'] ?? null) === $scope) ? (int) ($run['batches'] ?? 0) : 0;
        $max = max(1, (int) (getenv('BDO_RUN_MAX_BATCHES') ?: '25'));
        if ($count >= $max) {
            $this->json($output, [
                'ok' => false,
                'state' => 'budget_exhausted',
                'batches' => $count,
                'reason' => 'стеля BDO_RUN_MAX_BATCHES на цей прогін вичерпана; підніми її в .env або заверши прогін',
            ]);
            return false;
        }
        $newRun = json_encode(['scope' => $scope, 'batches' => $count + 1], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        if (@file_put_contents($path, $newRun, LOCK_EX) === false) {
            $output->stderr('Не вдалося записати файл стану: '.$path."\n");
            return null;
        }

        return true;
    }

    private function fetchFailure(Output $output, string $size, string $detail): int
    {
        $this->json($output, [
            'ok' => false,
            'state' => 'waiting_dependency',
            'reason' => 'fetch_failed',
            'size' => $size,
            'detail' => trim($detail),
        ]);

        return 1;
    }

    /** @param array<string,mixed> $value */
    private function json(Output $output, array $value): void
    {
        $output->stdout(json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n");
    }
}
