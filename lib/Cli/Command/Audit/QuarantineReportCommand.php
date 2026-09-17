<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Pipeline\RowAttempts;

/**
 * Рядки, які не доїхали до жодного шару.
 *
 * Навіщо команда взагалі зʼявилась. `state/quarantine.jsonl` писався з першого
 * дня і не читався НІКИМ. Заміряно 2026-08-25: 21 із 120 рядків пачки (18%)
 * осідали саме там. Гірше за саму втрату був наслідок: рядок лишався
 * `missing=`, повертався у вибірку й займав місце в наступній пачці. Тепер
 * причину закрито в самому записі, тому карантин мусить лишатись ПОРОЖНІМ ·
 * непорожній карантин є сигналом дефекту, а не робочим станом.
 *
 * Прапорця `--requeue` немає навмисно: повторне взяття не потребує локальної
 * дії, бо серверний фільтр `missing=` і далі віддає ці рядки. Зворотний бік
 * цієї точності виміряно 2026-09-04 (D56, D58): рядок, якому сервер відмовив
 * усюди, повертався в КОЖНУ пачку. Тому спроби рахує `RowAttempts`, і після
 * стелі `BDO_ROW_MAX_ATTEMPTS` рядок чекає людину тут. `--clear` обнуляє
 * обидва файли · це і є «людина розібралась».
 *
 * Порт `cli/audit/quarantine-report.sh` · вивід дослівний.
 */
final class QuarantineReportCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $stateDir = $this->stateDir();
        $quarantine = $stateDir.'/quarantine.jsonl';
        $first = (string) ($arguments[0] ?? '');
        $mode = 'summary';
        $limit = '20';
        if ($first === '--list') {
            $mode = 'list';
            $limit = (string) ($arguments[1] ?? '20');
        } elseif ($first === '--clear') {
            $mode = 'clear';
        } elseif ($first !== '') {
            $output->stderr(sprintf("Дозволено: --list [N] або --clear. Отримано '%s'.\n", $first));

            return 2;
        }
        if (preg_match('/^[0-9]+$/', $limit) !== 1) {
            $output->stderr("--list потребує ціле число.\n");

            return 2;
        }

        if (! is_file($quarantine) || filesize($quarantine) === 0) {
            $output->stdout("Карантин порожній: жоден рядок не загубився.\n");

            return 0;
        }

        if ($mode === 'clear') {
            // Слід не знищується, а ЗСУВАЄТЬСЯ в архів · один файл, що доростає.
            //
            // Дозвіл власника на цю команду (2026-09-04) знімає з агента потребу
            // питати, але не робить втрату доказів безпечною: рівно цим слідом
            // доведено D53, D56 і D58. Дата в імені не додається навмисно ·
            // купа файлів `*.archived` у `state/` є тим самим сміттям, від якого
            // набір почистили. Архів старіє за `BDO_KEEP_DAYS`.
            $archive = $quarantine.'.archived';
            @file_put_contents($archive, (string) @file_get_contents($quarantine), FILE_APPEND);
            $lines = count(file($archive, FILE_IGNORE_NEW_LINES) ?: []);
            $output->stdout(sprintf("Слід зсунуто в архів: %s (%s рядків усього)\n", basename($archive), $lines));
            @file_put_contents($quarantine, '');
            // Разом із слідом обнуляється й журнал спроб: інакше рядок, який
            // людина вже полагодила в адмінці, лишався б виключеним із вибірки
            // назавжди.
            (new RowAttempts($stateDir))->clear();
            $output->stdout("Карантин і журнал спроб очищено. Рядки в шарах не змінені; наступна пачка знову візьме ці рядки.\n");

            return 0;
        }

        $attempts = new RowAttempts($stateDir);
        $tries = $attempts->counts();
        $max = RowAttempts::maxAttempts();
        $entries = [];
        foreach (file($quarantine, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $row = json_decode($line, true);
            if (is_array($row)) {
                $entries[] = $row;
            }
        }
        if ($entries === []) {
            $output->stdout("Карантин порожній: жоден рядок не загубився.\n");

            return 0;
        }

        $byReason = [];
        $byChannel = [];
        foreach ($entries as $row) {
            $reason = (string) ($row['reason'] ?? '?');
            $channel = (string) ($row['channel'] ?? '?');
            $byReason[$reason] = ($byReason[$reason] ?? 0) + 1;
            $byChannel[$channel] = ($byChannel[$channel] ?? 0) + 1;
        }
        arsort($byReason);
        $unique = [];
        foreach ($entries as $row) {
            $unique[(string) ($row['identity_hash'] ?? '?')] = true;
        }
        $output->stdout(sprintf("Карантин: %d записів на %d унікальних рядків\n", count($entries), count($unique)));
        if ($max > 0) {
            $output->stdout(sprintf(
                "Вичерпали стелю спроб (%d): %d рядків · у наступні пачки не беруться, чекають людину\n",
                $max,
                count($attempts->exhausted($max)),
            ));
        }
        $output->stdout("\n");
        $output->stdout("За причиною:\n");
        foreach ($byReason as $reason => $count) {
            $output->stdout(sprintf("  %-28s %d\n", $reason, $count));
        }
        $output->stdout("\nЗа каналом:\n");
        foreach ($byChannel as $channel => $count) {
            $output->stdout(sprintf("  %-28s %d\n", $channel, $count));
        }

        if ($mode === 'list') {
            $output->stdout("\nОстанні ".min((int) $limit, count($entries)).":\n");
            foreach (array_slice($entries, -(int) $limit) as $row) {
                $output->stdout(sprintf(
                    "\n  %s  %s  %s  спроб: %d\n",
                    substr((string) ($row['identity_hash'] ?? ''), 0, 12),
                    (string) ($row['at'] ?? '?'),
                    (string) ($row['reason'] ?? '?'),
                    $tries[(string) ($row['identity_hash'] ?? '')] ?? 0,
                ));
                if (isset($row['source_text'])) {
                    $output->stdout(sprintf("    EN: %s\n", mb_substr((string) $row['source_text'], 0, 90)));
                }
                if (isset($row['candidate'])) {
                    $output->stdout(sprintf("    UA: %s\n", mb_substr((string) $row['candidate'], 0, 90)));
                }
            }
        }
        $output->stdout("\nРядок береться в наступну пачку, доки не вичерпає стелю спроб (BDO_ROW_MAX_ATTEMPTS); далі його чекає людина.\n");
        $output->stdout("Очистити слід і журнал спроб після розбору: ./bdo quarantine --clear\n");

        return 0;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Рядки, які не доїхали до жодного шару.

  ./bdo quarantine              зведення за причинами
  ./bdo quarantine --list       останні 20 рядків із кандидатом
  ./bdo quarantine --list 100   останні 100
  ./bdo quarantine --clear      очистити карантин після розбору

Непорожній карантин є сигналом дефекту, а не робочим станом. `--clear` зсуває
слід в архів і обнуляє журнал спроб (state/row-attempts.jsonl).
TEXT;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
}
