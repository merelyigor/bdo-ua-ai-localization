#!/usr/bin/env bash
# Виміряти локальну модель на реальній пачці: швидкість, формат, русизми.
#
#   ./model-ab.sh <модель> <rows.json>
#   ./model-ab.sh qwen3.6:35b-a3b-mtp-q4_K_M output/rows_20260815_063207.json
#
# ЦЕ ЄДИНИЙ СКРИПТ ФЛОУ, ЯКИЙ САМ ЗВЕРТАЄТЬСЯ ДО МОДЕЛІ, і це навмисний,
# обмежений виняток із правила «жоден shell-runner не викликає модель». Правило
# існує, щоб переклад відбувався у видимих субагентських сесіях, а не в схованому
# циклі. Тут переклад не виробляється для запису: результат - вимір.
#
# Виняток тримається механічно, а не на довірі:
#   - вихід іде тільки в output/benchmark/ і нікуди більше;
#   - build-items.sh і batch-commit.sh відмовляються приймати файл із цієї
#     директорії, тому виміряний кандидат неможливо записати в API.
#
# Скрипт не чіпає активну схему пачки (--out у тимчасовий файл): бенчмарк посеред
# живого прогону інакше затер би identity-набір і зламав наступний виклик воркера.
#
# Модель прогрівається перед виміром. Це не косметика: перший запит містить
# завантаження ваг у памʼять і занижує швидкість на 10-25%. Саме через це
# попередні виміри проєкту довелось переміряти.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=paths.sh
source "$SCRIPT_DIR/paths.sh"
MODEL="${1:?Потрібна назва моделі Ollama, напр. qwen3.6:35b-a3b-mtp-q4_K_M}"
ROWS_FILE="${2:?Потрібен rows.json з API}"
test -f "$ROWS_FILE" || { echo "Немає файлу: $ROWS_FILE" >&2; exit 1; }

OLLAMA_URL="${BDO_OLLAMA_URL:-http://127.0.0.1:11434}"
translate_require_path TRANSLATE_AGENTS_DIR 'каталог промптів субагентів' "$TRANSLATE_AGENTS_DIR"
AGENT_FILE="$TRANSLATE_AGENTS_DIR/translation-worker.md"
test -f "$AGENT_FILE" || { echo "Немає промпту воркера: $AGENT_FILE" >&2; exit 1; }

if ! ollama list | awk 'NR>1 {print $1}' | grep -Fxq "$MODEL"; then
    echo "Модель '$MODEL' не встановлена. Спочатку: ollama pull $MODEL" >&2
    exit 1
fi

BENCH_DIR="$SCRIPT_DIR/output/benchmark"
mkdir -p "$BENCH_DIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="$BENCH_DIR/${MODEL//[^A-Za-z0-9._-]/_}_${STAMP}.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Схема - у тимчасовий файл, активна лишається недоторканою.
"$SCRIPT_DIR/build-schema.sh" --out "$TMP_DIR/schema.json" "$ROWS_FILE" >/dev/null

# Системний промпт - тіло агента без YAML-frontmatter, щоб міряти рівно те,
# з чим працює справжній translation-worker.
awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$AGENT_FILE" > "$TMP_DIR/system.txt"
"$SCRIPT_DIR/worker-payload.sh" "$ROWS_FILE" > "$TMP_DIR/payload.json"

php -r '
$body = [
    "model" => $argv[1],
    "messages" => [
        ["role" => "system", "content" => file_get_contents($argv[2])],
        ["role" => "user", "content" => file_get_contents($argv[3])],
    ],
    "temperature" => 0.1,
    "reasoning_effort" => "none",
    "response_format" => [
        "type" => "json_schema",
        "json_schema" => [
            "name" => "translations",
            "strict" => true,
            "schema" => json_decode(file_get_contents($argv[4]), true, 512, JSON_THROW_ON_ERROR),
        ],
    ],
];
file_put_contents($argv[5], json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
' "$MODEL" "$TMP_DIR/system.txt" "$TMP_DIR/payload.json" "$TMP_DIR/schema.json" "$TMP_DIR/request.json"

echo "Прогріваю $MODEL..." >&2
ollama run "$MODEL" "ок" >/dev/null 2>&1 || {
    echo "Не вдалося прогріти модель '$MODEL'." >&2; exit 1; }

echo "Міряю на $(php -r 'echo count(json_decode(file_get_contents($argv[1]), true)["data"]["rows"] ?? []);' "$ROWS_FILE") рядках..." >&2
START="$(php -r 'echo microtime(true);')"
curl -fsS -X POST "$OLLAMA_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    --data-binary "@$TMP_DIR/request.json" -o "$TMP_DIR/response.json"
END="$(php -r 'echo microtime(true);')"

php -r '
$r = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
if (isset($r["error"])) {
    fwrite(STDERR, "Помилка Ollama: " . json_encode($r["error"], JSON_UNESCAPED_UNICODE) . "\n");
    exit(1);
}
$items = json_decode($r["choices"][0]["message"]["content"] ?? "", true);
if (!is_array($items)) {
    fwrite(STDERR, "Модель відповіла не JSON-масивом - constrained decoding не тримається.\n");
    exit(1);
}
file_put_contents($argv[2], json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
$sec = (float) $argv[4] - (float) $argv[3];
$tokens = $r["usage"]["completion_tokens"] ?? 0;
printf("\nМодель: %s\n  рядків: %d | токенів: %d | час: %.1f с | ШВИДКІСТЬ: %.1f tok/s\n",
    $argv[5], count($items), $tokens, $sec, $tokens / max($sec, 0.001));
' "$TMP_DIR/response.json" "$OUT_FILE" "$START" "$END" "$MODEL"

echo
"$SCRIPT_DIR/check-russianisms.sh" "$OUT_FILE" "$ROWS_FILE" || true

echo
echo "Кандидат виміру: $OUT_FILE"
echo "Це вимір, а не переклад для запису: build-items.sh і batch-commit.sh його відхилять."
