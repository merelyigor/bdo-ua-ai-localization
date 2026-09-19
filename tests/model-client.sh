#!/usr/bin/env bash
# Клієнт локальної моделі мусить ПАДАТИ з причиною, а не деградувати мовчки.
#
# Це заміна дитячої сесії OpenCode, і саме на тихій деградації набір втрачав
# прогони: порожній `content` при ввімкненому думанні (D28), обрив на стелі
# `num_predict` (D29), викинутий початок payload при завищеному вікні (D32).
# Жодна з цих ситуацій не має права виглядати як «спробуємо ще».
#
# Перевіряємо не текстом коду, а поведінкою: піднімаємо ПІДРОБЛЕНИЙ endpoint
# Ollama на вбудованому сервері PHP і дивимось код виходу, причину в stderr,
# наявність файла відповіді та рядок у журналі.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
# Відповідь лежить У ТЕЦІ СТАНУ, як у справжньому прогоні (`state/batches/<пачка>/`).
# Поза нею журнал пише `null` замість шляху · і саме так перевірка «роздуми
# збережені» проходила б на файлі, якого сторінка все одно не побачить.
RESPONSE=""
PORT=$((21000 + RANDOM % 2000))
cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Підроблений Ollama: сценарій задає файл, щоб один сервер обслуговував усі кейси.
cat > "$WORK/router.php" <<'PHP'
<?php
$mode = trim((string) @file_get_contents(getenv("SCENARIO_FILE")));
if (str_contains($_SERVER["REQUEST_URI"], "/api/chat")) {
    // Тіло запиту лишається на диску: тест дивиться, що саме побачила модель.
    $request = (string) file_get_contents("php://input");
    @file_put_contents(getenv("SCENARIO_FILE").".request", $request);
    @file_put_contents(getenv("SCENARIO_FILE").".requests", $request."\n", FILE_APPEND);
}
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
    "alias" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 5,
             "message" => ["content" => '{"items":[{"id":"r2","text":"Щит"},{"id":"r1","text":"Меч"}]}']],
    "alias_unknown" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 5,
             "message" => ["content" => '{"items":[{"id":"r9","text":"Меч"}]}']],
    // Потік обірвався без завершального чанка: сервер помер, мережа впала,
    // проксі закрив зʼєднання. Мовчазно вважати це успіхом не можна · зібраний
    // JSON може бути валідним, а відповідь · неповною.
    "stream_cut" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 5,
             "message" => ["content" => '{"items":[{"identity_hash":"aa","text":"Меч"}]}']],
    // Роздуми приходять окремим полем і НЕ є відповіддю: якщо `content`
    // порожній, це відмова, скільки б роздумів не було (переміряно 2026-09-04).
    "think_only" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 900,
             "message" => ["content" => "", "thinking" => "Спершу подумаю дуже довго…"]],
    // Заміна живого зациклення: модель віддає тільки повторюваний thinking.
    "thinking_loop" => ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 9000,
             "message" => ["content" => "", "thinking" => str_repeat("думай ", 20000)]],
];
$answer = $answers[$mode] ?? $answers["ok"];
// Рантайм, який замовк посеред відповіді: шле трохи роздумів і зависає.
// Саме так виглядала жива відмова 2026-09-19 · і саме її не можна плутати з
// обривом мережі.
if ($mode === "stall") {
    header("Content-Type: application/json");
    echo json_encode(["message" => ["thinking" => "почав думати"], "done" => false]), "\n";
    flush();
    sleep(30);

    return true;
}
if ($mode === "thinking_long") {
    $pieces = [];
    for ($i = 1; $i <= 1800; $i++) {
        $pieces[] = "крок $i пояснює окрему перевірку без повторення попереднього фрагмента";
    }
    $answer = ["done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 1200,
        "message" => ["content" => '{"items":[{"identity_hash":"aa","text":"Меч"}]}', "thinking" => implode(" ", $pieces)]];
}
header("Content-Type: application/json");

// Клієнт просить ПОТІК, тому підробка мусить віддавати NDJSON · інакше тест
// міряв би шлях, якого в роботі немає. Форма чанків та сама, що в Ollama
// 0.33.3: кожен чанк несе шматок `message.content` або `message.thinking`, а
// завершальний · `done:true` разом із `done_reason` і лічильниками.
$body = (string) file_get_contents("php://input");
$wantsStream = str_contains($body, '"stream":true');
if (! $wantsStream || isset($answer["error"])) {
    echo json_encode($answer, JSON_UNESCAPED_UNICODE);
    return true;
}

$content = (string) ($answer["message"]["content"] ?? "");
$thinking = (string) ($answer["message"]["thinking"] ?? "");
$emit = static function (array $chunk): void {
    echo json_encode($chunk, JSON_UNESCAPED_UNICODE), "\n";
};
foreach (mb_str_split($thinking, 5) as $piece) {
    $emit(["message" => ["thinking" => $piece], "done" => false]);
}
foreach (mb_str_split($content, 4) as $piece) {
    $emit(["message" => ["content" => $piece], "done" => false]);
}
// Обрив ПІСЛЯ шматків і БЕЗ завершального чанка · окремий клас відмови.
if ($mode === "stream_cut") {
    return true;
}
$emit([
    "message" => ["content" => ""],
    "done" => true,
    "done_reason" => $answer["done_reason"] ?? "stop",
    "prompt_eval_count" => $answer["prompt_eval_count"] ?? 10,
    "eval_count" => $answer["eval_count"] ?? 5,
]);
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
if ! curl -fsS -m 1 "http://127.0.0.1:$PORT/api/ps" >/dev/null; then
    printf 'model client: SKIP · середовище забороняє bind локального mock runtime\n'
    exit 0
fi

mkdir -p "$WORK/state" "$WORK/roles"
RESPONSE="$WORK/state/response.json"
printf '{"items":[{"identity_hash":"aa","source_text":"Sword"}]}' > "$WORK/payload.json"
printf '{"type":"object"}' > "$WORK/schema.json"
cat > "$WORK/roles.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:$PORT", "default_model": "тест-модель",
  "num_ctx": 131072, "num_predict": 19, "timeout_seconds": 30,
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1, "num_predict": 17 } } }
JSON

run() {
    printf '%s' "$1" > "$SCENARIO_FILE"
    rm -f "$RESPONSE"
    # Файл роздумів теж скидаємо: інакше наступний сценарій побачив би чужий
    # і перевірка «роздуми збережені» проходила б на залишку від попереднього.
    rm -f "$RESPONSE.thinking.txt"
    rm -f "$SCENARIO_FILE.request" "$SCENARIO_FILE.requests"
    set +e
    STDERR="$(BDO_MODEL_THINK="${BDO_TEST_THINK:-0}" BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
        php "$ROOT/cli/model/client.php" translation-worker \
        "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
    CODE=$?
    set -e
}

# 1. Успіх: конверт `{"items":[…]}` розпаковується у масив, файл зʼявляється.
run ok
test "$CODE" = 0 || fail "успішний виклик дав код $CODE: $STDERR"
test -s "$RESPONSE" || fail 'успішний виклик не створив файл відповіді'
grep -q '"num_predict":17' "$SCENARIO_FILE.request" \
    || fail "рольове num_predict не дійшло до Ollama: $(cat "$SCENARIO_FILE.request")"
php -r 'exit(is_array(json_decode(file_get_contents($argv[1]), true)) && array_is_list(json_decode(file_get_contents($argv[1]), true)) ? 0 : 1);' \
    "$RESPONSE" || fail 'відповідь не є JSON-масивом · конвеєр такого не прийме'
# Журнал не має посилатися на шлях, який рушій може використати повторно й
# видалити. Стабільна копія мусить пережити зникнення робочого response-файла.
php -r '
$lines = file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
$entry = json_decode((string) end($lines), true);
$answer = (string) ($entry["answer"] ?? "");
if ($answer === "response.json" || ! is_file($argv[2]."/".$answer)) exit(1);
if (file_get_contents($argv[2]."/".$answer) !== file_get_contents($argv[3])) exit(1);
unlink($argv[3]);
if (! is_file($argv[2]."/".$answer)) exit(1);
' "$WORK/state/model-calls.jsonl" "$WORK/state" "$RESPONSE" \
    || fail 'журнал успішного виклику не зберіг стабільну копію відповіді'

# 1б. ВЛАСНОЇ СТЕЛІ НЕМАЄ. `num_predict` рахує токени роздумів РАЗОМ із
#     відповіддю · виміряно на живій моделі: 32 дало 117 символів thinking і
#     ПОРОЖНІЙ content із `done_reason=length`. Тому стеля різала саме
#     відповідь, а не зациклення. Поле йде в рантайм ЛИШЕ коли його свідомо
#     задали в конфігурації; без цього рядка стеля тихо повернулася б назад.
cat > "$WORK/roles-nopredict.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:$PORT", "default_model": "тест-модель",
  "num_ctx": 131072, "timeout_seconds": 30,
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1 } } }
JSON
printf '%s' ok > "$SCENARIO_FILE"
rm -f "$RESPONSE" "$SCENARIO_FILE.request" "$SCENARIO_FILE.requests"
set +e
BDO_MODEL_THINK=0 BDO_ROLES_CONFIG="$WORK/roles-nopredict.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker \
    "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1
nopredict_code=$?
set -e
test "$nopredict_code" = 0 || fail "виклик без заданої стелі дав код $nopredict_code"
if grep -q 'num_predict' "$SCENARIO_FILE.request"; then
    fail "стеля надіслана в рантайм, хоча її не задано: $(cat "$SCENARIO_FILE.request")"
fi

# 1в. СТЕЛЯ ПО ЧАСУ Є, І ВОНА ЩЕДРА (рішення власника 2026-09-19).
#     900 с виявились замалими · живий виклик обірвався на 1057-й секунді, тому
#     стеля мусить бути щонайменше 1500 с. Нуль лишається значенням «не
#     обривати»: у PHP його не можна віддати рантайму як є, бо це означало б
#     `default_socket_timeout` (60 с), тобто межу ЖОРСТКІШУ за будь-яку нашу.
config_timeout="$(php -r '$c = json_decode(file_get_contents($argv[1]), true); echo (int) ($c["timeout_seconds"] ?? -1);' "$ROOT/config/roles.json")"
test "$config_timeout" -ge 1500 \
    || fail "стеля виклику ${config_timeout} с · замало, живий виклик уже обривався на 1057-й секунді"
grep -Fq '365 * 24 * 3600' "$ROOT/cli/model/client.php" \
    || fail "клієнт більше не перекладає 0 у «без межі» · нуль стане 60-секундним таймаутом сокета"

# 1г. ТАЙМАУТ МАЄ ВЛАСНУ ПРИЧИНУ Й ВИТРАЧЕНІ СЕКУНДИ (вимога власника
#     2026-09-19). Раніше стеля часу давала той самий `stream_incomplete`, що
#     й обрив мережі, тому в журналі дві різні події виглядали однаково.
cat > "$WORK/roles-timeout.json" <<JSON
{ "version": 1, "endpoint": "http://127.0.0.1:$PORT", "default_model": "тест-модель",
  "num_ctx": 131072, "timeout_seconds": 2,
  "roles": { "translation-worker": { "schema": "response", "temperature": 0.1 } } }
JSON
printf '%s' stall > "$SCENARIO_FILE"
rm -f "$RESPONSE"
set +e
timeout_stderr="$(BDO_MODEL_THINK=0 BDO_ROLES_CONFIG="$WORK/roles-timeout.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker \
    "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
timeout_code=$?
set -e
printf '%s' ok > "$SCENARIO_FILE"
test "$timeout_code" = 1 || fail "виклик за стелею часу дав код $timeout_code замість 1"
grep -q '^timeout_error' <<<"$timeout_stderr" \
    || fail "стеля часу названа не своєю причиною: $timeout_stderr"
grep -qE 'витрачено [0-9]+ с' <<<"$timeout_stderr" \
    || fail "причина таймауту не каже, скільки секунд витрачено: $timeout_stderr"
grep -q '"verdict":"timeout_error"' "$WORK/state/model-calls.jsonl" \
    || fail "журнал викликів не записав вирок timeout_error"

# 1д. ЗНАК ЖИВОГО ВИКЛИКУ · роль видно, поки вона працює, навіть коли модель
#     ще мовчить. Файл зʼявляється на старті й ЗНИКАЄ на виході з будь-якої
#     причини · інакше картка «роль працює» висіла б після смерті процесу.
grep -Fq "current-call.json" "$ROOT/cli/model/client.php" \
    || fail 'клієнт не лишає знака живого виклику · картка ролі знову зникне під час завантаження ваги'
grep -Fq 'register_shutdown_function' "$ROOT/cli/model/client.php" \
    || fail 'знак живого виклику не прибирається на виході · він переживе процес'
test ! -e "$WORK/state/current-call.json" \
    || fail 'після завершених викликів лишився знак живого виклику'
run ok
test "$CODE" = 0 || fail "успішний виклик дав код $CODE"
test ! -e "$WORK/state/current-call.json" \
    || fail 'успішний виклик лишив по собі знак живого виклику'
run error
test ! -e "$WORK/state/current-call.json" \
    || fail 'виклик, що впав, лишив по собі знак живого виклику'

# 2. Голий масив без конверта теж приймається: схема ролі може бути й такою.
run envelopeless
test "$CODE" = 0 || fail "голий масив відхилено: $STDERR"

# 3-7. Кожна відмова · свій код і своя причина. Порожнього stderr бути не може.
for case_reason in "truncated:truncated" "empty:empty_content" \
                   "prose:not_json" "error:model_error" "overflow:context_overflow"; do
    scenario="${case_reason%%:*}"
    expected="${case_reason##*:}"
    run "$scenario"
    test "$CODE" = 1 || fail "сценарій $scenario мусив упасти, а дав код $CODE"
    grep -q "^$expected" <<<"$STDERR" \
        || fail "сценарій $scenario: чекали причину «${expected}», маємо «${STDERR}»"
    test ! -e "$RESPONSE" \
        || fail "сценарій $scenario створив файл відповіді попри відмову"
done

# 8. Думання окремо: причина мусить називати саме його, інакше власник шукатиме
#    дефект у промпті, а не у `think`.
run thinking
grep -q 'thinking' <<<"$STDERR" || fail "порожній content через думання не назвав причини: $STDERR"
grep -q '^empty_content' <<<"$STDERR" || fail "роздуми без відповіді не названі empty_content: $STDERR"
grep -q '"think_mismatch":true' "$WORK/state/model-calls.jsonl" \
    || fail 'журнал не показав розбіжність: requested think=false, received thinking'

# 8а. РОЗДУМИ ЗБЕРІГАЮТЬСЯ САМЕ НА ПРОВАЛІ. Цей сценарій завершується
#     `empty_content`, тобто файла відповіді немає взагалі · і єдине, що
#     пояснює власнику, ЩО робила модель, це збережені роздуми. Якби запис
#     стояв після перевірок відповіді, тут не було б нічого.
test -s "$RESPONSE.thinking.txt" \
    || fail 'роздуми не збережені поруч із відповіддю · сторінка не покаже, що робила модель'
php -r '$lines=file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
$d=json_decode((string) end($lines), true);
exit(is_string($d["thinking"] ?? null) && $d["thinking"] !== "" ? 0 : 1);' \
    "$WORK/state/model-calls.jsonl" \
    || fail 'журнал не назвав шляху до збережених роздумів'

# 8б. Штучне зациклення: повторюваний фрагмент перериває потік за секунди.
SECONDS=0
BDO_TEST_THINK=1 run thinking_loop
elapsed="$SECONDS"
test "$CODE" = 1 || fail "зациклений thinking-виклик дав код $CODE"
grep -q '^thinking_loop' <<<"$STDERR" || fail "зациклений thinking не зупинено з thinking_loop: $STDERR"
test "$elapsed" -lt 3 || fail "зациклений thinking не обірвано за секунди: ${elapsed}s"
test "$(wc -l < "$SCENARIO_FILE.requests" | tr -d ' ')" = 2 || fail 'зациклений виклик не повторено рівно один раз'
test "$(grep -c '"think":true' "$SCENARIO_FILE.requests")" = 2 || fail 'повтор зацикленого виклику вимкнув thinking'
grep -q '"thinking_loop_detected":true' "$WORK/state/model-calls.jsonl" || fail 'журнал не довів спрацювання детектора'
# РОЗДУМИ ПЕРЕЖИВАЮТЬ ОБІРВАНИЙ ВИКЛИК. Запис у кінці не давав нічого саме тут:
# зациклений виклик до збирання відповіді не доходить, тому доказ того, що
# робила модель, зникав разом із процесом · доказ для цієї ж роботи довелось
# діставати руками з `state/run-stream.log` (власник 2026-09-16).
test -s "$RESPONSE.thinking.txt" \
    || fail 'роздуми обірваного виклику не збережені · доказ зациклення нізвідки взяти'
# ОДНЕ СЛОВО · саме той випадок, який власник назвав першим. Раніше поріг
# починався з восьми слів, тому в журнал ішло «думай» ×8 замість одного слова.
grep -q '"thinking_repeat_fragment":"думай"' "$WORK/state/model-calls.jsonl" || fail 'журнал не записав повторюваний фрагмент'
php -r '$lines=file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
foreach ($lines as $line) { $d=json_decode($line, true);
    if (($d["thinking_loop_detected"] ?? false) === true) { exit(($d["thinking_repeat_count"] ?? 0) >= 10 ? 0 : 1); } }
exit(1);' "$WORK/state/model-calls.jsonl" \
    || fail 'детектор спрацював менш ніж на десяти повторах поспіль'
loop_elapsed="$elapsed"

# 8в. Довгі, але різні роздуми не можна обрізати за старою байтовою стелею.
SECONDS=0
BDO_TEST_THINK=1 run thinking_long
elapsed="$SECONDS"
test "$CODE" = 0 || fail "довгі різні роздуми помилково зупинені: $STDERR"
test -s "$RESPONSE" || fail 'довгі різні роздуми не дійшли до відповіді'
php -r '$d=json_decode(file_get_contents($argv[1]), true); exit($d === [["identity_hash" => "aa", "text" => "Меч"]] ? 0 : 1);' "$RESPONSE" \
    || fail 'відповідь після довгих різних роздумів не зібралась'
php -r '$lines=file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES); $d=json_decode((string) end($lines), true); exit(($d["thinking_bytes"] ?? 0) > 8192 && ($d["thinking_loop_detected"] ?? true) === false ? 0 : 1);' "$WORK/state/model-calls.jsonl" \
    || fail 'журнал не довів обсяг і відсутність false-positive для різних роздумів'
printf 'thinking regression: loop=%ss, long-different=%ss\n' "${loop_elapsed:-0}" "${elapsed:-0}"

# 9. Журнал бачить КОЖЕН виклик, і успішний, і невдалий.
lines="$(wc -l < "$WORK/state/model-calls.jsonl" | tr -d ' ')"
test "$lines" -ge 9 || fail "журнал має $lines рядків, а викликів було більше"
grep -q '"verdict":"ok"' "$WORK/state/model-calls.jsonl" || fail 'журнал не знає успішних викликів'
grep -q '"verdict":"thinking_loop"' "$WORK/state/model-calls.jsonl" || fail 'журнал не знає зациклення'

# 9б. Журнал мусить знати КРОК і СКІЛЬКИ РЯДКІВ пішло в модель.
#
# Одна роль працює в кількох кроках: `translation-repair` викликається і в
# `healing`, і в `names_pass`, тому два різні проходи лягали в журнал
# однаковими рядками. Питання «чому ремонт двічі на пачку» закрити даними було
# НЕМОЖЛИВО, а «53 секунди» без числа рядків не має знаменника (2026-09-05).
: > "$WORK/state/model-calls.jsonl"
printf '%s' ok > "$SCENARIO_FILE"
rm -f "$RESPONSE"
BDO_RUN_STATE=names_pass BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" \
    "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 || true
grep -q '"state":"names_pass"' "$WORK/state/model-calls.jsonl" \
    || fail "журнал не записав кроку конвеєра: $(cat "$WORK/state/model-calls.jsonl")"
grep -q '"rows":1' "$WORK/state/model-calls.jsonl" \
    || fail "журнал не записав числа рядків payload: $(cat "$WORK/state/model-calls.jsonl")"
grep -qE '"payload_bytes":[0-9]+' "$WORK/state/model-calls.jsonl" \
    || fail "журнал не записав ваги payload · питання «чи полегшав JSON» лишиться без відповіді"

# Чуже значення в журнал не потрапляє: поле читає екран власника.
: > "$WORK/state/model-calls.jsonl"
rm -f "$RESPONSE"
BDO_RUN_STATE='{"зле":1}' BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" \
    "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 || true
grep -q '"state":""' "$WORK/state/model-calls.jsonl" \
    || fail "у журнал пустили довільний рядок як крок: $(cat "$WORK/state/model-calls.jsonl")"

# Голий список рядків рахується так само, як конверт `{"items":[…]}`: форму
# payload читає рівно один клас, і саме тому лічильник не залежить від неї.
: > "$WORK/state/model-calls.jsonl"
printf '[{"identity_hash":"aa"},{"identity_hash":"bb"},{"identity_hash":"cc"}]' > "$WORK/list-payload.json"
rm -f "$RESPONSE"
BDO_RUN_STATE=healing BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/list-payload.json" \
    "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 || true
grep -q '"rows":3' "$WORK/state/model-calls.jsonl" \
    || fail "голий список рядків порахований неправильно: $(cat "$WORK/state/model-calls.jsonl")"

# 10. Недоступний endpoint · теж причина, а не мовчання.
printf '{ "version":1, "endpoint":"http://127.0.0.1:1", "default_model":"тест-модель",
  "num_ctx":4096, "timeout_seconds":2, "roles":{"translation-worker":{"schema":"response"}} }' > "$WORK/dead.json"
set +e
STDERR="$(BDO_ROLES_CONFIG="$WORK/dead.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" \
    "$RESPONSE" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
CODE=$?
set -e
test "$CODE" = 1 || fail "мертвий endpoint дав код $CODE"
grep -q 'model_unreachable' <<<"$STDERR" || fail "мертвий endpoint без причини: $STDERR"

# 11. Хеші не виходять за межу клієнта: модель бачить `r1`, `r2`, а конвеєр ·
#     повні identity_hash. Заміряно 2026-09-04: на QA з 49 рядків ~2 000 із
#     6 447 токенів виходу були копіюванням 64-символьних хешів.
H1="$(printf '%064d' 1)"; H2="$(printf '%064d' 2)"
printf '{"terms":[],"items":[{"identity_hash":"%s","source_text":"Sword"},{"identity_hash":"%s","source_text":"Shield"}]}' "$H1" "$H2" > "$WORK/payload.json"
php -r 'file_put_contents($argv[1], json_encode(["type"=>"object","properties"=>["items"=>["type"=>"array","items"=>[
    "type"=>"object","properties"=>["identity_hash"=>["type"=>"string","enum"=>[$argv[2],$argv[3]]],"text"=>["type"=>"string"]],
    "required"=>["identity_hash","text"],"additionalProperties"=>false]]],"required"=>["items"],"additionalProperties"=>false]));' \
    "$WORK/schema.json" "$H1" "$H2"
run alias
test "$CODE" = 0 || fail "виклик з аліасами впав: $STDERR"
request="$(cat "$SCENARIO_FILE.request")"
grep -q "$H1" <<<"$request" && fail 'модель побачила повний identity_hash у payload'
grep -q '\\"id\\":\\"r1\\"' <<<"$request" || fail "у payload для моделі немає короткого ключа r1: $request"
grep -q '"enum":\["r1","r2"\]' <<<"$request" || fail "схема для моделі не обмежує id переліком r1,r2: $request"
grep -q '"required":\["id","text"\]' <<<"$request" || fail "схема для моделі вимагає не id, а щось інше: $request"
php -r '$a=json_decode(file_get_contents($argv[1]),true);
    if (($a[0]["identity_hash"]??"")!==$argv[3] || ($a[0]["text"]??"")!=="Щит") { fwrite(STDERR, json_encode($a)); exit(1); }
    if (($a[1]["identity_hash"]??"")!==$argv[2] || isset($a[1]["id"])) { fwrite(STDERR, json_encode($a)); exit(1); }' \
    "$RESPONSE" "$H1" "$H2" || fail 'відповідь не повернула повні identity_hash у порядку відповіді моделі'

# 12. Чужий короткий ключ · відмова з причиною, а не здогад про «найближчий» хеш.
run alias_unknown
test "$CODE" = 1 || fail "чужий id мусив дати відмову, а дав код $CODE"
grep -q '^unknown_id' <<<"$STDERR" || fail "чужий id без причини unknown_id: $STDERR"
test ! -e "$RESPONSE" || fail 'чужий id створив файл відповіді'

# 12б. Роль, чия відповідь хеша не несе (термінологія, smoke), бачить payload як є:
#      інакше модель скопіювала б `r1` у поле, де конвеєр чекає на інше.
printf '{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"canonical_source":{"type":"string"}},"required":["canonical_source"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}' > "$WORK/schema-terms.json"
printf '%s' ok > "$SCENARIO_FILE"; rm -f "$RESPONSE"
BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema-terms.json" >/dev/null 2>&1 || true
grep -q "$H1" "$SCENARIO_FILE.request" || fail 'схема без identity_hash усе одно дістала аліаси в payload'

# 12в. ПОТІК · те, чим клієнт ходить за замовчуванням.
#
#      Переміряно 2026-09-04 на Ollama 0.33.3: потік не конфліктує ні зі
#      схемою, ні з думанням (721 чанк, зібраний JSON валідний), і коштує нуль.
#      Тому перевіряється саме він, а одноразова відповідь · як запасний шлях.
run ok
test "$CODE" = 0 || fail "потоковий виклик упав: $STDERR"
php -r 'exit(json_decode(file_get_contents($argv[1]), true) === [["identity_hash" => "aa", "text" => "Меч"]] ? 0 : 1);' \
    "$RESPONSE" || fail 'зібрана з чанків відповідь не збіглася з очікуваною'
grep -q '"stream":true' "$SCENARIO_FILE.request" || fail 'клієнт не просив потоку'
grep -q '"think":false' "$SCENARIO_FILE.request" || fail 'думання мусить бути вимкнене за замовчуванням'
printf 'request fragment think=off: '
grep -o '"think":false' "$SCENARIO_FILE.request" | head -1

# 12г. Обрив потоку без завершального чанка · названа відмова, а не «успіх».
#      Зібраний JSON тут ВАЛІДНИЙ, тому спокуса вважати це успіхом реальна.
run stream_cut
test "$CODE" = 1 || fail "обірваний потік дав код $CODE замість відмови"
grep -q '^stream_incomplete' <<<"$STDERR" || fail "обрив потоку без причини: $STDERR"
test ! -e "$RESPONSE" || fail 'обірваний потік створив файл відповіді'

# 12д. Роздуми не є відповіддю: порожній `content` лишається відмовою.
run think_only
test "$CODE" = 1 || fail "порожній content при довгих роздумах мусив упасти"
grep -q '^empty_content' <<<"$STDERR" || fail "роздуми підмінили відповідь: $STDERR"

# 12е. Думання ВКЛЮЧАЄТЬСЯ явно й тільки явно.
printf '%s' ok > "$SCENARIO_FILE"; rm -f "$RESPONSE"
BDO_MODEL_THINK=1 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 || true
grep -q '"think":true' "$SCENARIO_FILE.request" || fail 'BDO_MODEL_THINK=1 не ввімкнув думання'
grep -q '"think":true' "$WORK/state/model-calls.jsonl" || fail 'журнал не записав, що виклик був із думанням'
printf 'request fragment think=on: '
grep -o '"think":true' "$SCENARIO_FILE.request" | head -1

# 12ж. Запасний шлях: BDO_MODEL_STREAM=0 повертає одноразову відповідь.
printf '%s' ok > "$SCENARIO_FILE"; rm -f "$RESPONSE"
BDO_MODEL_STREAM=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 \
    || fail 'без потоку клієнт мусить працювати старим шляхом'
grep -q '"stream":false' "$SCENARIO_FILE.request" || fail 'BDO_MODEL_STREAM=0 не вимкнув потік'
test -s "$RESPONSE" || fail 'без потоку відповідь не записано'

# 12ж. Persistent settings мають силу над env, а порожній state повертає env
# і конфіг у визначеному порядку.
printf '%s\n' '{"version":1,"think":true}' > "$WORK/state/model-settings.json"
printf '%s' ok > "$SCENARIO_FILE"; rm -f "$RESPONSE"
BDO_MODEL_THINK=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 \
    || fail 'state model settings не застосувались'
grep -q '"think":true' "$SCENARIO_FILE.request" || fail 'state think не має пріоритету над env'

rm -f "$WORK/state/model-settings.json"
printf '%s' ok > "$SCENARIO_FILE"; rm -f "$RESPONSE"
BDO_MODEL_THINK=1 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 \
    || fail 'env model settings не застосувались'
grep -q '"think":true' "$SCENARIO_FILE.request" || fail 'env think не застосувався після порожнього state'

php -r '$c=json_decode(file_get_contents($argv[1]),true); $c["think"]=true; file_put_contents($argv[2],json_encode($c));' \
    "$WORK/roles.json" "$WORK/config-settings.json"
printf '%s' ok > "$SCENARIO_FILE"; rm -f "$RESPONSE"
env -u BDO_MODEL_THINK BDO_ROLES_CONFIG="$WORK/config-settings.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 \
    || fail 'config model settings не застосувались'
grep -q '"think":true' "$SCENARIO_FILE.request" || fail 'config think не застосувався після порожнього state/env'
rm -f "$WORK/state/model-settings.json"

# 13. Вимикач для порівняння: BDO_ROW_ALIAS=0 повертає хеші моделі як є.
printf '%s' ok > "$SCENARIO_FILE"; rm -f "$RESPONSE"
BDO_ROW_ALIAS=0 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
    php "$ROOT/cli/model/client.php" translation-worker "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" >/dev/null 2>&1 || true
grep -q "$H1" "$SCENARIO_FILE.request" || fail 'BDO_ROW_ALIAS=0 не вимкнув аліаси'

# 14. Фальсифікація: кожне старе рішення мусить зламати відповідну регресію.
# Копії ізольовані в tmp, production-файли не змінюються.
VAR_ROOT="$WORK/variant"
mkdir -p "$VAR_ROOT/cli/model"
ln -s "$ROOT/lib" "$VAR_ROOT/lib"
ln -s "$ROOT/roles" "$VAR_ROOT/roles"

variant_prepare() {
    local name="$1"
    mkdir -p "$VAR_ROOT/$name/cli/model"
    ln -s "$ROOT/lib" "$VAR_ROOT/$name/lib"
    ln -s "$ROOT/roles" "$VAR_ROOT/$name/roles"
    cp "$ROOT/cli/model/client.php" "$VAR_ROOT/$name/cli/model/client.php"
}
variant_run() {
    local name="$1" scenario="$2"
    printf '%s' "$scenario" > "$SCENARIO_FILE"
    rm -f "$RESPONSE" "$SCENARIO_FILE.request" "$SCENARIO_FILE.requests"
    set +e
    VAR_STDERR="$(BDO_MODEL_THINK=1 BDO_ROLES_CONFIG="$WORK/roles.json" BDO_STATE_DIR="$WORK/state" \
        php "$VAR_ROOT/$name/cli/model/client.php" translation-worker \
        "$WORK/payload.json" "$RESPONSE" --schema "$WORK/schema.json" 2>&1 >/dev/null)"
    VAR_CODE=$?
    set -e
}

variant_prepare no-detector
# САБОТАЖ МУСИТЬ ГАСИТИ ДЕТЕКТОР, А НЕ ЛАМАТИ PHP. Попередня редакція
# підставляла `&&` через awk `sub()`, де `&` означає ВЕСЬ ЗБІГ · виходив
# синтаксично зламаний файл, і перевірка «падала» з іншої причини, ніж
# заявлено. Тепер поріг просто робиться недосяжним, а код лишається валідним.
sed 's|\$thinkingDup / \$thinkingGrams >= 0.5|\$thinkingDup / \$thinkingGrams >= 99|' \
    "$VAR_ROOT/no-detector/cli/model/client.php" > "$VAR_ROOT/no-detector/cli/model/client.php.tmp"
php -l "$VAR_ROOT/no-detector/cli/model/client.php.tmp" >/dev/null \
    || fail 'саботаж detector зламав синтаксис замість порога'
grep -q 'thinkingGrams >= 99' "$VAR_ROOT/no-detector/cli/model/client.php.tmp" \
    || fail 'саботаж detector не знайшов порога · перевірка стала б фіктивною'
mv "$VAR_ROOT/no-detector/cli/model/client.php.tmp" "$VAR_ROOT/no-detector/cli/model/client.php"
SECONDS=0
variant_run no-detector thinking_loop
variant_elapsed="$SECONDS"
if test "$VAR_CODE" = 0 || grep -q '^thinking_loop' <<<"$VAR_STDERR"; then
    fail 'саботаж detector не зламав loop-регресію'
fi
printf 'sabotage detector: fail in %ss (expected %s)\n' "$variant_elapsed" "${VAR_STDERR%%$'\n'*}"

variant_prepare old-cap
awk '{print; if (index($0, "$thinking = trim") > 0) print "if (strlen($thinking) > 8192) { $fail(\"empty_content\", \"legacy thinking byte cap\"); }"}' \
    "$VAR_ROOT/old-cap/cli/model/client.php" > "$VAR_ROOT/old-cap/cli/model/client.php.tmp"
mv "$VAR_ROOT/old-cap/cli/model/client.php.tmp" "$VAR_ROOT/old-cap/cli/model/client.php"
SECONDS=0
variant_run old-cap thinking_long
variant_elapsed="$SECONDS"
if test "$VAR_CODE" = 0 || ! grep -q '^empty_content' <<<"$VAR_STDERR"; then
    fail 'саботаж старої байтової стелі не зламав довгі різні роздуми'
fi
printf 'sabotage byte-cap: fail in %ss (expected %s)\n' "$variant_elapsed" "${VAR_STDERR%%$'\n'*}"

variant_prepare no-thinking-retry
awk 'index($0, "$request = $makeRequest($think);") {n++; if (n == 2) {$0 = "            $request = $makeRequest(false);"}} {print}' \
    "$VAR_ROOT/no-thinking-retry/cli/model/client.php" > "$VAR_ROOT/no-thinking-retry/cli/model/client.php.tmp"
mv "$VAR_ROOT/no-thinking-retry/cli/model/client.php.tmp" "$VAR_ROOT/no-thinking-retry/cli/model/client.php"
SECONDS=0
variant_run no-thinking-retry thinking_loop
variant_elapsed="$SECONDS"
if test "$VAR_CODE" = 0 || ! grep -q '"think":false' "$SCENARIO_FILE.requests"; then
    fail 'саботаж retry без thinking не зламав перевірку повтору'
fi
printf 'sabotage retry-thinking: fail in %ss (expected second request think=false)\n' "$variant_elapsed"

echo "OK: клієнт моделі падає з причиною на кожному шляху відмови й ховає хеші за короткими ключами."
