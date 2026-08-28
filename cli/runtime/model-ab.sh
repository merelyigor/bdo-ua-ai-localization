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
#   - cli/quality/build-items.sh і cli/batch/batch-commit.sh відмовляються приймати файл із цієї
#     директорії, тому виміряний кандидат неможливо записати в API.
#
# Скрипт не чіпає активну схему пачки (--out у тимчасовий файл): бенчмарк посеред
# живого прогону інакше затер би identity-набір і зламав наступний виклик воркера.
#
# Модель прогрівається перед виміром. Це не косметика: перший запит містить
# завантаження ваг у памʼять і занижує швидкість на 10-25%. Саме через це
# попередні виміри проєкту довелось переміряти.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
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
SAFE_MODEL="${MODEL//[^A-Za-z0-9._-]/_}"
OUT_FILE="$BENCH_DIR/${SAFE_MODEL}_${STAMP}.json"
# Сира відповідь лежить поза TMP_DIR навмисно: саме вона потрібна, коли розбір
# упав, а trap видаляє TMP_DIR на виході · тобто раніше єдиний доказ збою зникав
# разом із ним.
RAW_FILE="$BENCH_DIR/${SAFE_MODEL}_${STAMP}_response.json"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Схема - у тимчасовий файл, активна лишається недоторканою.
"$SCRIPT_DIR/cli/prepare/build-schema.sh" --out "$TMP_DIR/schema.json" "$ROWS_FILE" >/dev/null

# Системний промпт - тіло агента без YAML-frontmatter, щоб міряти рівно те,
# з чим працює справжній translation-worker.
awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$AGENT_FILE" > "$TMP_DIR/system.txt"
"$SCRIPT_DIR/cli/prepare/worker-payload.sh" "$ROWS_FILE" > "$TMP_DIR/payload.json"

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
if ! curl -sS -X POST "$OLLAMA_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    --data-binary "@$TMP_DIR/request.json" -o "$RAW_FILE"; then
    echo "Запит до Ollama не вдався: $OLLAMA_URL. Перевір, що вона запущена: ./bdo runtime" >&2
    exit 1
fi
END="$(php -r 'echo microtime(true);')"

php -r '
$raw = file_get_contents($argv[1]);
$r = json_decode($raw, true);
if (!is_array($r)) {
    fwrite(STDERR, "Ollama віддала не JSON. Перші 300 символів:\n" . substr($raw, 0, 300) . "\n");
    fwrite(STDERR, "Повна відповідь: " . $argv[6] . "\n");
    exit(1);
}
if (isset($r["error"])) {
    fwrite(STDERR, "Помилка Ollama: " . json_encode($r["error"], JSON_UNESCAPED_UNICODE) . "\n");
    exit(1);
}

$message = $r["choices"][0]["message"] ?? null;
$content = is_array($message) ? ($message["content"] ?? "") : "";
$items = json_decode(is_string($content) ? $content : "", true);

if (!is_array($items)) {
    // Тут раніше стояв один рядок «не JSON-масив» без жодних даних, і збій був
    // недіагностовним: не видно було ні що прийшло, ні чому. Нижче саме те, що
    // розрізняє три різні причини з однаковим симптомом.
    fwrite(STDERR, "\nМодель НЕ віддала JSON-масив. Що прийшло насправді:\n");

    if ($message === null) {
        fwrite(STDERR, "  choices[0].message відсутній узагалі · відповідь не має форми chat completion\n");
    }
    $reasoning = is_array($message) ? ($message["reasoning"] ?? ($message["reasoning_content"] ?? "")) : "";
    $finish = $r["choices"][0]["finish_reason"] ?? "?";
    $usage = $r["usage"] ?? [];

    fwrite(STDERR, sprintf("  content: %d символів%s\n", strlen((string) $content),
        $content === "" || $content === null ? " (ПОРОЖНІЙ)" : ""));
    fwrite(STDERR, sprintf("  reasoning: %d символів\n", strlen((string) $reasoning)));
    fwrite(STDERR, sprintf("  finish_reason: %s\n", (string) $finish));
    fwrite(STDERR, sprintf("  токенів: вхід %s, вихід %s\n",
        $usage["prompt_tokens"] ?? "?", $usage["completion_tokens"] ?? "?"));

    if (is_string($content) && $content !== "") {
        fwrite(STDERR, "  перші 300 символів content:\n    " . str_replace("\n", "\n    ", substr($content, 0, 300)) . "\n");
        fwrite(STDERR, "  помилка розбору JSON: " . json_last_error_msg() . "\n");
    }

    // Три відомі причини, кожна зі своїм підписом у цифрах вище.
    fwrite(STDERR, "\nЛікування за симптомом:\n");
    if (strlen((string) $reasoning) > 0 && ($content === "" || $content === null)) {
        fwrite(STDERR, "  reasoning непорожній, а content порожній · модель витратила весь бюджет\n");
        fwrite(STDERR, "  виходу на міркування. Перевір, що ця модель шанує reasoning_effort=none\n");
        fwrite(STDERR, "  на /v1: ./bdo runtime, пункт 3.\n");
    } elseif ($finish === "length") {
        fwrite(STDERR, "  finish_reason=length · відповідь обрізано лімітом виходу. Візьми меншу\n");
        fwrite(STDERR, "  пачку: на 20 рядках ліміт не досягався.\n");
    } elseif ($content === "" || $content === null) {
        fwrite(STDERR, "  порожній content без reasoning · найчастіше модель не оголошена\n");
        fwrite(STDERR, "  провайдеру або не тягне схему. Перевір: ./bdo runtime і ./bdo models.\n");
    } elseif (str_starts_with(ltrim((string) $content), "[") && json_last_error() === JSON_ERROR_CTRL_CHAR) {
        // Відповідь ПОЧАЛАСЬ правильно (масив, за схемою) і обірвалась на півслові.
        // Це не про схему: схема діяла, інакше першим символом не був би `[`.
        // Розрізняти обовʼязково · інакше підказка веде шукати формат там, де
        // насправді генерація просто спинилась.
        fwrite(STDERR, "  content почався як JSON-масив і ОБІРВАВСЯ на " . strlen((string) $content) . " символах.\n");
        fwrite(STDERR, "  Схема діяла (перший символ `[`), тобто справа не в ній і не в MLX.\n");
        fwrite(STDERR, "  Генерація спинилась передчасно. Перевір по порядку:\n");
        fwrite(STDERR, "    - ліміт виходу Ollama (num_predict/OLLAMA_NUM_PREDICT);\n");
        fwrite(STDERR, "    - чи влазить пачка в контекст моделі (OLLAMA_CONTEXT_LENGTH);\n");
        fwrite(STDERR, "    - чи не вивантажилась модель посеред запиту (логи Ollama).\n");
    } else {
        fwrite(STDERR, "  content є, але не JSON-масив · constrained decoding не застосувався.\n");
        fwrite(STDERR, "  Схема не застосувалась цим runner. Перевір: ./bdo runtime, крок 4.\n");
    }
    fwrite(STDERR, "\nПовна відповідь для розбору: " . $argv[6] . "\n");
    exit(1);
}
file_put_contents($argv[2], json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
$sec = (float) $argv[4] - (float) $argv[3];
$tokens = $r["usage"]["completion_tokens"] ?? 0;
printf("\nМодель: %s\n  рядків: %d | токенів: %d | час: %.1f с | ШВИДКІСТЬ: %.1f tok/s\n",
    $argv[5], count($items), $tokens, $sec, $tokens / max($sec, 0.001));
' "$RAW_FILE" "$OUT_FILE" "$START" "$END" "$MODEL" "$RAW_FILE"

echo
"$SCRIPT_DIR/cli/quality/check-russianisms.sh" "$OUT_FILE" "$ROWS_FILE" || true

echo
echo "Кандидат виміру: $OUT_FILE"
echo "Це вимір, а не переклад для запису: cli/quality/build-items.sh і cli/batch/batch-commit.sh його відхилять."
