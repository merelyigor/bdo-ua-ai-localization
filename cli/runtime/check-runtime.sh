#!/usr/bin/env bash
# Перевірити, що локальний Ollama runtime готовий до translation-флоу.
#
#   ./check-runtime.sh          # перевірити активну модель субагентів
#
# Перевіряє контракт, від якого залежать субагенти:
#   1. /v1 endpoint відповідає, активна модель існує.
#   2. Формат моделі не вгадується за назвою: його доводить крок 4.
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
        if curl -fsS -m 5 "$OLLAMA_URL/v1/models" 2>/dev/null | jq -e '.data[] | select(.id == "gemma4:26b")' >/dev/null; then
            echo 'Наявна друга дозволена модель. Перемкни без завантаження 35B: TRANSLATE_MODEL=ollama-local/gemma4:26b у .env, далі ./bdo env'
        else
            echo "Завантаж модель: ollama pull $MODEL"
        fi
        exit 1
    }
echo "OK"

# Крок 2 навмисно НЕ дивиться на назву тега.
#
# Раніше тут падав будь-який `-mlx`, бо тодішній runner ігнорував схему.
# Перевірено наново 2026-08-28 на Ollama 0.33.1: `gemma4:e4b-mlx` дотримав
# strict-схему 4 рази з 4. Формат моделі перевіряє крок 4 · він міряє саме
# поведінку, а не написання тега, і ловить будь-який runner, не лише MLX.
echo -n "2. формат відповіді перевіряється кроком 4... "
echo "OK"

# Крок 3 бере ЕФЕКТИВНЕ значення з `.env`, а не зашите `none`.
#
# Раніше проба завжди слала `reasoning_effort: none` і завжди була зелена ·
# зокрема тоді, коли в `.env` стояло `off`, і плагін не слав НІЧОГО. Для
# думальної моделі «нічого» означає думати: 2026-08-28 `qwen3.6` віддавав усе в
# `reasoning`, лишав `content` порожнім, і child «падав» без помилки, поки
# перевірка показувала OK. Перевірка мусить іти тим самим шляхом, що й робота.
EFFORT="$(php -r '
$file = getenv("TRANSLATE_ENV_FILE") ?: $argv[1];
$raw = null;
foreach (@file($file) ?: [] as $line) {
    if (preg_match("~^\s*(?:export\s+)?BDO_REASONING_EFFORT\s*=\s*(.*)$~", $line, $m)) $raw = $m[1];
}
$v = strtolower(trim(explode("#", (string) ($raw ?? "none"))[0], " \"\x27\t\n"));
echo $v === "" ? "none" : $v;
' "$SCRIPT_DIR/.env")"
echo -n "3. thinking вимикається (BDO_REASONING_EFFORT=$EFFORT)... "
php -r '
$body = [
    "model" => $argv[1],
    "temperature" => 0,
    "max_tokens" => 60,
    "messages" => [["role" => "user", "content" => "Скажи одним словом: готово"]],
];
// `off` означає «поле не надсилати» · саме так і перевіряємо.
if ($argv[3] !== "off") $body["reasoning_effort"] = $argv[3];
$payload = json_encode($body);
$ctx = stream_context_create(["http" => [
    "method" => "POST", "header" => "Content-Type: application/json",
    "content" => $payload, "timeout" => 120, "ignore_errors" => true,
]]);
$raw = file_get_contents($argv[2] . "/v1/chat/completions", false, $ctx);
$d = json_decode((string) $raw, true);
$m = $d["choices"][0]["message"] ?? [];
$content = trim($m["content"] ?? "");
$reasoning = $m["reasoning"] ?? $m["reasoning_content"] ?? null;
if ($content === "") {
    fwrite(STDERR, "FAIL: content порожній, thinking зʼїв відповідь\n");
    if ($argv[3] === "off") fwrite(STDERR, "  BDO_REASONING_EFFORT=off НЕ надсилає нічого, тому модель думає. Постав none.\n");
    exit(1);
}
if (is_string($reasoning) && trim($reasoning) !== "") {
    fwrite(STDERR, "FAIL: у відповіді лишився reasoning\n");
    if ($argv[3] === "off") fwrite(STDERR, "  Постав BDO_REASONING_EFFORT=none: `off` лишає поведінку провайдера.\n");
    exit(1);
}
echo "OK\n";
' "$MODEL" "$OLLAMA_URL" "$EFFORT"

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
