<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;

/**
 * Один екран стану проєкту: плани, дефекти, залишок роботи, живі сигнали.
 *
 * Навіщо. Реєстри вже є (плани, беклог, дефекти, інциденти, карантин, рішення
 * судді), але лежать у шести місцях. Поки їх треба збирати вручну, вони не
 * читаються · саме так 2026-08-28 відкриті питання губились між сесіями, а той
 * самий клас дефекту повторився чотири рази за добу.
 *
 * Тут ЛИШЕ читання файлів набору: жодного запиту до API, жодної зміни стану.
 * Порожній розділ друкується явно · «нічого немає» є відповіддю, а не
 * мовчанням.
 *
 * Порт `cli/audit/project-review.sh` · вивід дослівний. Разом із shell зникли
 * дві його вади, які там доводилося обходити руками: `ls` на порожній теці під
 * `set -euo pipefail` обривав екран після першого ж розділу, а `grep -c` на
 * відсутньому файлі вимагав `|| true` у кожному виклику.
 */
final class ProjectReviewCommand implements Command, CommandHelp
{
    private const LINE = '------------------------------------------------------------';

    public function execute(array $arguments, Output $output): int
    {
        $root = dirname(__DIR__, 4);
        $stateDir = getenv('BDO_STATE_DIR') ?: $root.'/state';

        $output->stdout("================ СТАН ПРОЄКТУ ================\n");
        $output->stdout("\n");

        $this->plans($output, $root);
        $this->defects($output, $root);
        $this->backlog($output, $root);
        $this->batches($output, $stateDir);
        $this->live($output, $stateDir);

        $output->stdout("Що перевіряти далі · docs/CHECKLIST.md\n");
        $output->stdout("Що робили моделі цього прогону · ./bdo audit\n");

        return 0;
    }

    private function plans(Output $output, string $root): void
    {
        $output->stdout("== 1. Плани в роботі ==\n");
        $readme = $root.'/docs/plans/README.md';
        if (is_file($readme)) {
            $found = [];
            $inside = false;
            foreach (file($readme, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
                if (str_starts_with($line, '### У роботі')) {
                    $inside = true;
                }
                if ($inside && preg_match('/^\| (\[[^\]]*\])/', $line, $match) === 1) {
                    $found[] = '  '.$match[1];
                }
                if ($inside && str_starts_with($line, '### Не починалися')) {
                    break;
                }
            }
            $output->stdout($found === [] ? "  немає\n" : implode("\n", $found)."\n");
        } else {
            $output->stdout("  немає docs/plans/README.md\n");
        }
        $output->stdout("\n");
        $active = glob($root.'/docs/plans/active/*.md') ?: [];
        $output->stdout('  файлів у active/: '.count($active)."\n");
        $output->stdout(self::LINE."\n");
    }

    private function defects(Output $output, string $root): void
    {
        $output->stdout("== 2. Дефекти ==\n");
        $path = $root.'/docs/plans/DEFECTS.md';
        if (! is_file($path)) {
            $output->stdout("  немає docs/plans/DEFECTS.md · реєстр дефектів не ведеться\n");
            $output->stdout(self::LINE."\n");

            return;
        }
        // Статус · сьома колонка таблиці, а не початок рядка: рахувати треба
        // саме її, інакше лічильник тихо показує нулі при непорожньому реєстрі.
        $counts = ['відкритий' => 0, 'прийнятий' => 0, 'закритий' => 0];
        $open = [];
        foreach (file($path, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
            if (preg_match('/^\| D[0-9]+ /', $line) !== 1) {
                continue;
            }
            $columns = explode('|', $line);
            $status = preg_replace('/[ \t]/', '', (string) ($columns[6] ?? '')) ?? '';
            if (isset($counts[$status])) {
                $counts[$status]++;
            }
            if ($status === 'відкритий') {
                $id = preg_replace('/[ \t]/', '', (string) ($columns[1] ?? '')) ?? '';
                // Той самий зріз, що й в awk: `substr($4, 2, 70)` · від другого
                // байта четвертої колонки, 70 байтів. Байти, не символи:
                // інакше ширина екрана поїде проти shell-версії.
                $open[] = sprintf("  ВІДКРИТИЙ %-4s %s\n", $id, substr((string) ($columns[3] ?? ''), 1, 70));
            }
        }
        $output->stdout(sprintf(
            "  відкритих: %d | прийнятих: %d | закритих: %d\n",
            $counts['відкритий'],
            $counts['прийнятий'],
            $counts['закритий'],
        ));
        // Відкритий дефект без регресії · найдорожчий рядок у проєкті: він
        // повернеться, і ніхто про це не дізнається.
        foreach ($open as $row) {
            $output->stdout($row);
        }
        $output->stdout(self::LINE."\n");
    }

    private function backlog(Output $output, string $root): void
    {
        $output->stdout("== 3. Черга робіт ==\n");
        $path = $root.'/docs/plans/BACKLOG.md';
        if (! is_file($path)) {
            $output->stdout("  немає docs/plans/BACKLOG.md\n");
            $output->stdout(self::LINE."\n");

            return;
        }
        $lines = file($path, FILE_IGNORE_NEW_LINES) ?: [];
        $rows = static function (string $status) use ($lines): int {
            $needle = '| `'.$status.'`';
            $count = 0;
            foreach ($lines as $line) {
                if (str_starts_with($line, $needle)) {
                    $count++;
                }
            }

            return $count;
        };
        $output->stdout(sprintf(
            "  в роботі: %s | чекає: %s | перевірити: %s | відкладено: %s | готово: %s\n",
            $rows('в роботі'),
            $rows('чекає'),
            $rows('перевірити'),
            $rows('відкладено'),
            $rows('готово'),
        ));
        $output->stdout(self::LINE."\n");
    }

    private function batches(Output $output, string $stateDir): void
    {
        $output->stdout("== 4. Останні пачки ==\n");
        $path = $stateDir.'/run-summary.json';
        if (! is_file($path)) {
            $output->stdout("  прогону немає\n");
            $output->stdout(self::LINE."\n");

            return;
        }
        $data = json_decode((string) file_get_contents($path), true) ?: [];
        $batches = is_array($data['batches'] ?? null) ? $data['batches'] : [];
        if ($batches === []) {
            $output->stdout("  прогін порожній\n");
            $output->stdout(self::LINE."\n");

            return;
        }
        foreach (array_slice($batches, -5, 5, true) as $id => $batch) {
            $output->stdout(sprintf(
                "  %s  рядків %-4d у шар %-4d модерація %-3d карантин %d\n",
                substr((string) $id, 0, 15),
                $batch['rows'] ?? 0,
                $batch['target_written'] ?? 0,
                $batch['moderation_written'] ?? 0,
                $batch['quarantine'] ?? 0,
            ));
        }
        $totals = ['rows' => 0, 'target_written' => 0, 'moderation_written' => 0, 'quarantine' => 0];
        foreach ($batches as $batch) {
            foreach ($totals as $key => $value) {
                $totals[$key] = $value + (int) ($batch[$key] ?? 0);
            }
        }
        $output->stdout(sprintf(
            "  РАЗОМ (%d пачок): рядків %d, у шар %d, модерація %d, карантин %d\n",
            count($batches),
            $totals['rows'],
            $totals['target_written'],
            $totals['moderation_written'],
            $totals['quarantine'],
        ));
        $output->stdout(self::LINE."\n");
    }

    private function live(Output $output, string $stateDir): void
    {
        $output->stdout("== 5. Живі сигнали ==\n");
        $pointer = $stateDir.'/current-batch';
        $current = is_file($pointer) ? trim((string) file_get_contents($pointer)) : '';
        $manifestPath = $stateDir.'/batches/'.$current.'/manifest.json';
        if ($current !== '' && is_file($manifestPath)) {
            $manifest = json_decode((string) file_get_contents($manifestPath), true) ?: [];
            $output->stdout(sprintf(
                "  поточна пачка: %s | стан %s | рядків %d\n",
                $current,
                $manifest['state'] ?? '?',
                $manifest['rows'] ?? 0,
            ));
            foreach (($manifest['children'] ?? []) as $role => $child) {
                $output->stdout(sprintf(
                    "    %-24s викликів %d, рядків %d\n",
                    $role,
                    $child['calls'] ?? 0,
                    $child['items'] ?? 0,
                ));
            }
        } else {
            $output->stdout("  поточної пачки немає\n");
        }
        // Лічильники епохи диригента прибрано разом із ним · їх писали плагіни,
        // яких немає. Показувати незмінне число щоразу означало б лякати
        // власника тим, чого вже не існує. Збої моделей рахуються там, де вони
        // НАСПРАВДІ пишуться · у журналі викликів.
        $output->stdout(sprintf(
            "  збоїв моделі: %s | карантин: %s | рішень судді: %s\n",
            $this->failedCalls($stateDir.'/model-calls.jsonl'),
            $this->lines($stateDir.'/quarantine.jsonl'),
            $this->lines($stateDir.'/judge-decisions.jsonl'),
        ));
        $output->stdout(self::LINE."\n");
    }

    private function failedCalls(string $path): int
    {
        if (! is_file($path)) {
            return 0;
        }
        $count = 0;
        foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry) && ($entry['verdict'] ?? '') !== 'ok') {
                $count++;
            }
        }

        return $count;
    }

    /** `wc -l` рахує ПЕРЕВОДИ РЯДКА · порожній файл дає 0, як і в shell. */
    private function lines(string $path): int
    {
        if (! is_file($path)) {
            return 0;
        }

        return substr_count((string) file_get_contents($path), "\n");
    }

    public static function help(): string
    {
        return <<<'TEXT'
Один екран стану проєкту: плани, дефекти, залишок роботи, живі сигнали прогону.

  ./bdo review

Лише читання файлів набору: жодного запиту до API, жодної зміни стану.
TEXT;
    }
}
