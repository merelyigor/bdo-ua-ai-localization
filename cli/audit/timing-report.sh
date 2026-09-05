#!/usr/bin/env bash
# Куди пішов час прогону · не лише в модель.
#
#   ./bdo timing            останні 3 пачки
#   ./bdo timing 10         останні 10 пачок
#   ./bdo timing --all      усе, що є в журналі
#
# Навіщо. `state/model-calls.jsonl` знає рівно час МОДЕЛІ, і на цьому 2026-09-05
# народилась хибна заява, що третина часу пачки йде кудись іще. Мітки
# (`cli/system/timed.sh`) її спростували: у неперервному прогоні на дві пачки
# модель бере 89% часу, решта кроків 11%. Розриви, які виглядали накладними
# витратами, були паузами між окремими запусками `--batches 1`.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"

LAST=3
case "${1:-}" in
    '') ;;
    --all) LAST=0 ;;
    *[!0-9]*) printf 'timing: потрібне число пачок або --all, отримано «%s»\n' "$1" >&2; exit 2 ;;
    *) LAST="$1" ;;
esac

php -r '
require $argv[1];

use Bdo\Translate\Run\StepTimes;

$times = new StepTimes($argv[2]);
$last = (int) $argv[3];
if (! is_file($times->path())) {
    echo "Міток часу ще немає: вони зʼявляться після першого прогону з цією версією.\n";
    echo "Журнал: ", $times->path(), "\n";
    exit(0);
}
$report = $times->report($last);
if ($report["steps"] === []) {
    echo "Журнал міток порожній · прогонів у ньому немає.\n";
    exit(0);
}

$total = $report["total_ms"];
$scope = $last > 0 ? "останні $last пачок" : "увесь журнал";
printf("\nКУДИ ПІШОВ ЧАС · %s\n\n", $scope);
printf("  %-26s %8s %7s %6s  %s\n", "крок", "секунд", "частка", "разів", "");
foreach ($report["steps"] as $step) {
    $share = $total > 0 ? 100 * $step["ms"] / $total : 0;
    $bar = str_repeat("█", max(0, (int) round($share / 4)));
    printf("  %-26s %8.0f %6.1f%% %6d  %s%s\n",
        $step["step"], $step["ms"] / 1000, $share, $step["calls"], $bar,
        $step["failed"] > 0 ? sprintf("  (відмов %d)", $step["failed"]) : "");
}

// Головне число · те, заради якого мітки й зʼявились.
$model = $report["model_ms"];
$other = $report["other_ms"];
printf("\n  усього %.0f с; модель %.0f с (%.0f%%), решта %.0f с (%.0f%%)\n",
    $total / 1000, $model / 1000, $total > 0 ? 100 * $model / $total : 0,
    $other / 1000, $total > 0 ? 100 * $other / $total : 0);
echo "\n  «модель» береться з state/model-calls.jsonl, «решта» · сума міток,\n";
echo "  які не є викликом моделі (відніманням рахувати не можна: втрачена\n";
echo "  мітка тоді тихо зменшує «решту» · так і сталось у D81).\n";
echo "  Крок `drive` це вся механіка пачки між викликами моделі;\n";
echo "  `mode.start` · відбір наступної пачки з API.\n\n";
' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$LAST"
