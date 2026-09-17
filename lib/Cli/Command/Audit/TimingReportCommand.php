<?php

declare(strict_types=1);

namespace Bdo\Translate\Cli\Command\Audit;

use Bdo\Translate\Cli\Command;
use Bdo\Translate\Cli\CommandHelp;
use Bdo\Translate\Cli\Output;
use Bdo\Translate\Run\StepTimes;

/**
 * Куди пішов час прогону · не лише в модель.
 *
 * Навіщо. `state/model-calls.jsonl` знає рівно час МОДЕЛІ, і на цьому
 * 2026-09-05 народилась хибна заява, що третина часу пачки йде кудись іще.
 * Мітки кроків її спростували: у неперервному прогоні на дві пачки модель бере
 * 89% часу, решта кроків 11%. Розриви, які виглядали накладними витратами,
 * були паузами між окремими запусками `--batches 1`.
 *
 * Це порт `cli/audit/timing-report.sh`: shell там був лише розбором одного
 * аргумента навколо того самого PHP, тому вивід лишається дослівним.
 */
final class TimingReportCommand implements Command, CommandHelp
{
    public function execute(array $arguments, Output $output): int
    {
        $last = 3;
        $first = (string) ($arguments[0] ?? '');
        if ($first === '--all') {
            $last = 0;
        } elseif ($first !== '') {
            // Тільки цифри. `preg_match` тут чесніший за `(int)`: той мовчки
            // перетворив би `3abc` на 3 і показав звіт не про те, що просили.
            if (preg_match('/^[0-9]+$/', $first) !== 1) {
                $output->stderr(sprintf("timing: потрібне число пачок або --all, отримано «%s»\n", $first));

                return 2;
            }
            $last = (int) $first;
        }

        $times = new StepTimes($this->stateDir());
        if (! is_file($times->path())) {
            $output->stdout("Міток часу ще немає: вони зʼявляться після першого прогону з цією версією.\n");
            $output->stdout('Журнал: '.$times->path()."\n");

            return 0;
        }
        $report = $times->report($last);
        if ($report['steps'] === []) {
            $output->stdout("Журнал міток порожній · прогонів у ньому немає.\n");

            return 0;
        }

        $total = $report['total_ms'];
        $scope = $last > 0 ? "останні $last пачок" : 'увесь журнал';
        $output->stdout(sprintf("\nКУДИ ПІШОВ ЧАС · %s\n\n", $scope));
        $output->stdout(sprintf("  %-26s %8s %7s %6s  %s\n", 'крок', 'секунд', 'частка', 'разів', ''));
        foreach ($report['steps'] as $step) {
            $share = $total > 0 ? 100 * $step['ms'] / $total : 0;
            $bar = str_repeat('█', max(0, (int) round($share / 4)));
            $output->stdout(sprintf(
                "  %-26s %8.0f %6.1f%% %6d  %s%s\n",
                $step['step'],
                $step['ms'] / 1000,
                $share,
                $step['calls'],
                $bar,
                $step['failed'] > 0 ? sprintf('  (відмов %d)', $step['failed']) : '',
            ));
        }

        // Головне число · те, заради якого мітки й зʼявились.
        $model = $report['model_ms'];
        $other = $report['other_ms'];
        $output->stdout(sprintf(
            "\n  усього %.0f с; модель %.0f с (%.0f%%), решта %.0f с (%.0f%%)\n",
            $total / 1000,
            $model / 1000,
            $total > 0 ? 100 * $model / $total : 0,
            $other / 1000,
            $total > 0 ? 100 * $other / $total : 0,
        ));
        $output->stdout("\n  «модель» береться з state/model-calls.jsonl, «решта» · сума міток,\n");
        $output->stdout("  які не є викликом моделі (відніманням рахувати не можна: втрачена\n");
        $output->stdout("  мітка тоді тихо зменшує «решту» · так і сталось у D81).\n");
        $output->stdout("  Крок `drive` це вся механіка пачки між викликами моделі;\n");
        $output->stdout("  `mode.start` · відбір наступної пачки з API.\n\n");

        return 0;
    }

    public static function help(): string
    {
        return <<<'TEXT'
Куди пішов час прогону · не лише в модель.

  ./bdo timing            останні 3 пачки
  ./bdo timing 10         останні 10 пачок
  ./bdo timing --all      усе, що є в журналі

Читає state/step-times.jsonl і state/model-calls.jsonl. Нічого не змінює.
TEXT;
    }

    private function stateDir(): string
    {
        return getenv('BDO_STATE_DIR') ?: dirname(__DIR__, 4).'/state';
    }
}
