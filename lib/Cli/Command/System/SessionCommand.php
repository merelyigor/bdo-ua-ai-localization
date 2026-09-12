<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\System;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\LocalTime;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Cli\Command\Batch\BatchCleanCommand;
use Bdo\Translate\Session\Ledger;
use Bdo\Translate\Ui\Text;
use FilesystemIterator;
use RecursiveDirectoryIterator;
use RecursiveIteratorIterator;

/**
 * Життєвий цикл робочих сесій.
 *
 * Порт `cli/system/session.sh`; підкоманди й тексти лишаються його контрактом.
 */
final class SessionCommand implements Command
{
    public function execute(array $arguments, Output $output): int
    {
        $stateDir = $this->stateDir();
        $this->ensureStateDirectory($stateDir);
        $sub = (string) ($arguments[0] ?? 'list');
        $rest = array_slice($arguments, 1);

        return match ($sub) {
            'new' => $this->newSession($rest, $stateDir, $output),
            'close' => $this->close($rest, $stateDir, $output),
            'list' => $this->list($rest, $stateDir, $output),
            'show' => $this->show($rest, $stateDir, $output),
            'delete' => $this->delete($rest, $stateDir, $output),
            'journals' => $this->journals($rest, $stateDir, $output),
            'ensure' => $this->ensure($rest, $stateDir, $output),
            default => $this->die($output, "дозволено лише new, close, list, show і ensure, отримано «{$sub}»"),
        };
    }

    /** Виклик для PHP-команд, яким потрібна сесія без shell seam. */
    public static function ensureCurrent(string $stateDir, string $env): string
    {
        $ledger = new Ledger($stateDir);
        $current = $ledger->currentId();

        return $current ?? $ledger->open($env, LocalTime::stamp());
    }

    /** @param list<string> $arguments */
    private function newSession(array $arguments, string $stateDir, Output $output): int
    {
        if ($arguments !== []) {
            return $this->die($output, 'new не приймає аргументів, отримано «'.(string) $arguments[0].'»');
        }
        $busy = $this->liveDriver($stateDir);
        if ($busy !== null) {
            return $this->die($output, "зараз працює прогін (пачка {$busy}) · нову сесію починати нема куди. Дочекайся кінця або зупини роботу.");
        }
        $ledger = new Ledger($stateDir);
        if ($ledger->currentId() !== null) {
            $report = $ledger->close(false);
            $output->stdout(sprintf(
                "Попередню сесію %s закрито: пачок %d, у шар %d, до людини %d, карантин %d.\n",
                $report['id'], $report['batches'], $report['to_layer'], $report['to_human'], $report['quarantine'],
            ));
        }
        $id = $ledger->open($this->targetEnv(), LocalTime::stamp());
        $output->stdout("Сесію {$id} відкрито. Кожна нова пачка потрапляє в неї сама.\n");

        return 0;
    }

    /** @param list<string> $arguments */
    private function close(array $arguments, string $stateDir, Output $output): int
    {
        $drop = false;
        $keepFiles = false;
        foreach ($arguments as $argument) {
            if ($argument === '--drop-journals') {
                $drop = true;
            } elseif ($argument === '--keep-files') {
                $keepFiles = true;
            } else {
                return $this->die($output, "для close дозволено лише --drop-journals і --keep-files, отримано «{$argument}»");
            }
        }
        $busy = $this->liveDriver($stateDir);
        if ($busy !== null) {
            return $this->die($output, "зараз працює прогін (пачка {$busy}) · закриття перенесло б журнал, у який драйвер пише. Дочекайся кінця або зупини роботу (./bdo watch --stop).");
        }
        $ledger = new Ledger($stateDir);
        if ($ledger->currentId() === null) {
            $output->stdout("Відкритої сесії немає · закривати нічого.\n");

            return 0;
        }
        $report = $ledger->close($drop);
        $output->stdout("Сесію {$report['id']} закрито.\n");
        $output->stdout(sprintf(
            "  пачок: %d | рядків: %d | у шар: %d | до людини: %d | карантин: %d | викликів моделі: %d\n",
            $report['batches'], $report['rows'], $report['to_layer'], $report['to_human'], $report['quarantine'], $report['model_calls'],
        ));
        if ($report['journals'] === 'dropped') {
            $output->stdout("  журнали видалено на вимогу (--drop-journals)\n");
        } elseif ($report['moved'] !== []) {
            $output->stdout(sprintf("  журнали перенесено (%s), житимуть %d дн.\n", implode(', ', $report['moved']), Ledger::keepDays()));
        } else {
            $output->stdout("  журналів не було · переносити нічого\n");
        }
        if ($report['missing'] !== []) {
            $output->stdout(sprintf(
                "  УВАГА: квитанції %d пачок уже прибрані, їхні числа в підсумок не увійшли: %s\n",
                count($report['missing']), implode(', ', $report['missing']),
            ));
        }
        if ($report['pruned'] !== []) {
            $output->stdout(sprintf("  журнали старших сесій прибрано: %s\n", implode(', ', $report['pruned'])));
        }
        $output->stdout("  тека: {$stateDir}/sessions/{$report['id']}\n");
        if (! $keepFiles) {
            $cleanCode = (new BatchCleanCommand())->execute(['--apply', '--quiet'], $output);
            if ($cleanCode !== 0) {
                return $cleanCode;
            }
            $output->stdout("  похідні файли завершених пачок прибрано (./bdo clean)\n");
        }

        return 0;
    }

    /** @param list<string> $arguments */
    private function list(array $arguments, string $stateDir, Output $output): int
    {
        $limit = (string) ($arguments[0] ?? '20');
        if ($limit === '' || preg_match('/^[0-9]+$/D', $limit) !== 1) {
            return $this->die($output, "list потребує число, отримано «{$limit}»");
        }
        $rows = (new Ledger($stateDir))->sessions((int) $limit);
        if ($rows === []) {
            $output->stdout("Сесій ще немає. Перша відкриється сама з першою пачкою.\n");

            return 0;
        }
        $status = ['open' => 'відкрита', 'closed' => 'закрита', 'abandoned' => 'покинута'];
        $output->stdout(sprintf(
            "%s %s %s %s %s %s %s\n",
            Text::pad('сесія', 16), Text::pad('стан', 9), Text::pad('почалась', 17),
            Text::pad('пачок', 6), Text::pad('у шар', 7), Text::pad('до людини', 10), 'журнали',
        ));
        foreach ($rows as $row) {
            $output->stdout(sprintf(
                "%s %s %s %s %s %s %s\n",
                Text::pad((string) $row['id'], 16),
                Text::pad($status[(string) $row['status']] ?? (string) $row['status'], 9),
                Text::pad((string) $row['stamp'], 17),
                Text::pad((string) (int) ($row['batches'] ?? 0), 6),
                Text::pad((string) (int) ($row['to_layer'] ?? 0), 7),
                Text::pad((string) (int) ($row['to_human'] ?? 0), 10),
                $row['journals_on_disk'] === [] ? 'прибрані' : (string) count($row['journals_on_disk']),
            ));
        }

        return 0;
    }

    /** @param list<string> $arguments */
    private function show(array $arguments, string $stateDir, Output $output): int
    {
        $id = (string) ($arguments[0] ?? '');
        $ledger = new Ledger($stateDir);
        $id = $id !== '' ? $id : $ledger->currentId();
        if ($id === null) {
            $output->stdout("Відкритої сесії немає · назви ідентифікатор: ./bdo session show <id>\n");

            return 0;
        }
        if (! is_dir($ledger->dir($id))) {
            $output->stderr("session: немає сесії {$id}\n");

            return 1;
        }
        $batches = $ledger->batches($id);
        $output->stdout(sprintf("Сесія %s · пачок %d\n\n", $id, count($batches)));
        if ($batches === []) {
            $output->stdout("Пачок у ній ще не було.\n");

            return 0;
        }
        $output->stdout(sprintf(
            "%s %s %s %s %s %s\n",
            Text::pad('пачка', 34), Text::pad('рядків', 7), Text::pad('у шар', 7),
            Text::pad('до людини', 10), Text::pad('карантин', 9), 'стан',
        ));
        foreach ($batches as $batch) {
            if (($batch['receipt_gone'] ?? false) === true) {
                $output->stdout(sprintf("%s %s\n", Text::pad((string) $batch['id'], 34), 'квитанцію прибрано · числа втрачені'));
                continue;
            }
            $output->stdout(sprintf(
                "%s %s %s %s %s %s\n",
                Text::pad((string) $batch['id'], 34), Text::pad((string) (int) $batch['rows'], 7),
                Text::pad((string) (int) $batch['to_layer'], 7), Text::pad((string) (int) $batch['to_human'], 10),
                Text::pad((string) (int) $batch['quarantine'], 9), (string) $batch['state'],
            ));
        }

        return 0;
    }

    /** @param list<string> $arguments */
    private function delete(array $arguments, string $stateDir, Output $output): int
    {
        $id = (string) ($arguments[0] ?? '');
        $apply = (($arguments[1] ?? '') === '--apply');
        $ledger = new Ledger(rtrim($stateDir, '/'));
        if (preg_match('/^[0-9]{8}_[0-9]{6}$/D', $id) !== 1) {
            return $this->error($output, 'session delete: назви сесію як 20260906_064420');
        }
        $dir = $ledger->dir($id);
        if (! is_dir($dir)) {
            return $this->error($output, "session delete: немає сесії {$id}");
        }
        if ((string) $ledger->currentId() === $id) {
            $output->stderr("session delete: сесія {$id} ВІДКРИТА. Спершу закрий її (./bdo session close),\n");
            $output->stderr("інакше видалення забере теку, у яку пише поточний прогін.\n");

            return 1;
        }

        $batches = $ledger->batches($id);
        $currentBatch = trim((string) @file_get_contents($stateDir.'/current-batch'));
        $dirs = [];
        $bytes = 0;
        $measure = function (string $path) use (&$bytes): void {
            if (! is_dir($path)) {
                return;
            }
            $iterator = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS));
            foreach ($iterator as $file) {
                if ($file->isFile()) {
                    $bytes += $file->getSize();
                }
            }
        };
        foreach ($batches as $batch) {
            $batchId = (string) ($batch['id'] ?? '');
            if ($batchId === '') {
                continue;
            }
            if ($batchId === $currentBatch) {
                return $this->error($output, "session delete: пачка {$batchId} цієї сесії є ПОТОЧНОЮ · видалення заблоковано.");
            }
            $batchDir = $stateDir.'/batches/'.$batchId;
            if (is_dir($batchDir)) {
                $dirs[] = $batchDir;
                $measure($batchDir);
            }
        }
        $measure($dir);
        $dirs[] = $dir;
        $output->stdout(sprintf("Сесія %s · пачок %d, тек до видалення %d, разом %d КБ\n", $id, count($batches), count($dirs), (int) round($bytes / 1024)));
        foreach ($dirs as $directory) {
            $output->stdout("  ".substr($directory, strlen($stateDir) + 1)."\n");
        }
        $output->stdout("НЕ чіпається: write-log.jsonl (слід записів у API), quarantine.jsonl, row-attempts.jsonl.\n");
        if (! $apply) {
            $output->stdout("ВИРОК: це лише показ. Видалити: ./bdo session delete {$id} --apply\n");

            return 0;
        }
        $remove = function (string $path) use (&$remove): void {
            if (! is_dir($path)) {
                @unlink($path);
                return;
            }
            foreach (scandir($path) ?: [] as $name) {
                if ($name === '.' || $name === '..') {
                    continue;
                }
                $remove($path.'/'.$name);
            }
            @rmdir($path);
        };
        foreach ($dirs as $directory) {
            $remove($directory);
        }
        $output->stdout(sprintf("Видалено: сесія %s і %d тек пачок (%d КБ).\n", $id, count($dirs) - 1, (int) round($bytes / 1024)));

        return 0;
    }

    /** @param list<string> $arguments */
    private function journals(array $arguments, string $stateDir, Output $output): int
    {
        $id = (string) ($arguments[0] ?? '');
        $drop = (($arguments[1] ?? '') === '--drop');
        $ledger = new Ledger($stateDir);
        $id = $id !== '' ? $id : (string) $ledger->currentId();
        if ($id === '') {
            return $this->error($output, 'session journals: назви ідентифікатор сесії');
        }
        if (! is_dir($ledger->dir($id))) {
            return $this->error($output, "session journals: немає сесії {$id}");
        }
        $files = $ledger->journalsOnDisk($id);
        if (! $drop) {
            $output->stdout(sprintf("Сесія %s · журналів на диску: %d\n", $id, count($files)));
            foreach ($files as $file) {
                $output->stdout(sprintf("  %s  %d КБ\n", $file, (int) round(filesize($ledger->dir($id).'/'.$file) / 1024)));
            }
            if ($files === []) {
                $output->stdout("  журнали вже прибрані\n");
            }

            return 0;
        }
        if ($files === []) {
            $output->stdout("Сесія {$id} · журнали вже прибрані.\n");

            return 0;
        }
        $freed = 0;
        foreach ($files as $file) {
            $path = $ledger->dir($id).'/'.$file;
            $freed += (int) filesize($path);
            @unlink($path);
        }
        $output->stdout(sprintf("Сесія %s · прибрано журналів: %d (%d КБ). Підсумок і перелік пачок лишились.\n", $id, count($files), (int) round($freed / 1024)));

        return 0;
    }

    /** @param list<string> $arguments */
    private function ensure(array $arguments, string $stateDir, Output $output): int
    {
        $output->stdout(self::ensureCurrent($stateDir, $this->targetEnv())."\n");

        return 0;
    }

    private function liveDriver(string $stateDir): ?string
    {
        foreach (glob($stateDir.'/batches/*/drive.lock') ?: [] as $lock) {
            if (! is_link($lock)) {
                continue;
            }
            $owner = readlink($lock);
            if (! is_string($owner) || preg_match('/^[0-9]+$/D', $owner) !== 1) {
                continue;
            }
            if (function_exists('posix_kill') && @posix_kill((int) $owner, 0)) {
                return basename(dirname($lock));
            }
        }

        return null;
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

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }

    private function ensureStateDirectory(string $stateDir): void
    {
        if (! is_dir($stateDir) && ! @mkdir($stateDir, 0777, true) && ! is_dir($stateDir)) {
            throw new \RuntimeException('Не вдалося створити теку стану: '.$stateDir);
        }
    }

    private function die(Output $output, string $message): int
    {
        return $this->error($output, 'session: '.$message);
    }

    private function error(Output $output, string $message): int
    {
        $output->stderr($message."\n");

        return 1;
    }
}
