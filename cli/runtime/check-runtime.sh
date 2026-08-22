#!/usr/bin/env bash
# Перевірити, що локальний Ollama runtime готовий до translation-флоу.
#
#   ./check-runtime.sh          # перевірити активну модель субагентів
#
# Перевіряє контракт, від якого залежать субагенти:
#   1. /v1 endpoint відповідає, активна модель існує.
#   2. Модель не MLX (MLX runner мовчки ігнорує constrained decoding).
#   3. reasoning_effort=none реально вимикає thinking (інакше content порожній).
#   4. response_format json_schema реально тримається: хеші з enum повертаються
#      точно, зайві ключі неможливі, вихід парситься як JSON.
#   5. модель оголошена провайдеру в конфізі OpenCode.
# Кожен пункт падає з поясненням; exit 0 означає, що рантайм готовий.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
readonly SCRIPT_DIR
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
readonly OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"

translate_require_path TRANSLATE_OPENCODE_CONFIG 'конфіг OpenCode' "$TRANSLATE_OPENCODE_CONFIG"
MODEL_FULL="$(jq -r '.agent["translation-worker"].model // empty' "$TRANSLATE_OPENCODE_CONFIG")"
test -n "$MODEL_FULL" || { echo "FAIL: у opencode.json немає моделі translation-worker" >&2; exit 1; }

case "$MODEL_FULL" in
ollama-local/*) MODEL="${MODEL_FULL#ollama-local/}" ;;
*)
    echo "Runtime route: $MODEL_FULL"
    echo 'Зовнішній provider перевіряється child smoke у самому OpenCode; прямий HTTP probe навмисно не обходить OpenCode auth.'
    echo 'Відкрий режим і попроси: «Запусти translation-smoke та покажи фактичний provider/model». '
    exit 2
    ;;
esac

echo "Runtime check для: $MODEL_FULL"

echo -n "1. endpoint і модель... "
curl -fsS -m 5 "$OLLAMA_URL/v1/models" 2>/dev/null \
    | jq -e --arg m "$MODEL" '.data[] | select(.id == $m)' >/dev/null \
    || {
        echo "FAIL: $OLLAMA_URL не відповідає або моделі $MODEL немає."
        if curl -fsS -m 5 "$OLLAMA_URL/v1/models" 2>/dev/null | jq -e '.data[] | select(.id == "qwen3.5:9b")' >/dev/null; then
            echo 'Наявна fast-модель. Перемкни без завантаження 35B: ./bdo profile fast'
        else
            echo "Завантаж модель: ollama pull $MODEL"
        fi
        exit 1
    }
echo "OK"

echo -n "2. не MLX... "
case "$MODEL" in
*-mlx*) echo "FAIL: MLX runner ігнорує constrained decoding; потрібен GGUF-тег"; exit 1 ;;
*) echo "OK" ;;
esac

echo -n "3. thinking вимикається... "
php -r '
$payload = json_encode([
    "model" => $argv[1],
    "temperature" => 0,
    "max_tokens" => 60,
    "reasoning_effort" => "none",
    "messages" => [["role" => "user", "content" => "Скажи одним словом: готово"]],
]);
$ctx = stream_context_create(["http" => [
    "method" => "POST", "header" => "Content-Type: application/json",
    "content" => $payload, "timeout" => 120, "ignore_errors" => true,
]]);
$raw = file_get_contents($argv[2] . "/v1/chat/completions", false, $ctx);
$d = json_decode((string) $raw, true);
$m = $d["choices"][0]["message"] ?? [];
$content = trim($m["content"] ?? "");
$reasoning = $m["reasoning"] ?? $m["reasoning_content"] ?? null;
if ($content === "") { fwrite(STDERR, "FAIL: content порожній, thinking зʼїв відповідь\n"); exit(1); }
if (is_string($reasoning) && trim($reasoning) !== "") { fwrite(STDERR, "FAIL: у відповіді лишився reasoning\n"); exit(1); }
echo "OK\n";
' "$MODEL" "$OLLAMA_URL"

echo -n "4. constrained decoding тримається... "
php -r '
$hashes = [hash("sha256", "runtime-check-a"), hash("sha256", "runtime-check-b")];
$schema = [
    "type" => "array", "minItems" => 2, "maxItems" => 2,
    "items" => [
        "type" => "object",
        "properties" => [
            "identity_hash" => ["type" => "string", "enum" => $hashes],
            "text" => ["type" => "string", "minLength" => 1],
        ],
        "required" => ["identity_hash", "text"],
        "additionalProperties" => false,
    ],
];
$rows = [
    ["identity_hash" => $hashes[0], "source_text" => "Ancient Spirit Dust"],
    ["identity_hash" => $hashes[1], "source_text" => "Guild Wharf Manager"],
];
$payload = json_encode([
    "model" => $argv[1],
    "temperature" => 0,
    "max_tokens" => 900,
    "reasoning_effort" => "none",
    "response_format" => ["type" => "json_schema", "json_schema" => ["name" => "t", "strict" => true, "schema" => $schema]],
    "messages" => [
        ["role" => "system", "content" => "Перекладай рядки гри англійською->українською."],
        ["role" => "user", "content" => json_encode($rows, JSON_UNESCAPED_UNICODE)],
    ],
], JSON_UNESCAPED_UNICODE);
$ctx = stream_context_create(["http" => [
    "method" => "POST", "header" => "Content-Type: application/json",
    "content" => $payload, "timeout" => 600, "ignore_errors" => true,
]]);
$raw = file_get_contents($argv[2] . "/v1/chat/completions", false, $ctx);
$d = json_decode((string) $raw, true);
$content = $d["choices"][0]["message"]["content"] ?? "";
$out = json_decode($content, true);
if (!is_array($out)) { fwrite(STDERR, "FAIL: вихід не JSON-масив: " . mb_substr($content, 0, 120) . "\n"); exit(1); }
if (count($out) !== 2) { fwrite(STDERR, "FAIL: елементів " . count($out) . " замість 2\n"); exit(1); }
foreach ($out as $i => $item) {
    $keys = array_keys($item);
    sort($keys);
    if ($keys !== ["identity_hash", "text"]) {
        fwrite(STDERR, "FAIL: зайві або відсутні ключі (" . implode(",", $keys) . ") - схема не застосувалась (MLX?)\n");
        exit(1);
    }
    if ($item["identity_hash"] !== $hashes[$i]) { fwrite(STDERR, "FAIL: хеш #$i не збігається\n"); exit(1); }
    if (trim($item["text"]) === "") { fwrite(STDERR, "FAIL: порожній text #$i\n"); exit(1); }
}
echo "OK\n";
' "$MODEL" "$OLLAMA_URL"

echo -n "5. модель оголошена в конфізі OpenCode... "
# Пункти 1-4 говорять із Ollama напряму й тому пропустили реальний збій: модель
# працювала, а OpenCode не мав її в списку моделей провайдера й створював
# порожні дочірні сесії - нуль токенів, жодної відповіді. Перевіряти рантайм
# без цього пункту означає перевіряти не той шар.
if "$SCRIPT_DIR/cli/runtime/sync-opencode-models.sh" >/dev/null 2>&1; then
    echo "OK"
else
    echo "FAIL"
    "$SCRIPT_DIR/cli/runtime/sync-opencode-models.sh" || true
    exit 1
fi

echo "Runtime готовий: $MODEL_FULL"
