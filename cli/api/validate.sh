#!/usr/bin/env bash
# Перевірити переклади через POST /translations/validate (без запису).
#
# Використання:
#   ./validate.sh <items.json>
#
# Формат items.json:
#   [{"identity_hash": "...", "text": "переклад"}, ...]
#
# Вихід: ./output/validate_YYYYMMDD_HHMMSS.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/cli/system/select-env.sh"

INPUT="${1:?Потрібен файл items.json}"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

mkdir -p "$SCRIPT_DIR/output"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT="$SCRIPT_DIR/output/validate_${TIMESTAMP}.json"

# Формуємо payload
php -r '
require $argv[3];
use Bdo\Translate\Api\WritePayload;

$items = json_decode((string) file_get_contents($argv[1]), true);
if (!is_array($items)) $items = [];
try {
    WritePayload::assertItems($items);
} catch (RuntimeException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
file_put_contents($argv[2], json_encode(
    ["layer" => "machine", "auto_repair" => true, "items" => $items], JSON_UNESCAPED_UNICODE));
echo "Підготовлено " . count($items) . " елементів\n";
' "$INPUT" "$OUT" "$SCRIPT_DIR/lib/autoload.php"

echo "Перевіряю..."
RESPONSE=$("$SCRIPT_DIR/cli/api/http-request.sh" -fsS -X POST \
    -H "X-API-Key: $KEY" \
    -H "Content-Type: application/json" \
    --data @"$OUT" \
    "$API/translations/validate")

echo "$RESPONSE" > "$OUT"

echo ""
php -r '
require $argv[2];
use Bdo\Translate\Api\Response;

$response = Response::fromFile($argv[1], "POST /translations/validate");
$results = $response->results();
$counts = $response->statusCounts();

printf("Результат: ok=%d  rejected=%d  unchanged=%d  total=%d\n",
    $counts["ok"] + $counts["repaired"], $counts["rejected"], $counts["unchanged"], $counts["total"]);

foreach ($results as $r) {
    $status = (string) ($r["status"] ?? "");
    $idx = $r["index"] ?? "?";
    if ($status === "ok") {
        printf("  [%s] OK\n", $idx);
    } elseif ($status === "repaired") {
        printf("  [%s] REPAIRED: %s\n", $idx, implode("; ", $r["repairs"] ?? []));
        printf("         текст: %s\n", mb_substr((string) ($r["repaired_text"] ?? ""), 0, 80));
    } elseif ($status === "unchanged") {
        printf("  [%s] UNCHANGED\n", $idx);
    } else {
        printf("  [%s] %s: %s\n", $idx, strtoupper($status), mb_substr((string) ($r["message"] ?? ""), 0, 100));
        if (!empty($r["code"])) printf("         code=%s\n", $r["code"]);
    }
}

$warning = $response->meta()["batch_quality_warning"] ?? null;
if ($warning) {
    printf("\n  УВАГА: відкинуто %s%% - зламався промпт?\n", ($warning["rejected_ratio"] ?? 0) * 100);
}
' "$OUT" "$SCRIPT_DIR/lib/autoload.php"

echo ""
echo "Деталі: $OUT"
