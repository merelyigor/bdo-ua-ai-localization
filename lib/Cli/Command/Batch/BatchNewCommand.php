<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Batch;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\LocalTime;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Cli\Command\System\SessionCommand;
use Bdo\Translate\Session\Ledger;
use RuntimeException;

/**
 * Створює, показує й закриває ізольовану пачку.
 *
 * Сесія відкривається тією самою PHP-логікою, що й команда `session ensure`,
 * до створення workspace.
 */
final class BatchNewCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $stateDir = $this->stateDir();
        $this->ensureStateDirectory($stateDir);

        $mode = (string) ($arguments[0] ?? '');
        if ($mode === '--show') {
            $this->show($stateDir, $output);

            return 0;
        }
        if ($mode === '--end') {
            Workspace::closeCurrent($stateDir);
            $output->stdout("Пачку закрито. Тека лишилась - прибирає ./bdo clean\n");

            return 0;
        }
        if ($mode === '') {
            $output->stderr("Потрібен rows.json з API\n");

            return 1;
        }
        if (! is_file($mode)) {
            $output->stderr("Немає файлу: {$mode}\n");

            return 1;
        }

        // Беремо ту саму системну зону й формат без Unix-процесу.
        $stamp = LocalTime::stamp();
        $this->ensureSession();
        $rows = RowSet::fromFile($mode);
        $rows->identityHashes();
        $workspace = Workspace::create($stateDir, $rows, $stamp);
        (new Ledger($stateDir))->recordBatch($workspace->id());
        if (! copy($mode, $workspace->path('rows.json'))) {
            throw new RuntimeException('Не вдалося скопіювати rows.json у теку пачки.');
        }

        $output->stdout(sprintf("Пачку розпочато: %s\n  рядків: %d | ключ набору: %s\n", $workspace->id(), count($rows), $rows->key()));
        $output->stdout(sprintf("  тека: %s\n", $workspace->dir()));
        $output->stdout("\nДалі всі файли пачки складай сюди. Рядки бери з rows.json у цій теці.\n");

        return 0;
    }

    private function show(string $stateDir, Output $output): void
    {
        $workspace = Workspace::current($stateDir);
        if ($workspace === null) {
            $output->stdout("Пачку не розпочато.\n");

            return;
        }
        $manifest = $workspace->manifest();
        $output->stdout(sprintf(
            "Поточна пачка: %s\n  рядків: %s | ключ: %s | створено: %s\n  тека: %s\n",
            $workspace->id(),
            $manifest['rows'] ?? '?',
            $manifest['identity_key'] ?? '?',
            $manifest['created_at'] ?? '?',
            $workspace->dir(),
        ));
    }

    private function ensureStateDirectory(string $stateDir): void
    {
        if (! is_dir($stateDir) && ! @mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            throw new RuntimeException('Не вдалося створити теку стану: '.$stateDir);
        }
    }

    private function ensureSession(): void
    {
        SessionCommand::ensureCurrent($this->stateDir(), $this->targetEnv());
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }

    private function targetEnv(): string
    {
        $env = getenv('BDO_ENV');
        if (is_string($env) && $env !== '') {
            return $env;
        }
        $path = dirname(__DIR__, 4).'/.env';
        foreach (is_file($path) ? (file($path, FILE_IGNORE_NEW_LINES) ?: []) : [] as $line) {
            if (str_starts_with($line, 'BDO_ENV=')) {
                return trim(substr($line, 8), "\"' \t\r\n");
            }
        }

        return '';
    }
}
