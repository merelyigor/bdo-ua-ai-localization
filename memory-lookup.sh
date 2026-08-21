#!/usr/bin/env bash
# Спитати API, чи цей самий англійський оригінал уже перекладено деінде.
#
#   ./memory-lookup.sh rows.json [memory.json]
#
# Виміряно на живій базі: 80,9% неперекладених активних рядків мають точний збіг
# оригіналу серед уже перекладених; на реальних вибірках агента - 25%. Але
# головне не економія викликів моделі, а узгодженість: без цього кроку воркер
# вигадує свій варіант там, де в проєкті вже є усталений.
#
# Читання: денної квоти рядків не витрачає.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/select-env.sh"

ROWS_FILE="${1:?Потрібен rows.json}"
OUT_FILE="${2:-}"
if [ -z "$OUT_FILE" ]; then
    BATCH_DIR="$("$SCRIPT_DIR/batch-dir.sh" 2>/dev/null || true)"
    OUT_FILE="${BATCH_DIR:-${BDO_STATE_DIR:-$SCRIPT_DIR/state}}/memory.json"
fi

TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT

# Запит розбивається на частини: ендпоінт має ту саму стелю 50, що й запис, а
# вибірка може бути більшою (наприклад, при вимірюваннях).
php -r '
require $argv[1];
use Bdo\Translate\Batch\RowSet;
$hashes = RowSet::fromFile($argv[2])->identityHashes();
$i = 0;
foreach (array_chunk($hashes, 50) as $chunk) {
    file_put_contents(sprintf("%s/req-%02d.json", $argv[3], $i),
        json_encode(["identity_hashes" => $chunk], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
    $i++;
}
' "$SCRIPT_DIR/lib/autoload.php" "$ROWS_FILE" "$TMP_DIR"

for req in "$TMP_DIR"/req-*.json; do
    curl -fsS -X POST -H "X-API-Key: $BDO_API_KEY" -H 'Content-Type: application/json' \
        --data-binary "@$req" "$BDO_API_BASE/translations/memory" -o "${req%.json}.resp.json"
done

php -r '
require $argv[1];
use Bdo\Translate\Api\Response;
$memory = []; $requested = 0;
foreach (glob($argv[2] . "/req-*.resp.json") as $file) {
    $response = Response::fromFile($file, "translations/memory");
    $memory += $response->data()["memory"] ?? [];
    $requested += (int) ($response->meta()["requested"] ?? 0);
}
file_put_contents($argv[3], json_encode(
    ["data" => ["memory" => $memory], "meta" => ["requested" => $requested, "with_memory" => count($memory)]],
    JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT
));
printf("Рядків запитано: %d | мають готовий переклад: %d (%.0f%%)\n",
    $requested, count($memory), $requested ? count($memory) * 100 / $requested : 0);
' "$SCRIPT_DIR/lib/autoload.php" "$TMP_DIR" "$OUT_FILE"
echo "Памʼять: $OUT_FILE"
