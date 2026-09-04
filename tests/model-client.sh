#!/usr/bin/env bash
# Клієнт локальної моделі мусить ПАДАТИ з причиною, а не деградувати мовчки.
#
# Це заміна дитячої сесії OpenCode, і саме на тихій деградації набір втрачав
# прогони: порожній `content` при ввімкненому думанні (D28), обрив на стелі, що
# виглядає як зіпсований JSON (D29), викинутий початок payload при завищеному
# вікні (D32). Жодна з цих ситуацій не має права виглядати як «спробуємо ще».
#
# Перевіряємо не текстом коду, а поведінкою: піднімаємо ПІДРОБЛЕНИЙ endpoint
# Ollama на вбудованому сервері PHP і дивимось код виходу, причину в stderr,
# наявність файла відповіді та рядок у журналі.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
PORT=$((21000 + RANDOM % 2000))
cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Підроблений Ollama: сценарій задає файл, щоб один сервер обслуговував усі кейси.
cat > "$WORK/router.php" <<'PHP'
<?php
$mode = trim((string) @file_get_contents(getenv("SCENARIO_FILE")));
if (str_contains($_SERVER["REQUEST_URI"], "/api/ps")) {
    $window = $mode === "overflow" ? 1000 : 131072;
    header("Content-Type: application/json");
    echo json_encode(["models" => [["name" => "тест-модель", "context_length" => $window]]]);
    return true;
}
$answers = [
    "ok" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 5,
             "message" => ["content" => '{"items":[{"identity_hash":"aa","text":"Меч"}]}']],
    "envelopeless" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 5,
             "message" => ["content" => '[{"identity_hash":"aa","text":"Меч"}]']],
    "truncated" => ["done_reason" => "length", "prompt_eval_count" => 10, "eval_count" => 4096,
             "message" => ["content" => '{"items":[{"identity_ha']],
    "empty" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 0,
             "message" => ["content" => ""]],
    "thinking" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 300,
             "message" => ["content" => "", "thinking" => "Хм, спершу подумаю…"]],
    "prose" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 9,
             "message" => ["content" => "Готово, я все переклав."]],
    "error" => ["error" => "model requires more system memory"],
    "overflow" => ["done_reason" => "stop", "prompt_eval_count" => 980, "eval_count" => 5,
             "message" => ["content" => '{"items":[{"identity_hash":"aa","text":"Меч"}]}']],
];
header("Content-Type: application/json");
echo json_encode($answers[$mode] ?? $answers["ok"], JSON_UNESCAPED_UNICODE);
return true;
PHP

export SCENARIO_FILE="$WORK/scenario"
echo ok > "$SCENARIO_FILE"
SCENARIO_FILE="$SCENARIO_FILE" php -S "127.0.0.1:$PORT" "$WORK/router.php" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null || fail 'підроблений Ollama не піднявся'

mkdir -p "$WORK/state" "$WORK/roles"
printf '{"items":[{"identity_hash":"aa","source_text":"Sword"}]}' > "$WORK/payload.json"
printf '{"type":"object"}' > "$WORK/schema.json"
cat > "$WORK/roles.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:$PORT", "default_model": "тест-модель",
  "num_ctx": 131072, "timeout_seconds": 30,
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1 } } }
JSON

run() {
    printf '%s' "$1" > "$SCENARIO_FILE"
    rm -f "$WORK/response.json"
    set +e
    STDERR="$(BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
        php "$ROOT/cli/model/client.php" translation-worker \
        "$WORK/payload.json" "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
    CODE=$?
    set -e
}

# 1. Успіх: конверт `{"items":[…]}` розпаковується у масив, файл зʼявляється.
run ok
test "$CODE" = 0 || fail "успішний виклик дав код $CODE: $STDERR"
test -s "$WORK/response.json" || fail 'успішний виклик не створив файл відповіді'
php -r 'exit(is_array(json_decode(file_get_contents($argv[1]), true)) && array_is_list(json_decode(file_get_contents($argv[1]), true)) ? 0 : 1);' \
    "$WORK/response.json" || fail 'відповідь не є JSON-масивом · конвеєр такого не прийме'

# 2. Голий масив без конверта теж приймається: схема ролі може бути й такою.
run envelopeless
test "$CODE" = 0 || fail "голий масив відхилено: $STDERR"

# 3-7. Кожна відмова · свій код і своя причина. Порожнього stderr бути не може.
for case_reason in "truncated:truncated" "empty:empty_content" "thinking:empty_content" \
                   "prose:not_json" "error:model_error" "overflow:context_overflow"; do
    scenario="${case_reason%%:*}"
    expected="${case_reason##*:}"
    run "$scenario"
    test "$CODE" = 1 || fail "сценарій $scenario мусив упасти, а дав код $CODE"
    printf '%s' "$STDERR" | grep -q "^$expected" \
        || fail "сценарій $scenario: чекали причину «${expected}», маємо «${STDERR}»"
    test ! -e "$WORK/response.json" \
        || fail "сценарій $scenario створив файл відповіді попри відмову"
done

# 8. Думання окремо: причина мусить називати саме його, інакше власник шукатиме
#    дефект у промпті, а не у `think`.
run thinking
printf '%s' "$STDERR" | grep -q 'thinking' || fail "порожній content через думання не назвав причини: $STDERR"

# 9. Журнал бачить КОЖЕН виклик, і успішний, і невдалий.
lines="$(wc -l < "$WORK/state/model-calls.jsonl" | tr -d ' ')"
test "$lines" -ge 9 || fail "журнал має $lines рядків, а викликів було більше"
grep -q '"verdict":"ok"' "$WORK/state/model-calls.jsonl" || fail 'журнал не знає успішних викликів'
grep -q '"verdict":"truncated"' "$WORK/state/model-calls.jsonl" || fail 'журнал не знає обриву на стелі'

# 10. Недоступний endpoint · теж причина, а не мовчання.
printf '{ "version":1, "endpoint":"http://127.0.0.1:1", "default_model":"тест-модель",
  "num_ctx":4096, "timeout_seconds":2, "roles":{"translation-worker":{"schema":"response"}} }' > "$WORK/dead.json"
set +e
STDERR="$(BDO_ROLES_CONFIG="$WORK/dead.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" \
    "$WORK/response.json" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
CODE=$?
set -e
test "$CODE" = 1 || fail "мертвий endpoint дав код $CODE"
printf '%s' "$STDERR" | grep -q 'model_unreachable' || fail "мертвий endpoint без причини: $STDERR"

echo "OK: клієнт моделі падає з причиною на кожному шляху відмови."
