#!/usr/bin/env bash
# Роль-лагоджувач JSON · останній шар автономності й найнебезпечніший.
#
# Рішення власника 2026-09-23: код закриває лише ті форми поломки, які ми вже
# бачили, а їх більше, ніж можна перелічити наперед. Тому останнім шаром стоїть
# модель · автономність дорожча за швидкість.
#
# Небезпека рівно одна: модель, яка переписує відповідь, може дорогою «покращити»
# переклад. Тому роль НЕ Є ДОВІРЕНОЮ: кожне значення звіряється з поламаним
# текстом дослівно, і перше вигадане слово скасовує ремонт цілком. Саме цю межу
# перевірка й стереже · разом із порядком шарів, бо лагоджувач, який кличеться
# першим, коштував би виклику моделі на кожній дрібниці.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
PORT=$((26000 + RANDOM % 900))
cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/router.php" <<'PHP'
<?php
if (str_contains($_SERVER["REQUEST_URI"], "/api/ps")) {
    header("Content-Type: application/json");
    echo json_encode(["models" => [["name" => "тест-модель", "context_length" => 131072]]]);

    return true;
}
$body = (string) file_get_contents("php://input");
// Лагоджувача впізнаємо по його payload: він єдиний несе ключ `broken`.
$isRepair = str_contains($body, '\"broken\"');
@file_put_contents(getenv("CALLS_FILE"), ($isRepair ? "repair" : "role")."\n", FILE_APPEND);
$content = $isRepair
    ? (string) @file_get_contents(getenv("REPAIR_FILE"))
    : (string) @file_get_contents(getenv("BROKEN_FILE"));
header("Content-Type: application/json");
echo json_encode([
    "done_reason" => "stop",
    "prompt_eval_count" => 10,
    "eval_count" => 50,
    "message" => ["content" => $content],
], JSON_UNESCAPED_UNICODE);

return true;
PHP

export CALLS_FILE="$WORK/calls" BROKEN_FILE="$WORK/broken" REPAIR_FILE="$WORK/repair"
: > "$CALLS_FILE"; : > "$BROKEN_FILE"; : > "$REPAIR_FILE"
CALLS_FILE="$CALLS_FILE" BROKEN_FILE="$BROKEN_FILE" REPAIR_FILE="$REPAIR_FILE" \
    php -S "127.0.0.1:$PORT" "$WORK/router.php" >/dev/null 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null 2>&1; then
    printf 'model json repair: ПРОПУЩЕНО · середовище забороняє bind локального mock runtime\n'
    exit 77
fi

mkdir -p "$WORK/state"
RESPONSE="$WORK/state/response.json"
printf '{"items":[{"identity_hash":"aa","source_text":"Sword"}]}' > "$WORK/payload.json"
printf '{"type":"object"}' > "$WORK/schema.json"
cat > "$WORK/roles.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:$PORT", "default_model": "тест-модель",
  "num_ctx": 131072, "timeout_seconds": 30,
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1 } } }
JSON

# ПОЛОМКА, ЯКУ КОД НЕ ЗАКРИВАЄ. Дужки збалансовані, тому детермінований рятунок
# область знайде · і все одно не розбере: всередині немає коми між полями. Саме
# такий клас і має діставатися моделі.
HOPELESS='{"items":[{"identity_hash":"aa" "text":"Меч",},]}'
GOOD='{"items":[{"identity_hash":"aa","text":"Меч"}]}'

run() {
    printf '%s' "$1" > "$BROKEN_FILE"
    printf '%s' "$2" > "$REPAIR_FILE"
    : > "$CALLS_FILE"
    rm -f "$RESPONSE"
    set +e
    STDERR="$(BDO_JSON_REPAIR="${REPAIR_SWITCH:-on}" BDO_MODEL_STREAM=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
        php "$ROOT/cli/model/client.php" translation-worker \
        "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
    CODE=$?
    set -e
}
calls() { grep -c "$1" "$CALLS_FILE" || true; }

# 1. ПОЛОМКА, ЯКУ КОД НЕ ЗАКРИВ, доходить до ролі · і виклик рятується.
run "$HOPELESS" "$GOOD"
test "$CODE" = 0 || fail "лагоджувач не врятував виклик: $STDERR"
test "$(calls repair)" = 1 || fail "роль покликано $(calls repair) разів замість одного"
grep -Fq 'Меч' "$RESPONSE" || fail "полагоджена відповідь не дійшла до файла: $(cat "$RESPONSE")"
grep -Fq 'json-repair' <<<"$STDERR" || fail 'ремонт не названо вголос на екрані прогону'
php -r '
$lines = file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
$entry = json_decode((string) end($lines), true);
exit(str_contains((string) ($entry["json_salvaged"] ?? ""), "json-repair") ? 0 : 1);
' "$WORK/state/model-calls.jsonl" || fail 'журнал не каже, що форму лагодила роль'

# 2. НАЙВАЖЛИВІШЕ · ВИГАДАНИЙ ТЕКСТ СКАСОВУЄ РЕМОНТ. Тут лагоджувач повертає
#    валідний JSON правильної форми, але «покращив» слово. Узяти таке означало б
#    підмінити переклад · саме того, чого роль не має права робити.
run "$HOPELESS" '{"items":[{"identity_hash":"aa","text":"Меч величезний"}]}'
test "$CODE" != 0 || fail 'вигаданий лагоджувачем текст проїхав у відповідь'
grep -Fq 'ВІДХИЛЕНО' <<<"$STDERR" || fail "підміну не названо: $STDERR"
grep -Fq 'not_json' <<<"$STDERR" || fail 'після відхилення виклик не впав із початковою причиною'
test ! -s "$RESPONSE" 2>/dev/null || fail 'файл відповіді створено з підміненим текстом'

# 2.1. Дослівне значення В ІНШОМУ ПОРЯДКУ полів · це ремонт форми, він дозволений.
#      Інакше перевірка забороняла б саме те, заради чого роль існує.
run "$HOPELESS" '{"items":[{"text":"Меч","identity_hash":"aa"}]}'
test "$CODE" = 0 || fail "переставлені поля визнано підміною: $STDERR"

# 3. ПОРЯДОК ШАРІВ. Поломку, яку знімає код, роль бачити не мусить · інакше
#    кожне зайве слово коштувало б зайвого виклику моделі.
run 'items{"items":[{"identity_hash":"aa","text":"Меч"}]}' "$GOOD"
test "$CODE" = 0 || fail "просту поломку не знято кодом: $STDERR"
test "$(calls repair)" = 0 || fail 'роль покликано там, де впорався код'

# 4. Шар вимикається цілком · власник мусить мати вимикач.
REPAIR_SWITCH=off run "$HOPELESS" "$GOOD"
unset REPAIR_SWITCH
test "$CODE" != 0 || fail 'вимикач не вимкнув лагоджувача'
test "$(calls repair)" = 0 || fail 'вимкнену роль усе одно покликано'

# 5. Роль мусить бути самодостатньою й НЕ знати про предмет перекладу · це
#    системна роль, і знання про BDO зробило б її ще одним перекладачем.
grep -Fq 'Black Desert' "$ROOT/roles/json-repair.md" && fail 'системна роль знає про предмет перекладу'
grep -Fq 'ДОСЛІВНО' "$ROOT/roles/json-repair.md" || fail 'промпт не забороняє власний текст'

echo 'model json repair: OK · роль лагодить лише те, чого не зміг код, вигадане слово скасовує ремонт, вимикач працює.'
