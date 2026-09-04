#!/usr/bin/env bash
# Два транспорти · один контракт відмов.
#
# Навіщо цей тест окремо від `tests/model-client.sh`. Той перевіряє поведінку
# клієнта на протоколі Ollama. Тут перевіряється головна обіцянка етапу
# провайдерів: зовнішній API формату OpenAI підключається КОНФІГОМ, а всі
# перевірки змісту лишаються ті самі й дають ті самі причини.
#
# Клас відмови, від якого це захищає: транспорт, який «майже працює». Обрив без
# `[DONE]` виглядає як успіх, бо зібраний текст випадково розібрався як JSON;
# `finish_reason=length` виглядає як зіпсована модель, а не як наша стеля;
# лічильники без `stream_options.include_usage` тихо зникають, і журнал
# втрачає токени саме там, де вони коштують грошей.
#
# Перевіряємо ПОВЕДІНКОЮ на підробленому сервері кожного протоколу, а не
# читанням коду.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
PORT=$((23000 + RANDOM % 2000))
cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Підроблений сервіс формату OpenAI. Сценарій задає файл · один сервер на всі
# випадки, як і в перевірці Ollama.
cat > "$WORK/router.php" <<'PHP'
<?php
$mode = trim((string) @file_get_contents(getenv("SCENARIO_FILE")));
$body = (string) file_get_contents("php://input");
@file_put_contents(getenv("SCENARIO_FILE").".request", $body);
@file_put_contents(getenv("SCENARIO_FILE").".headers", json_encode($_SERVER, JSON_UNESCAPED_UNICODE));

if (! str_contains($_SERVER["REQUEST_URI"], "/chat/completions")) {
    http_response_code(404);
    echo json_encode(["error" => ["message" => "unknown path", "type" => "invalid_request_error"]]);
    return true;
}

$cases = [
    "ok" => ['{"items":[{"identity_hash":"aa","text":"Меч"}]}', "stop"],
    "truncated" => ['{"items":[{"identity_ha', "length"],
    "empty" => ["", "stop"],
    "prose" => ["Готово, я все переклав.", "stop"],
    "reasoning" => ["", "stop"],
];
if ($mode === "error") {
    header("Content-Type: application/json");
    http_response_code(429);
    echo json_encode(["error" => ["message" => "rate limit reached", "type" => "rate_limit_error"]]);
    return true;
}
[$content, $finish] = $cases[$mode] ?? $cases["ok"];
$wantsStream = str_contains($body, '"stream":true');

if (! $wantsStream) {
    header("Content-Type: application/json");
    echo json_encode([
        "choices" => [["message" => ["content" => $content], "finish_reason" => $finish]],
        "usage" => ["prompt_tokens" => 11, "completion_tokens" => 7],
    ], JSON_UNESCAPED_UNICODE);
    return true;
}

header("Content-Type: text/event-stream");
$emit = static function (array $chunk): void {
    echo "data: ", json_encode($chunk, JSON_UNESCAPED_UNICODE), "\n\n";
};
if ($mode === "reasoning") {
    // Роздуми окремим полем, а `content` порожній · та сама пастка, що D28.
    foreach (mb_str_split("Спершу подумаю дуже довго", 6) as $piece) {
        $emit(["choices" => [["delta" => ["reasoning_content" => $piece], "finish_reason" => null]]]);
    }
}
foreach (mb_str_split($content, 4) as $piece) {
    $emit(["choices" => [["delta" => ["content" => $piece], "finish_reason" => null]]]);
}
// Обрив ПІСЛЯ шматків: ні finish_reason, ні [DONE].
if ($mode === "stream_cut") {
    return true;
}
$emit(["choices" => [["delta" => (object) [], "finish_reason" => $finish]]]);
// Лічильники приходять окремим чанком · рівно так їх віддає провайдер, коли
// попросили `stream_options.include_usage`.
$emit(["choices" => [], "usage" => ["prompt_tokens" => 11, "completion_tokens" => 7]]);
echo "data: [DONE]\n\n";
return true;
PHP

export SCENARIO_FILE="$WORK/scenario"
echo ok > "$SCENARIO_FILE"
SCENARIO_FILE="$SCENARIO_FILE" php -S "127.0.0.1:$PORT" "$WORK/router.php" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/chat/completions" && break
    sleep 0.1
done

mkdir -p "$WORK/state"
printf '{"items":[{"identity_hash":"aa","source_text":"Sword"}]}' > "$WORK/payload.json"
printf '{"type":"object"}' > "$WORK/schema.json"
cat > "$WORK/roles.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:1", "provider": "openai",
  "providers": {
    "openai": { "transport": "openai", "endpoint": "http://127.0.0.1:$PORT",
                "api_key_env": "BDO_TEST_KEY", "reasoning_effort": "low" }
  },
  "default_model": "не-та-модель", "num_ctx": 4096, "timeout_seconds": 20,
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1, "model": "зовнішня-модель" } } }
JSON

run() {
    printf '%s' "$1" > "$SCENARIO_FILE"
    rm -f "$WORK/response.json"
    set +e
    STDERR="$(BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
        BDO_TEST_KEY=test-key BDO_MODEL_SHOW=0 \
        php "$ROOT/cli/model/client.php" translation-worker \
        "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
    CODE=$?
    set -e
}

# 1. Успіх на SSE: та сама розпакована відповідь, що й від Ollama.
run ok
test "$CODE" = 0 || fail "успішний виклик зовнішнього провайдера дав код $CODE: $STDERR"
test -s "$WORK/response.json" || fail 'успішний виклик не створив файл відповіді'
php -r 'exit(is_array(json_decode(file_get_contents($argv[1]), true)) ? 0 : 1);' "$WORK/response.json" \
    || fail 'відповідь зовнішнього провайдера не є JSON-масивом'

# 2. Запит мусить бути у формі ЦЬОГО протоколу, а не Ollama.
request="$(cat "$SCENARIO_FILE.request")"
printf '%s' "$request" | grep -q '"response_format"' \
    || fail "схема не передана як response_format: $request"
printf '%s' "$request" | grep -q '"json_schema"' || fail 'схема не у формі json_schema'
printf '%s' "$request" | grep -q '"stream_options"' \
    || fail 'не попросили лічильники (stream_options.include_usage) · журнал лишиться без токенів'
printf '%s' "$request" | grep -q '"model":"зовнішня-модель"' \
    || fail "модель ролі не дійшла до провайдера: $request"
printf '%s' "$request" | grep -q '"num_ctx"' \
    && fail 'у зовнішній API пішло поле Ollama (num_ctx) · транспорти змішались'
headers="$(cat "$SCENARIO_FILE.headers")"
printf '%s' "$headers" | grep -q 'Bearer test-key' \
    || fail 'ключ не пішов заголовком Authorization'

# 3. Лічильники з окремого чанка дійшли в журнал.
grep -q '"in":11' "$WORK/state/model-calls.jsonl" \
    || fail "журнал не отримав лічильники входу: $(tail -1 "$WORK/state/model-calls.jsonl")"
grep -q '"out":7' "$WORK/state/model-calls.jsonl" || fail 'журнал не отримав лічильники виходу'
grep -q '"provider":"openai"' "$WORK/state/model-calls.jsonl" \
    || fail 'журнал не називає провайдера · без цього дефект «за моделями» не розібрати'

# 4. Кожна відмова · та сама причина, що й на Ollama.
for case_reason in "truncated:truncated" "empty:empty_content" "reasoning:empty_content" \
                   "prose:not_json" "error:model_error" "stream_cut:stream_incomplete"; do
    scenario="${case_reason%%:*}"
    expected="${case_reason##*:}"
    run "$scenario"
    test "$CODE" = 1 || fail "сценарій $scenario мусив упасти, а дав код $CODE"
    printf '%s' "$STDERR" | grep -q "^$expected" \
        || fail "сценарій $scenario: чекали причину «${expected}», маємо «${STDERR}»"
    test ! -e "$WORK/response.json" || fail "сценарій $scenario створив файл відповіді попри відмову"
done

# 5. Роздуми названі окремо: інакше власник шукатиме дефект у промпті.
run reasoning
printf '%s' "$STDERR" | grep -q 'thinking' \
    || fail "порожній content при роздумах не назвав причини: $STDERR"

# 6. Без потоку той самий шлях перевірок.
printf 'ok' > "$SCENARIO_FILE"
rm -f "$WORK/response.json"
set +e
STDERR="$(BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    BDO_TEST_KEY=test-key BDO_MODEL_STREAM=0 BDO_MODEL_SHOW=0 \
    php "$ROOT/cli/model/client.php" translation-worker \
    "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
CODE=$?
set -e
test "$CODE" = 0 || fail "виклик без потоку впав: $STDERR"
printf '%s' "$(cat "$SCENARIO_FILE.request")" | grep -q '"stream":false' \
    || fail 'BDO_MODEL_STREAM=0 не вимкнув потік у зовнішнього провайдера'

# 7. Немає ключа · відмова З ПРИЧИНОЮ, а не запит без авторизації.
rm -f "$WORK/response.json"
set +e
STDERR="$(BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" BDO_MODEL_SHOW=0 \
    php "$ROOT/cli/model/client.php" translation-worker \
    "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
CODE=$?
set -e
test "$CODE" = 1 || fail "виклик без ключа дав код $CODE"
printf '%s' "$STDERR" | grep -q '^provider_key_missing' || fail "відмова без ключа не назвала причини: $STDERR"
printf '%s' "$STDERR" | grep -q 'BDO_TEST_KEY' || fail 'відмова не назвала, ЯКОЇ саме змінної немає'

# 8. Невідомий провайдер · відмова, а не тихий Ollama.
sed 's/"provider": "openai"/"provider": "вигаданий"/' "$WORK/roles.json" > "$WORK/bogus.json"
set +e
STDERR="$(BDO_ROLES_CONFIG="$WORK/bogus.json" BDO_STATE_DIR="$WORK/state" BDO_MODEL_SHOW=0 \
    php "$ROOT/cli/model/client.php" translation-worker \
    "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
CODE=$?
set -e
test "$CODE" = 1 || fail "невідомий провайдер дав код $CODE"
printf '%s' "$STDERR" | grep -q '^unknown_provider' || fail "невідомий провайдер без причини: $STDERR"

# 9. Модель не названа · відмова до запиту, а не помилка чужого API.
php -r '
$c = json_decode(file_get_contents($argv[1]), true);
unset($c["roles"]["translation-worker"]["model"], $c["default_model"]);
file_put_contents($argv[2], json_encode($c, JSON_UNESCAPED_UNICODE));' "$WORK/roles.json" "$WORK/nomodel.json"
set +e
STDERR="$(BDO_ROLES_CONFIG="$WORK/nomodel.json" BDO_STATE_DIR="$WORK/state" \
    BDO_TEST_KEY=test-key BDO_MODEL_SHOW=0 \
    php "$ROOT/cli/model/client.php" translation-worker \
    "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
CODE=$?
set -e
test "$CODE" = 1 || fail "виклик без назви моделі дав код $CODE"
printf '%s' "$STDERR" | grep -q '^missing_model' || fail "відсутня модель без причини: $STDERR"

# 10. Старий конфіг БЕЗ блока providers мусить працювати як раніше (Ollama).
#     Інакше зміна транспорту зупинила б прогін на першій ролі, а «спершу онови
#     конфіг» · це і є тихий збій, який помічають на живій пачці.
php -r '
require $argv[1];
use Bdo\Translate\Model\Transport\Factory;
$legacy = ["endpoint" => "http://127.0.0.1:11434", "default_model" => "локальна", "num_ctx" => 4096, "roles" => []];
$t = Factory::forRole($legacy, ["schema" => "response"]);
if ($t->name() !== "ollama") { fwrite(STDERR, "старий конфіг дав транспорт ".$t->name()."\n"); exit(1); }
if (Factory::modelForRole($legacy, ["schema" => "response"]) !== "локальна") { fwrite(STDERR, "модель зі старого конфігу не взято\n"); exit(1); }
// Роль може піти в інший провайдер, не чіпаючи решти набору.
$mixed = ["provider" => "ollama", "providers" => ["openai" => ["transport" => "openai", "endpoint" => "http://x", "api_key_env" => "K"]],
          "endpoint" => "http://127.0.0.1:11434", "default_model" => "локальна", "roles" => []];
if (Factory::forRole($mixed, ["provider" => "openai"])->name() !== "openai") { fwrite(STDERR, "провайдер ролі не переважив набір\n"); exit(1); }
if (Factory::forRole($mixed, [])->name() !== "ollama") { fwrite(STDERR, "решта ролей поїхала не тим транспортом\n"); exit(1); }
' "$ROOT/lib/autoload.php" || fail 'сумісність конфігу або перевага провайдера ролі зламані'

# 11. Реальний конфіг набору лишається на локальних моделях · курс не змінився
#     випадковою правкою (рішення власника 2026-08-27).
php -r '
$c = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
if (($c["provider"] ?? "ollama") !== "ollama") { fwrite(STDERR, "набір за замовчуванням більше не на Ollama\n"); exit(1); }
foreach ($c["roles"] as $name => $role) {
    if (($role["provider"] ?? "ollama") !== "ollama") { fwrite(STDERR, "роль $name пішла у зовнішній провайдер\n"); exit(1); }
}
if (! isset($c["providers"]["openai"]["api_key_env"])) { fwrite(STDERR, "провайдер openai описаний без імені змінної ключа\n"); exit(1); }
foreach ($c["providers"] as $p) {
    foreach ($p as $k => $v) {
        if (is_string($v) && preg_match("~^(sk-|Bearer )~", $v)) { fwrite(STDERR, "у конфізі лежить ключ\n"); exit(1); }
    }
}
' "$ROOT/config/roles.json" || fail 'config/roles.json порушує курс на локальні моделі або містить ключ'

echo 'model transports: OK · зовнішній API формату OpenAI підключається конфігом, дає ті самі причини відмов, лічильники й провайдера в журналі, а набір лишається на локальних моделях.'
