#!/usr/bin/env bash
# Показати перекладені приклади з тим самим підтвердженим терміном.
#
# Використання:
#   ./row-context.sh <identity_hash>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/cli/system/select-env.sh"

IDENTITY_HASH="${1:?Потрібен identity_hash рядка}"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

if [[ ! "$IDENTITY_HASH" =~ ^[0-9a-f]{64}$ ]]; then
    echo "identity_hash має складатися з 64 малих hex-символів." >&2
    exit 1
fi

RESPONSE_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE"' EXIT

curl -fsS -H "X-API-Key: $KEY" "$API/rows/$IDENTITY_HASH/context" > "$RESPONSE_FILE"

php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "rows/{hash}/context")->raw();
$context = $d["data"]["context"] ?? [];
if (empty($context["indexed"])) {
    echo "Граф згадок для цього рядка ще не індексований. Контексту не вгадуємо.\n";
    exit;
}

$terms = $context["terms"] ?? [];
echo "Підтверджені терміни: " . count($terms) . "\n";
foreach ($terms as $term) {
    $source = $term["canonical_source"] ?? $term["matched_text"] ?? "?";
    $ukrainian = $term["ukrainian"] ?? "немає відповідника";
    echo "  $source → $ukrainian\n";
}

$examples = $context["related_rows"] ?? [];
echo "\nПерекладені приклади: " . count($examples) . "\n";
foreach ($examples as $index => $row) {
    $translation = $row["translation"] ?? [];
    $terms = array_map(static fn (array $term): string => $term["canonical_source"], $row["matching_terms"] ?? []);
    $number = $index + 1;
    echo "\n[$number] " . ($row["source_text"] ?? "") . "\n";
    echo "  UA (" . ($translation["layer"] ?? "?") . ", " . ($translation["freshness"] ?? "?") . "): " . ($translation["text"] ?? "") . "\n";
    echo "  Зв\047язок: " . implode(", ", $terms) . "\n";
}
' "$RESPONSE_FILE" "$SCRIPT_DIR/lib/autoload.php"
