#!/usr/bin/env bash
# Накласти вердикти контрольного QA поверх первинних.
#
#   ./merge-verdicts.sh verdicts.json control-verdicts.json > final.json
#
# Контрольний QA перевіряє лише виправлені рядки, але batch-commit.sh вимагає
# рівно один вердикт на КОЖЕН рядок пачки (інакше qa_incomplete). Тому фінальний
# набір - первинні вердикти, у яких перевірені повторно рядки замінені новими.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_FILE="${1:?Потрібен verdicts.json (повна пачка)}"
OVERLAY_FILE="${2:?Потрібен verdicts контрольного QA}"

php -r '
require $argv[1];
use Bdo\Translate\Quality\VerdictSet;

$base = iterator_to_array(VerdictSet::fromFile($argv[2]));
$overlay = [];
foreach (VerdictSet::fromFile($argv[3]) as $v) {
    $overlay[$v["identity_hash"] ?? ""] = $v;
}
$replaced = 0;
foreach ($base as $i => $v) {
    $hash = $v["identity_hash"] ?? "";
    if (isset($overlay[$hash])) { $base[$i] = $overlay[$hash]; $replaced++; }
}
fprintf(STDERR, "Вердиктів: %d | замінено контрольним QA: %d\n", count($base), $replaced);
echo json_encode(array_values($base), JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), "\n";
' "$SCRIPT_DIR/lib/autoload.php" "$BASE_FILE" "$OVERLAY_FILE"
