<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Batch;

use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;
use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\LocalTime;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Session\Ledger;
use RuntimeException;

/**
 * Створює, показує й закриває ізольовану пачку.
 *
 * Причина збереження `session.sh ensure`: session orchestration належить
 * підетапу 7, тому ця команда переносить лише batch-частину й лишає старий
 * seam у тому самому місці — до створення workspace.
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

        // Беремо ту саму системну зону й формат, але без Unix-процесу: PHP має
        // працювати нативно на Windows, а session.sh лишається тимчасовим seam.
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
        $script = dirname(__DIR__, 4).'/cli/system/session.sh';
        $command = 'bash '.escapeshellarg($script).' ensure >/dev/null';
        exec($command, $unused, $code);
        if ($code !== 0) {
            throw new RuntimeException('Не вдалося відкрити сесію перед створенням пачки.');
        }
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
}
