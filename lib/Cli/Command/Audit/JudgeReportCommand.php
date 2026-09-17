<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Pipeline\JudgePolicy;
use Bdo\Translate\Ui\Clock;

/**
 * Що вирішував суддя і чи можна йому вірити.
 *
 * Журнал пише крок запису під час застосування вироків. Тут лише читання. Мета
 * · калібрування: поріг `BDO_JUDGE_MIN_CONFIDENCE` має спиратися на те, як
 * вироки збігаються з рішеннями людини в модерації, а не на відчуття.
 *
 * Окремо перевіряється ВИРОДЖЕННЯ: суддя, який пропускає у шар майже все, не
 * судить, а штампує. Це видно лише на журналі, тому висновок зʼявляється, коли
 * вибірка достатня.
 *
 * Порт `cli/audit/judge-report.sh` · вивід дослівний.
 */
final class JudgeReportCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $log = $this->stateDir().'/judge-decisions.jsonl';
        $mode = (string) ($arguments[0] ?? 'summary');
        if ($mode === '') {
            $mode = 'summary';
        }
        if (! in_array($mode, ['summary', '--list', '--clear'], true)) {
            $output->stderr("Дозволено: (без аргументів) | --list | --clear\n");

            return 2;
        }
        if (! is_file($log)) {
            $output->stdout("Суддя ще не ухвалював рішень: $log не створено.\n");

            return 0;
        }

        if ($mode === '--clear') {
            @rename($log, $log.'.'.date('Ymd_His').'.archived');
            $output->stdout("Журнал вироків заархівовано.\n");

            return 0;
        }

        $rows = [];
        foreach (file($log, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $entry = json_decode($line, true);
            if (is_array($entry)) {
                $rows[] = $entry;
            }
        }

        if ($mode === '--list') {
            foreach ($rows as $entry) {
                $output->stdout(sprintf(
                    "%s  %s  %3d%%  вирок=%-10s застосовано=%-10s QA=%s/%s\n    %s\n",
                    Clock::stamp($entry['at'] ?? null),
                    substr((string) ($entry['identity_hash'] ?? ''), 0, 12),
                    $entry['confidence'] ?? 0,
                    $entry['verdict'] ?? '?',
                    $entry['applied'] ?? '?',
                    $entry['qa_status'] ?? '?',
                    $entry['qa_severity'] ?? '?',
                    str_replace("\n", ' ', substr((string) ($entry['reason'] ?? ''), 0, 160)),
                ));
            }

            return 0;
        }

        if ($rows === []) {
            $output->stdout("Журнал порожній.\n");

            return 0;
        }

        $applied = ['ai_layer' => 0, 'moderation' => 0];
        $overridden = 0;
        $buckets = ['0-49' => 0, '50-69' => 0, '70-84' => 0, '85-94' => 0, '95-100' => 0];
        foreach ($rows as $entry) {
            $key = (string) ($entry['applied'] ?? 'moderation');
            $applied[$key] = ($applied[$key] ?? 0) + 1;
            if (($entry['verdict'] ?? '') !== ($entry['applied'] ?? '')) {
                $overridden++;
            }
            $confidence = (int) ($entry['confidence'] ?? 0);
            $bucket = $confidence < 50 ? '0-49'
                : ($confidence < 70 ? '50-69'
                    : ($confidence < 85 ? '70-84'
                        : ($confidence < 95 ? '85-94' : '95-100')));
            $buckets[$bucket]++;
        }
        $output->stdout(sprintf(
            "Вироків: %d | у ШІ-шар: %d | до людини: %d | поріг або механіка перебили вирок: %d\n",
            count($rows),
            $applied['ai_layer'] ?? 0,
            $applied['moderation'] ?? 0,
            $overridden,
        ));
        $output->stdout("Розподіл упевненості:\n");
        foreach ($buckets as $range => $count) {
            $output->stdout(sprintf("  %-7s %s %d\n", $range, str_repeat('#', min(40, $count)), $count));
        }

        $degenerate = JudgePolicy::degenerate($rows);
        if ($degenerate === null) {
            $output->stdout("\nВибірка ще мала для висновку про якість суддівства (треба щонайменше 20 вироків).\n");
        } elseif ($degenerate) {
            $output->stdout("\nУВАГА: суддя пропускає у шар понад 90% спірних рядків · він більше не розрізняє.\n");
            $output->stdout("Це лікується промптом ролі або іншою моделлю, а не порогом.\n");
        } else {
            $output->stdout("\nСуддя розрізняє: частка ШІ-шару в межах норми.\n");
        }
        $output->stdout("\nКалібрування: звіряйте ці вироки з рішеннями людини в ./bdo moderation.\n");
        $output->stdout("Поріг задає BDO_JUDGE_MIN_CONFIDENCE у .env (1-100, типово 65; нижче = менше модерації).\n");

        return 0;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Що вирішував суддя і чи можна йому вірити.

  ./bdo judge              зведення й перевірка на виродження
  ./bdo judge --list       останні вироки повністю
  ./bdo judge --clear      архівувати журнал

Читає state/judge-decisions.jsonl. Поріг задає BDO_JUDGE_MIN_CONFIDENCE у .env.
TEXT;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
}
