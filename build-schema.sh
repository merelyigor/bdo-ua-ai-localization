#!/usr/bin/env bash
# Створити JSON Schema для constrained decoding із rows.json і поставити її як активну.
#
# Схема робить структурно неможливим втратити або вигадати identity_hash: список хешів
# задається enum, а довжина масиву фіксується. Формат виходу моделі збігається з тим,
# що очікує build-items.sh, тому перепакування не потрібне.
#
# Використання:
#   ./build-schema.sh rows.json          # схема для worker/repair
#   ./build-schema.sh --qa rows.json     # схема для translation-qa (статус на КОЖЕН рядок)
#   ./build-schema.sh --clear            # зняти обидві схеми
#   ./build-schema.sh --show             # показати активні схеми
#   ./build-schema.sh --out FILE rows.json   # у свій файл, активну НЕ чіпати
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
# Активна схема НАВМИСНО спільна, а не в теці пачки: це вказівник «що зараз
# обмежене», і його читає плагін OpenCode за фіксованим шляхом. Застаріла схема
# від попередньої пачки не є діркою в ізоляції - вона себе виявляє одразу, бо
# фіксує довжину масиву й перелік identity в enum, тож на іншій пачці запит
# просто не проходить.
readonly ACTIVE="$SCRIPT_DIR/state/current-response-schema.json"
readonly ACTIVE_QA="$SCRIPT_DIR/state/current-qa-schema.json"
MODE=rows
OUT_FILE=""

while true; do
    case "${1:-}" in
        --clear)
            rm -f "$ACTIVE" "$ACTIVE_QA"
            echo "Схеми знято: worker/repair/qa відповідають без обмеження формату."
            exit 0
            ;;
        --show)
            found=0
            test -f "$ACTIVE" && { echo "--- worker/repair ---"; cat "$ACTIVE"; found=1; }
            test -f "$ACTIVE_QA" && { echo "--- qa ---"; cat "$ACTIVE_QA"; found=1; }
            # Запит стану, а не помилка: код 0 навіть коли нічого не поставлено,
            # інакше `./build-schema.sh --show && next-command` обриває ланцюг.
            test "$found" = 1 || echo "Активних схем немає."
            exit 0
            ;;
        --qa)
            MODE=qa
            shift
            ;;
        --out)
            # Схема у власний файл, БЕЗ підміни активної. Потрібно для вимірювань
            # (model-ab.sh): інакше бенчмарк затер би схему живої пачки, і
            # наступний виклик воркера пішов би з чужим набором identity.
            OUT_FILE="${2:?--out потребує шлях до файла}"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

ROWS_FILE="${1:?Потрібен rows.json з API}"
test -f "$ROWS_FILE" || { echo "Немає файлу: $ROWS_FILE" >&2; exit 1; }
TARGET="$ACTIVE"
test "$MODE" = qa && TARGET="$ACTIVE_QA"
if [ -n "$OUT_FILE" ]; then
    TARGET="$OUT_FILE"
else
    mkdir -p "$SCRIPT_DIR/state"
fi

php -r '
require $argv[4];
use Bdo\Translate\Batch\RowSet;

$hashes = RowSet::fromFile($argv[1])->identityHashes();
$count = count($hashes);

if ($argv[3] === "qa") {
    // Статус на КОЖЕН рядок: інакше QA повертає "PASS: 1" на пачку з 4 рядків.
    $properties = [
        "identity_hash" => ["type" => "string", "enum" => $hashes],
        "status" => ["type" => "string", "enum" => ["PASS", "REVIEW", "REJECT"]],
        "severity" => ["type" => "string", "enum" => ["none", "minor", "major", "critical"]],
        "issue" => ["type" => "string"],
        "fix" => ["type" => "string"],
    ];
    $required = ["identity_hash", "status", "severity", "issue", "fix"];
} else {
    $properties = [
        "identity_hash" => ["type" => "string", "enum" => $hashes],
        "text" => ["type" => "string", "minLength" => 1],
    ];
    $required = ["identity_hash", "text"];
}
$schema = [
    "type" => "array",
    "minItems" => $count,
    "maxItems" => $count,
    "items" => [
        "type" => "object",
        "properties" => $properties,
        "required" => $required,
        "additionalProperties" => false,
    ],
];
file_put_contents($argv[2], json_encode($schema, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
echo "Схему поставлено на $count рядків.\n";
' "$ROWS_FILE" "$TARGET" "$MODE" "$SCRIPT_DIR/lib/autoload.php"

if [ -n "$OUT_FILE" ]; then
    echo "Схема у файлі: $TARGET (активну схему не змінено)"
else
    echo "Активна схема: $TARGET"
    echo "Зняти після пачки: ./bdo schema clear"
fi
