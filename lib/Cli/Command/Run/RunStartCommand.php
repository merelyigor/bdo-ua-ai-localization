<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Run;

use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\Command\Api\ApiEnvironment;
use Bdo\Translate\Cli\Output;
use RuntimeException;

/** Фіксує target прогону без мережі й без зовнішніх Unix-процесів. */
final class RunStartCommand implements Command
{
    // ПРАВИЛО: target locking and timestamps stay inside PHP without Unix helpers.
    // САБОТАЖ: any external process in this class must make the runtime guard fail.
    /** @var list<string> */
    private const RESET_FILES = ['run-target', 'run-started-at', 'run-batches.json', 'run-seen.json'];

    public function execute(array $arguments, Output $output): int
    {
        $stateDir = $this->stateDir();
        $this->ensureStateDirectory($stateDir);
        $first = (string) ($arguments[0] ?? '');

        if ($first === '--show') {
            $targetFile = $stateDir.'/run-target';
            if (is_file($targetFile)) {
                $contents = @file_get_contents($targetFile);
                if ($contents === false) {
                    throw new RuntimeException('Не вдалося прочитати файл стану: '.$targetFile);
                }
                $output->stdout($contents);
            } else {
                $output->stdout("Прогін не розпочато.\n");
            }

            return 0;
        }

        if ($first === '--end') {
            $this->removeResetFiles($stateDir);
            $output->stdout("Прогін завершено, фіксацію знято.\n");

            return 0;
        }

        $root = dirname(__DIR__, 4);
        $environment = ApiEnvironment::load($root);
        $target = $environment['environment'];
        $this->announce($environment, $output);
        if (! $this->confirm($first, $target, $output)) {
            return 1;
        }

        $targetFile = $stateDir.'/run-target';
        if (is_file($targetFile)) {
            $current = $this->firstLine($targetFile);
            if ($current !== $target) {
                $batchState = 'none';
                $workspace = Workspace::current($stateDir);
                if ($workspace !== null) {
                    $manifest = $workspace->manifest();
                    $batchState = (string) ($manifest['state'] ?? 'unknown');
                }
                if (in_array($batchState, ['none', 'verified', 'failed_terminal'], true)) {
                    $this->removeResetFiles($stateDir);
                    $output->stderr("Застарілу ціль '{$current}' автоматично замінено на '{$target}': незавершеної пачки немає.\n");
                } else {
                    $output->stderr("ЗАБЛОКОВАНО: незавершена пачка має state='{$batchState}' і ціль '{$current}',\n");
                    $output->stderr("а BDO_ENV вимагає '{$target}'. Не вгадуй --end і не перемикай середовище.\n");
                    $output->stderr("Поверни BDO_ENV до '{$current}' та заверши пачку або попроси власника явно відмовитися від неї.\n");

                    return 1;
                }
            }
        }

        $this->writeFile($targetFile, $target."\n");
        $this->writeFile($stateDir.'/run-started-at', (string) (int) floor(microtime(true) * 1000)."\n");
        $env = ($target === 'prod' || $target === 'hub-prod') ? 'PROD' : 'DEV';
        $output->stdout("Ціль прогону зафіксована: {$env} ({$environment['base']})\n");
        if ($target === 'prod') {
            $output->stdout("УВАГА: це production. Кожна PASS-пачка піде в бойову базу.\n");
        }

        return 0;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }

    private function ensureStateDirectory(string $stateDir): void
    {
        if (! is_dir($stateDir) && ! @mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            throw new RuntimeException('Не вдалося створити теку стану: '.$stateDir);
        }
    }

    /** @param array{base:string,key:string,environment:string} $environment */
    private function announce(array $environment, Output $output): void
    {
        $env = ($environment['environment'] === 'prod' || $environment['environment'] === 'hub-prod') ? 'PROD' : 'DEV';
        $prefix = str_starts_with($environment['environment'], 'hub-') ? 'ХАБ ' : '';
        $output->stderr("Ціль: {$prefix}{$env} ({$environment['base']})\n");
    }

    private function confirm(string $value, string $target, Output $output): bool
    {
        if ($value === '') {
            return true;
        }
        $confirm = match (strtolower($value)) {
            'prod', 'production' => 'prod',
            'dev', 'local', 'localhost' => 'local',
            'hub-prod', 'hub-production' => 'hub-prod',
            'hub-dev', 'hub-local' => 'hub-local',
            default => null,
        };
        if ($confirm === null) {
            $output->stderr("Дозволено DEV, PROD, HUB-DEV або HUB-PROD як підтвердження, отримано '{$value}'.\n");
            return false;
        }
        if ($confirm !== $target) {
            $env = ($target === 'prod' || $target === 'hub-prod') ? 'PROD' : 'DEV';
            $apiTarget = str_starts_with($target, 'hub-') ? 'hub' : 'legacy';
            $output->stderr("Підтвердження '{$value}' не збігається з ціллю '{$target}' із .env\n");
            $output->stderr("(BDO_ENV={$env}, BDO_API_TARGET={$apiTarget}).\n");
            $output->stderr("Ціль задає файл. Зміни .env або прибери аргумент.\n");
            return false;
        }

        return true;
    }

    private function firstLine(string $path): string
    {
        $handle = @fopen($path, 'rb');
        if ($handle === false) {
            throw new RuntimeException('Не вдалося прочитати файл стану: '.$path);
        }
        $line = fgets($handle);
        if ($line === false && ! feof($handle)) {
            fclose($handle);
            throw new RuntimeException('Не вдалося прочитати файл стану: '.$path);
        }
        fclose($handle);

        return trim((string) $line);
    }

    private function removeResetFiles(string $stateDir): void
    {
        $failedPath = null;
        foreach (self::RESET_FILES as $file) {
            $path = $stateDir.'/'.$file;
            if (! file_exists($path) && ! is_link($path)) {
                continue;
            }
            if (! @unlink($path) || file_exists($path) || is_link($path)) {
                $failedPath ??= $path;
            }
        }
        if ($failedPath !== null) {
            throw new RuntimeException('Не вдалося видалити файл стану: '.$failedPath);
        }
    }

    private function writeFile(string $path, string $contents): void
    {
        if (file_put_contents($path, $contents) === false) {
            throw new RuntimeException('Не вдалося записати файл стану: '.$path);
        }
    }
}
