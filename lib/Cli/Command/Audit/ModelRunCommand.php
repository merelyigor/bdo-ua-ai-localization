<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Ui\Clock;

/**
 * Що робили моделі цього прогону · за ВЛАСНИМ журналом.
 *
 * Навіщо окремий аудит. Старий аудит читав `opencode.db`: іншого джерела правди
 * про дитячі сесії не було, бо їх створював чужий застосунок. Це коштувало
 * кількох дефектів само по собі · аудит бачив лише те, що зберіг той застосунок,
 * і його вирок про форму відповіді розійшовся з нашою ж схемою (D44).
 *
 * Тепер моделі викликає `cli/model/client.php`, і КОЖЕН виклик пише рядок у
 * `state/model-calls.jsonl`. Джерело правди наше, воно не залежить від
 * застосунку й переживає його видалення.
 *
 * Код виходу: 0 · збоїв немає; 1 · у прогоні є виклики з вердиктом, відмінним
 * від `ok`. Це не «страшно», це привід подивитись причину · вона в тому ж рядку.
 *
 * Порт `cli/audit/model-run.sh` · вивід дослівний.
 */
final class ModelRunCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $stateDir = getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
        $calls = $stateDir.'/model-calls.jsonl';
        $limit = (int) ($arguments[0] ?? 0);

        if (! is_file($calls)) {
            $output->stdout("Журналу викликів ще немає ($calls) · моделі не викликали жодного разу.\n");

            return 0;
        }

        // Межа прогону · та сама мітка, що й у старому аудиті: інакше
        // вчорашній збій лишається у вибірці й лякає на здоровому прогоні.
        $since = 0;
        $marker = $stateDir.'/run-started-at';
        if (is_file($marker)) {
            $lines = file($marker, FILE_IGNORE_NEW_LINES) ?: [];
            $since = (int) ($lines[0] ?? 0);
        }

        $rows = [];
        foreach (file($calls, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $entry = json_decode($line, true);
            if (! is_array($entry)) {
                continue;
            }
            if ($since > 0 && strtotime((string) ($entry['at'] ?? '')) * 1000 < $since) {
                continue;
            }
            $rows[] = $entry;
        }
        $output->stdout(sprintf(
            "Оцінюємо: %s\n\n",
            $since > 0 ? 'виклики поточного прогону' : 'уся історія (прогін не розпочато)',
        ));
        if ($rows === []) {
            $output->stdout("У цьому прогоні моделі ще не викликали.\n");

            return 0;
        }

        $byRole = [];
        foreach ($rows as $row) {
            $role = (string) ($row['role'] ?? '?');
            $stats = $byRole[$role] ?? ['n' => 0, 'bad' => 0, 'ms' => 0, 'in' => 0, 'out' => 0];
            $stats['n']++;
            $stats['ms'] += (int) ($row['ms'] ?? 0);
            $stats['in'] += (int) ($row['in'] ?? 0);
            $stats['out'] += (int) ($row['out'] ?? 0);
            if (($row['verdict'] ?? '') !== 'ok') {
                $stats['bad']++;
            }
            $byRole[$role] = $stats;
        }
        ksort($byRole);
        $output->stdout(sprintf(
            "%s %s %s %s %s %s\n",
            $this->pad('роль', 24),
            $this->pad('разів', 6),
            $this->pad('збоїв', 6),
            $this->pad('сек', 10),
            $this->pad('вхід', 10),
            $this->pad('вихід', 10),
        ));
        $totals = ['n' => 0, 'bad' => 0, 'ms' => 0, 'in' => 0, 'out' => 0];
        foreach ($byRole as $role => $stats) {
            $output->stdout(sprintf(
                "%s %6d %6d %10.1f %10d %10d\n",
                $this->pad((string) $role, 24),
                $stats['n'],
                $stats['bad'],
                $stats['ms'] / 1000,
                $stats['in'],
                $stats['out'],
            ));
            foreach ($totals as $key => $_) {
                $totals[$key] += $stats[$key];
            }
        }
        $output->stdout(sprintf(
            "%s %6d %6d %10.1f %10d %10d\n",
            $this->pad('РАЗОМ', 24),
            $totals['n'],
            $totals['bad'],
            $totals['ms'] / 1000,
            $totals['in'],
            $totals['out'],
        ));

        // Швидкість · головна цифра для планування нічного прогону.
        if ($totals['ms'] > 0) {
            $output->stdout(sprintf(
                "\nШвидкість генерації: %.1f токенів/с у середньому по всіх ролях.\n",
                $totals['out'] / ($totals['ms'] / 1000),
            ));
        }

        $bad = array_values(array_filter($rows, static fn (array $row): bool => ($row['verdict'] ?? '') !== 'ok'));
        if ($bad !== []) {
            $output->stdout(sprintf("\nЗбої (%d):\n", count($bad)));
            foreach (array_slice($bad, -10) as $row) {
                $output->stdout(sprintf(
                    "  %s %s %s\n",
                    Clock::stamp($row['at'] ?? null),
                    $this->pad((string) ($row['role'] ?? '?'), 24),
                    (string) ($row['verdict'] ?? '?'),
                ));
            }
        }

        if ($limit > 0) {
            $output->stdout(sprintf("\nОстанні %d викликів:\n", $limit));
            foreach (array_slice($rows, -$limit) as $row) {
                $output->stdout(sprintf(
                    "  %s %s %s %6.1f с\n",
                    Clock::stamp($row['at'] ?? null),
                    $this->pad((string) ($row['role'] ?? '?'), 24),
                    $this->pad((string) ($row['verdict'] ?? '?'), 16),
                    ((int) ($row['ms'] ?? 0)) / 1000,
                ));
            }
        }

        $output->stdout("\n".($bad === []
            ? "ВИРОК: усі виклики моделей завершились нормально.\n"
            : sprintf("ВИРОК: %d викликів зі збоєм · причина в тому ж рядку журналу.\n", count($bad))));

        return $bad === [] ? 0 : 1;
    }

    /**
     * `sprintf` рахує БАЙТИ, а заголовки тут кириличні: без mb-вирівнювання
     * колонки зʼїжджають рівно на довжину слова. Та сама пастка вже ловила
     * звіт `./bdo models`.
     */
    private function pad(string $text, int $width): string
    {
        return $text.str_repeat(' ', max(1, $width - mb_strlen($text)));
    }

    public static function help(): string
    {
        return <<<'TEXT'
Що робили моделі цього прогону · за власним журналом state/model-calls.jsonl.

  ./bdo audit          підсумок по ролях + останні збої
  ./bdo audit 40       ще й останні 40 викликів по одному

Код виходу: 0 · збоїв немає; 1 · є виклики з вердиктом, відмінним від `ok`.
Межу прогону тримає state/run-started-at.
TEXT;
    }
}
