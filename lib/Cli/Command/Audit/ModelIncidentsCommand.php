<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Ui\Clock;
use Bdo\Translate\Ui\Text;

/**
 * Виклики моделі, які завершились НЕ вердиктом `ok`.
 *
 * Джерело · `state/model-calls.jsonl`, той самий журнал, що й у `./bdo audit`.
 * Раніше цей звіт читав журнали плагіна OpenCode, якого немає з 2026-09-04:
 * файли перестали рости, а команда показувала застигле число · тобто брехала
 * про стан набору.
 *
 * Що тут видно тепер: `truncated` (обрив на `num_predict`), `not_json`,
 * `empty_content`, `thinking_loop`, `model_error`, `model_unreachable`,
 * `context_overflow`, `unknown_id`. Кожну причину пише `cli/model/client.php` у
 * момент відмови, тому журнал і робота ходять одним шляхом.
 *
 * `--clear` тут немає навмисно: єдиний журнал прогону чистити не можна, інакше
 * зникне й історія успішних викликів, за якою рахується вартість пачки.
 *
 * Порт `cli/audit/model-incidents.sh` · вивід дослівний.
 */
final class ModelIncidentsCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $mode = (string) ($arguments[0] ?? 'summary');
        if ($mode === '') {
            $mode = 'summary';
        }
        $limit = '20';
        if ($mode === '--list') {
            $limit = (string) ($arguments[1] ?? '20');
        } elseif ($mode !== 'summary') {
            $output->stderr(sprintf("Дозволено: (без аргументів) | --list [N]. Отримано '%s'.\n", $mode));

            return 2;
        }
        if (preg_match('/^[0-9]+$/', $limit) !== 1) {
            $output->stderr("--list потребує ціле число.\n");

            return 2;
        }

        $calls = $this->stateDir().'/model-calls.jsonl';
        if (! is_file($calls) || filesize($calls) === 0) {
            $output->stdout("Журналу викликів ще немає ($calls) · моделі не викликали жодного разу.\n");

            return 0;
        }

        $bad = [];
        $total = 0;
        foreach (file($calls, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $entry = json_decode($line, true);
            if (! is_array($entry)) {
                continue;
            }
            $total++;
            if (($entry['verdict'] ?? '') !== 'ok') {
                $bad[] = $entry;
            }
        }
        if ($bad === []) {
            $output->stdout(sprintf("Збоїв немає: %d викликів, усі з вердиктом ok.\n", $total));

            return 0;
        }
        $output->stdout(sprintf("Збоїв: %d із %d викликів\n\n", count($bad), $total));
        $byKey = [];
        foreach ($bad as $entry) {
            $key = (string) ($entry['role'] ?? '?').' | '.(string) ($entry['verdict'] ?? '?');
            $byKey[$key] = ($byKey[$key] ?? 0) + 1;
        }
        arsort($byKey);
        foreach ($byKey as $key => $count) {
            $output->stdout(sprintf("  %4d  %s\n", $count, $key));
        }
        if ($mode === '--list') {
            $output->stdout(sprintf("\nОстанні %d:\n", min((int) $limit, count($bad))));
            foreach (array_slice($bad, -(int) $limit) as $entry) {
                $output->stdout(sprintf(
                    "  %s  %s %s  %.1f с  вих %s\n",
                    Clock::stamp($entry['at'] ?? null),
                    Text::pad((string) ($entry['role'] ?? '?'), 24),
                    Text::pad((string) ($entry['verdict'] ?? '?'), 18),
                    ((int) ($entry['ms'] ?? 0)) / 1000,
                    (string) ($entry['out'] ?? '-'),
                ));
            }
        }
        $output->stdout("\nПовні записи: ./bdo incidents --list\n");
        $output->stdout("Повторюваний збій тієї самої ролі означає роботу над промптом, схемою або\n");
        $output->stdout("моделлю, а не над окремою пачкою. Причину кожної відмови пише cli/model/client.php.\n");

        return 0;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Виклики моделі, які завершились НЕ вердиктом `ok`.

  ./bdo incidents            зведення за роллю й причиною
  ./bdo incidents --list     останні записи повністю
  ./bdo incidents --list 50  останні 50

Читає state/model-calls.jsonl. `--clear` немає навмисно: єдиний журнал прогону
чистити не можна, інакше зникне й історія успішних викликів.
TEXT;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
}
