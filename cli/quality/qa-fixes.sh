#!/usr/bin/env bash
# Витягти БЕЗПЕЧНІ виправлення з вердиктів QA у формат для cli/quality/merge-items.sh.
#
#   ./qa-fixes.sh verdicts.json rows.json candidate.json > fixes.json
#
# QA повертає в полі fix повний виправлений текст, тож лікування зазвичай не
# потребує ще одного виклику моделі. АЛЕ довіряти цьому полю наосліп не можна:
# на живому прогоні 4 з 6 fix виявились зіпсованим текстом («Сутінки Кінця -
# Сережки» -> «Суттинки Слитинця - Серінка»), і сліпе застосування замінило б
# добрі переклади кашею. Модель судить краще, ніж переписує.
#
# Кожен fix проходить детерміновані перевірки з Quality\FixPolicy і потрапляє у
# вихід, лише якщо пройшов усі. Відхилені рядки віддаються translation-repair.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VERDICT_FILE="${1:?Потрібен verdicts.json від translation-qa}"
ROWS_FILE="${2:?Потрібен rows.json}"
CAND_FILE="${3:?Потрібен candidate.json}"
for f in "$VERDICT_FILE" "$ROWS_FILE" "$CAND_FILE"; do
    test -f "$f" || { echo "Немає файлу: $f" >&2; exit 1; }
done

php -r '
require $argv[4];
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\FixPolicy;
use Bdo\Translate\Quality\VerdictSet;

$verdicts = VerdictSet::fromFile($argv[1]);
$rows = RowSet::fromFile($argv[2]);
$candidate = Candidate::fromFile($argv[3]);
$fixSeen = $verdicts->fixFrequency();

$accepted = []; $rejected = []; $pass = 0; $noFix = 0;
foreach ($verdicts as $v) {
    $hash = $v["identity_hash"] ?? "";
    if (($v["status"] ?? "") === "PASS") { $pass++; continue; }
    $fix = trim((string) ($v["fix"] ?? ""));
    if ($fix === "") { $noFix++; $rejected[] = [$hash, "порожній fix"]; continue; }

    $why = FixPolicy::rejections(
        $rows->getOrEmpty($hash),
        $candidate->text($hash),
        $fix,
        $fixSeen[$fix] ?? 1
    );

    if ($why === []) {
        $accepted[] = ["identity_hash" => $hash, "text" => $fix];
    } else {
        $rejected[] = [$hash, implode("; ", $why)];
    }
}

fprintf(STDERR, "PASS: %d | fix прийнято: %d | fix відхилено: %d (з них порожніх: %d)\n",
    $pass, count($accepted), count($rejected), $noFix);

// Причини відмов · у журнал, а не лише в stderr пачки.
//
// FixPolicy вирішує, скільки рядків піде в окремий прохід translation-repair:
// 2026-08-27 вона пропустила 13 fix із 50, решта 37 стали повним додатковим
// проходом моделі. Налаштовувати поріг можна лише на даних, а stderr пачки
// зникає разом із пачкою при автоочистці.
$stateDir = getenv("BDO_STATE_DIR") ?: dirname(__DIR__, 2)."/state";
if (is_dir($stateDir)) {
    $histogram = [];
    foreach ($rejected as [$hash, $why]) {
        foreach (explode("; ", $why) as $reason) {
            $reason = trim($reason);
            if ($reason !== "") $histogram[$reason] = ($histogram[$reason] ?? 0) + 1;
        }
    }
    arsort($histogram);
    @file_put_contents($stateDir."/fix-policy.jsonl", json_encode([
        "at" => gmdate("c"),
        "pass" => $pass,
        "accepted" => count($accepted),
        "rejected" => count($rejected),
        "empty_fix" => $noFix,
        "reasons" => $histogram,
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND);
}
foreach ($rejected as [$hash, $why]) fprintf(STDERR, "  %s  %s\n", substr($hash, 0, 12), $why);
if ($accepted === []) {
    fwrite(STDERR, "\nВИРОК: безпечних виправлень немає. Відхилені рядки - у translation-repair.\n");
} else {
    fprintf(STDERR, "\nВИРОК: cli/quality/merge-items.sh на %d рядках, потім повторні validate і QA по них.\n", count($accepted));
    if ($rejected !== []) fwrite(STDERR, "Решту - у translation-repair, не в merge.\n");
}
echo json_encode($accepted, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
' "$VERDICT_FILE" "$ROWS_FILE" "$CAND_FILE" "$SCRIPT_DIR/lib/autoload.php"
