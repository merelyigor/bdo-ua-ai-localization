#!/usr/bin/env bash
# Що вирішував суддя і чи можна йому вірити.
#
#   ./judge-report.sh              зведення й перевірка на виродження
#   ./judge-report.sh --list       останні вироки повністю
#   ./judge-report.sh --clear      архівувати журнал
#
# Журнал пише `cli/batch/batch-commit.sh` під час застосування вироків. Тут лише
# читання. Мета · калібрування: поріг `BDO_JUDGE_MIN_CONFIDENCE` має спиратися на
# те, як вироки збігаються з рішеннями людини в модерації, а не на відчуття.
#
# Окремо перевіряється ВИРОДЖЕННЯ: суддя, який пропускає у шар майже все, не
# судить, а штампує. Це видно лише на журналі, тому висновок зʼявляється, коли
# вибірка достатня.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
LOG="$STATE_DIR/judge-decisions.jsonl"
MODE="${1:-summary}"

test -f "$LOG" || { echo "Суддя ще не ухвалював рішень: $LOG не створено."; exit 0; }

case "$MODE" in
    --clear)
        mv "$LOG" "$LOG.$(date +%Y%m%d_%H%M%S).archived"
        echo "Журнал вироків заархівовано."
        ;;
    --list)
        php -r '
        foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            $e = json_decode($line, true);
            if (! is_array($e)) continue;
            printf("%s  %s  %3d%%  вирок=%-10s застосовано=%-10s QA=%s/%s\n    %s\n",
                $e["at"] ?? "?", substr((string) ($e["identity_hash"] ?? ""), 0, 12),
                $e["confidence"] ?? 0, $e["verdict"] ?? "?", $e["applied"] ?? "?",
                $e["qa_status"] ?? "?", $e["qa_severity"] ?? "?",
                str_replace("\n", " ", substr((string) ($e["reason"] ?? ""), 0, 160)));
        }' "$LOG"
        ;;
    summary)
        php -r '
        require $argv[2];
        use Bdo\Translate\Pipeline\JudgePolicy;

        $rows = [];
        foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            $e = json_decode($line, true);
            if (is_array($e)) $rows[] = $e;
        }
        if ($rows === []) { echo "Журнал порожній.\n"; exit(0); }

        $applied = ["ai_layer" => 0, "moderation" => 0];
        $overridden = 0;
        $buckets = ["0-49" => 0, "50-69" => 0, "70-84" => 0, "85-94" => 0, "95-100" => 0];
        foreach ($rows as $e) {
            $applied[$e["applied"] ?? "moderation"] = ($applied[$e["applied"] ?? "moderation"] ?? 0) + 1;
            if (($e["verdict"] ?? "") !== ($e["applied"] ?? "")) $overridden++;
            $c = (int) ($e["confidence"] ?? 0);
            $key = $c < 50 ? "0-49" : ($c < 70 ? "50-69" : ($c < 85 ? "70-84" : ($c < 95 ? "85-94" : "95-100")));
            $buckets[$key]++;
        }
        printf("Вироків: %d | у ШІ-шар: %d | до людини: %d | поріг або механіка перебили вирок: %d\n",
            count($rows), $applied["ai_layer"] ?? 0, $applied["moderation"] ?? 0, $overridden);
        echo "Розподіл упевненості:\n";
        foreach ($buckets as $range => $n) printf("  %-7s %s %d\n", $range, str_repeat("#", min(40, $n)), $n);

        $degenerate = JudgePolicy::degenerate($rows);
        if ($degenerate === null) {
            printf("\nВибірка ще мала для висновку про якість суддівства (треба щонайменше 20 вироків).\n");
        } elseif ($degenerate) {
            printf("\nУВАГА: суддя пропускає у шар понад 90%% спірних рядків · він більше не розрізняє.\n");
            printf("Це лікується промптом ролі або іншою моделлю, а не порогом.\n");
        } else {
            printf("\nСуддя розрізняє: частка ШІ-шару в межах норми.\n");
        }
        echo "\nКалібрування: звіряйте ці вироки з рішеннями людини в ./bdo moderation.\n";
        echo "Поріг задає BDO_JUDGE_MIN_CONFIDENCE у .env (1-100, типово 65; нижче = менше модерації).\n";
        ' "$LOG" "$SCRIPT_DIR/lib/autoload.php"
        ;;
    *) echo "Дозволено: (без аргументів) | --list | --clear" >&2; exit 2 ;;
esac
