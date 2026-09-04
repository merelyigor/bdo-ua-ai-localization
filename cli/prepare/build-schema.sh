#!/usr/bin/env bash
# Створити JSON Schema для constrained decoding із rows.json і поставити її як активну.
#
# Схема робить структурно неможливим втратити або вигадати identity_hash: список хешів
# задається enum, а довжина масиву фіксується. Формат виходу моделі збігається з тим,
# що очікує cli/quality/build-items.sh, тому перепакування не потрібне.
#
# Використання:
#   ./build-schema.sh rows.json          # схема для worker/repair
#   ./build-schema.sh --qa rows.json     # схема для translation-qa (статус на КОЖЕН рядок)
#   ./build-schema.sh --clear            # зняти обидві схеми
#   ./build-schema.sh --show             # показати активні схеми
#   ./build-schema.sh --out FILE rows.json   # у свій файл, активну НЕ чіпати
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly SCRIPT_DIR
# Активна схема НАВМИСНО спільна, а не в теці пачки: це вказівник «що зараз
# обмежене», і його читає `cli/model/client.php` за фіксованим шляхом.
#
# Твердження «застаріла схема себе виявляє одразу» виявилось хибним, і це
# коштувало власнику двох годин 2026-08-27. Схема будувалась один раз на
# переході `prepared`, тож пачка, яка вже висіла в `awaiting_worker`, назавжди
# лишалась зі СТАРИМ форматом: після виправлення формату smoke позеленів, а
# воркер падав далі, бо читав файл від 26 серпня з кореневим масивом. Провайдер
# відхиляв запит мовчки · нуль вхідних токенів і жодного тексту помилки.
# Тому `run drive` тепер перебудовує схему перед КОЖНОЮ емісією child
# (`ensure_schema`), а не один раз на переході `prepared`. BDO_STATE_DIR тут той самий, що й у решти скриптів:
# без нього тест, який будує схему, затирав би активну схему живої пачки.
readonly STATE_ROOT="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
readonly ACTIVE="$STATE_ROOT/current-response-schema.json"
readonly ACTIVE_QA="$STATE_ROOT/current-qa-schema.json"
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
            # (cli/runtime/model-ab.sh): інакше бенчмарк затер би схему живої пачки, і
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
    mkdir -p "$STATE_ROOT"
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
        "text" => ["type" => "string"],
    ];
    $required = ["identity_hash", "text"];
}
// Форма схеми обмежена НЕ смаком, а лімітами structured outputs.
//
// Перша версія була tuple-масивом (`items` списком схем, `minItems`/`maxItems`).
// Її не приймає жоден OpenAI-сумісний провайдер: корінь мусить бути обʼєктом, а
// цих ключів strict-режим не знає. Виміряно 2026-08-27 по базі OpenCode:
// `opencode-go` мав 0 успішних дитячих сесій із 3, `ollama-local` · 130 із 137,
// бо Ollama-runner до схеми поблажливий.
//
// Друга версія робила по одному полю `row_N` на рядок і теж була б відхилена:
// на пачці зі 100 рядків це 101 властивість у корені й глибина 6, тоді як
// documented ліміт · 100 властивостей і 5 рівнів. Тобто дефект просто переїхав
// би з малих пачок на великі, і саме так виглядає найгірший клас помилки.
//
// Ця форма стала від розміру пачки НЕ залежати: три властивості завжди.
// Перелік дозволених identity йде спільним `enum`, довжина якого росте, але
// 100 хешів це 6 400 символів проти ліміту 15 000.
//
// Гарантію унікальності тримає КОД, а не схема, і це перевірено:
// `cli/quality/build-items.sh --require-all` падає з «Дубль identity_hash» на
// повторі й з «не покрив» на пропуску. Саме цей гейт зловив дефект 2026-08-22,
// коли воркер повернув 13 обʼєктів з одним хешем · схема тоді «трималась».
$schema = [
    "type" => "object",
    "properties" => [
        "items" => [
            "type" => "array",
            "items" => [
                "type" => "object",
                "properties" => $properties,
                "required" => $required,
                "additionalProperties" => false,
            ],
        ],
    ],
    "required" => ["items"],
    "additionalProperties" => false,
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
