#!/usr/bin/env bash
# Закрити памʼяттю те, що вже перекладено, і лишити моделі тільки решту.
#
#   ./memory-apply.sh rows.json memory.json
#
# Робить три речі, кожна з яких економить виклик моделі й тримає корпус
# узгодженим:
#   1. точний збіг оригіналу з памʼяті підставляється як готовий переклад;
#   2. однакові оригінали ВСЕРЕДИНІ пачки перекладаються один раз, решті
#      підставляється той самий текст (twins.json);
#   3. кожен підставлений текст проходить ті самі механічні перевірки, що й
#      машинний, - чужий переклад не звільняється від контролю. Рядок, який їх
#      не пройшов, повертається моделі.
#
# Пише в теку пачки: memory-candidate.json (готове), to-translate.json (для моделі,
# у форматі rows.json), twins.json (кого заповнити після воркера).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json}"
MEMORY_FILE="${2:?Потрібен memory.json від cli/prepare/memory-lookup.sh}"
BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
if [ -z "$BATCH_DIR" ]; then
    echo "Пачку не розпочато: ./bdo batch new rows.json" >&2
    exit 1
fi
"$SCRIPT_DIR/cli/batch/batch-assert.sh" "$ROWS_FILE" >/dev/null

php -r '
require $argv[1];
use Bdo\Translate\Batch\Memory;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\Defects;

$rows = RowSet::fromFile($argv[2]);
$memory = Memory::fromFile($argv[3]);

$ready = [];      // identity_hash => текст із памʼяті
$rejected = [];   // памʼять є, але текст не проходить перевірки цього рядка
$twins = [];      // близнюк => представник у цій самій пачці
$representative = [];
$forModel = [];

foreach ($rows as $row) {
    $hash = $row->identityHash();
    $best = $memory->best($hash);
    if ($best !== null) {
        $text = (string) $best["text"];
        $defects = Defects::inTranslation($row, $text);
        if ($defects === []) {
            $ready[$hash] = ["text" => $text, "layer" => $best["layer"] ?? "?"];
            continue;
        }
        $rejected[$hash] = $defects;
    }
    // Дублікати всередині пачки: той самий оригінал перекладаємо один раз.
    $sourceKey = hash("sha256", $row->sourceText());
    if (isset($representative[$sourceKey])) {
        $twins[$hash] = $representative[$sourceKey];
        continue;
    }
    $representative[$sourceKey] = $hash;
    $forModel[] = $row->raw();
}

file_put_contents($argv[4], json_encode(
    array_map(static fn (string $h, array $v): array => ["identity_hash" => $h, "text" => $v["text"]],
        array_keys($ready), array_values($ready)),
    JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT
));
file_put_contents($argv[5], json_encode(["data" => ["rows" => $forModel]], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
file_put_contents($argv[6], json_encode($twins, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

$total = count($rows);
printf("Рядків у пачці: %d (памʼять: шари %s)\n", $total, getenv("BDO_MEMORY_LAYERS") ?: "all");
printf("  закрито памʼяттю:            %d\n", count($ready));
printf("  дублі всередині пачки:       %d\n", count($twins));
printf("  памʼять відхилено перевірками: %d\n", count($rejected));
foreach ($rejected as $hash => $why) printf("    %s  %s\n", substr($hash, 0, 12), implode("; ", $why));
printf("  лишається моделі:            %d\n", count($forModel));
if ($forModel === []) {
    echo "\nВИРОК: модель не потрібна - пачка закрита памʼяттю. Далі build-items і запис.\n";
} else {
    printf("\nВИРОК: схему й payload будуй на to-translate.json (%d рядків), не на всій пачці.\n", count($forModel));
    echo "Після воркера: ./bdo memory expand <candidate> twins.json memory-candidate.json > full.json\n";
}
' "$SCRIPT_DIR/lib/autoload.php" "$ROWS_FILE" "$MEMORY_FILE" \
  "$BATCH_DIR/memory-candidate.json" "$BATCH_DIR/to-translate.json" "$BATCH_DIR/twins.json"
