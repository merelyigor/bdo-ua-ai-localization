#!/usr/bin/env bash
# Показати завантажені рядки у зручному вигляді для перекладу/перевірки.
#
# Використання:
#   ./show-rows.sh <шлях_до_файлу.json> [кількість]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

FILE="${1:?Потрібен шлях до JSON-файлу (cli/api/fetch-rows.sh)}"
LIMIT="${2:-0}"

php -r '
require $argv[3];
$file = $argv[1];
$limit = (int) $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($file, "rows")->raw();
$rows = $d["data"]["rows"] ?? [];
if ($limit > 0) $rows = array_slice($rows, 0, $limit);

echo "=== Рядки для перекладу: " . count($rows) . " ===\n\n";

foreach ($rows as $i => $r) {
    $src = $r["source_text"];
    $h = mb_substr($r["identity_hash"], 0, 12);
    $dom = $r["classification"]["domain"] ?? "?";
    $st = $r["classification"]["semantic_type"] ?? "?";
    $tokens = $r["tokens"]["must_preserve"] ?? [];
    $length = $r["constraints"]["length"] ?? [];
    $glossary = ($r["glossary"]["terms"] ?? []);
    $ref = $r["reference"]["text"] ?? "";
    $n = $i + 1;

    echo "--- [$n] $h... (ordinal=" . ($r["ordinal"] ?? "?") . ") ---\n";
    echo "  Domain: $dom  |  Type: $st\n";
    echo "  EN: $src\n";

    if ($ref) echo "  REF: $ref\n";

    $manual = $r["layers"]["manual"]["text"] ?? "";
    $machine = $r["layers"]["machine"]["text"] ?? "";
    if ($manual) echo "  UA (manual): $manual\n";
    elseif ($machine) echo "  UA (machine): $machine\n";

    $known = array_filter($glossary, fn($t) => !empty($t["ukrainian"]) && empty($t["ambiguous"]));
    $ambig = array_filter($glossary, fn($t) => !empty($t["ambiguous"]));
    if ($known) {
        $parts = array_map(fn($t) => $t["canonical_source"] . "=" . $t["ukrainian"], $known);
        echo "  Глосарій: " . implode(", ", $parts) . "\n";
    }
    if ($ambig) {
        $parts = array_map(fn($t) => $t["canonical_source"] ?? "?", $ambig);
        echo "  Неоднозначні: " . implode(", ", $parts) . "\n";
    }

    if ($tokens) {
        $parts = array_map(fn($t, $n) => "$t x$n", array_keys($tokens), $tokens);
        echo "  Токени: " . implode(", ", $parts) . "\n";
    }

    if (!empty($length["enforced"])) {
        echo "  Довжина: " . $length["min_chars"] . "-" . $length["max_chars"] . " (джерело: " . $length["source_chars"] . ")\n";
    } elseif (!empty($length["min_chars"])) {
        echo "  Довжина (підказка): " . $length["min_chars"] . "-" . $length["max_chars"] . "\n";
    }

    echo "\n";
}
' "$FILE" "$LIMIT" "$SCRIPT_DIR/lib/autoload.php"
