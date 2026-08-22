#!/usr/bin/env bash
# Вирізати підмножину рядків із rows.json для повтору лише проблемної частини пачки.
#
#   ./subset-rows.sh rows.json hash1,hash2,... subset.json
#
# Вихід має ту саму структуру {data:{rows:[...]}}, тому cli/prepare/build-schema.sh і
# cli/prepare/worker-payload.sh працюють із ним без змін. Невідомий хеш - помилка, щоб
# повтор не розійшовся з реальною пачкою.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"
HASHES="${2:?Потрібен перелік identity_hash через кому}"
OUTPUT_FILE="${3:?Потрібен вихідний subset.json}"

php -r '
require $argv[4];
use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1])->toRawList();
$wanted = array_fill_keys(array_filter(array_map("trim", explode(",", $argv[2]))), false);
if ($wanted === []) throw new RuntimeException("Порожній перелік хешів");
$subset = [];
foreach ($rows as $row) {
    $hash = $row["identity_hash"] ?? "";
    if (array_key_exists($hash, $wanted)) {
        $wanted[$hash] = true;
        $subset[] = $row;
    }
}
$missing = array_keys(array_filter($wanted, static fn ($found) => !$found));
if ($missing !== []) throw new RuntimeException("Хеші відсутні в rows.json: " . implode(",", $missing));
file_put_contents($argv[3], json_encode(["data" => ["rows" => $subset]], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
echo "Підмножина: " . count($subset) . " рядків із " . count($rows) . "\n";
' "$ROWS_FILE" "$HASHES" "$OUTPUT_FILE" "$SCRIPT_DIR/lib/autoload.php"
