#!/usr/bin/env bash
# Локальний сервер інтерфейсу: межа читання, вибір порту й ЖИВА сторінка.
#
# Перевіряється те, чим локальний сервер небезпечний або чим він може збрехати.
#
# 1. Посилання, яке команда надрукувала, справді відкриває сторінку. Порожній
#    вивід не є відповіддю (§12): сервер може стартувати й одразу впасти, і
#    надруковане наперед посилання було б брехнею.
# 2. Лише GET. Дій ще немає, тому будь-який інший метод · відмова.
# 3. Лише перелічені шляхи. `.env`, файли `state/**` і обхід теки · 404, і не
#    тому що заборонені, а тому що відображення «шлях -> файл» у коді немає.
# 4. Токен на кожен запит, включно зі сторінкою; чужий токен · 403.
# 5. Чуже походження · 403. Будь-яка вкладка може постукати на 127.0.0.1.
# 6. Сервер слухає ЛИШЕ loopback, а не всі інтерфейси.
# 7. Воркери справді працюють: при висячому SSE звичайний запит не чекає
#    закінчення потоку. Без цього сторінка мусить відкотитись на опитування.
# 8. Зайнятий типовий порт · беремо вільний і друкуємо ІНШЕ посилання.
#    Зайнятий ЯВНИЙ `BDO_WEB_PORT` · відмова з причиною, а не тихий переїзд.
# 9. Токен не лежить у самій сторінці: він приходить у посиланні й живе в
#    sessionStorage, тому `curl` на сторінку не має його бачити.
#
# Стан тесту живе у власній теці, а типовий порт підмінено `BDO_WEB_DEFAULT_PORT`:
# інакше перевірка зупинила б сервер власника й зайняла його 7654.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v php >/dev/null 2>&1 || fail 'немає php'
command -v curl >/dev/null 2>&1 || { echo 'web server: ПРОПУЩЕНО · немає curl'; exit 0; }

TMP="$(mktemp -d)"
export BDO_STATE_DIR="$TMP/state"
mkdir -p "$BDO_STATE_DIR"
# Порти беремо високі й нетипові: перевірка не має конкурувати з чимось живим.
BASE_PORT=$(( 41000 + RANDOM % 4000 ))
export BDO_WEB_DEFAULT_PORT="$BASE_PORT"
export BDO_WEB_STREAM_SECONDS=6

BLOCKER_PID=""
cleanup() {
    bash "$ROOT/cli/system/web.sh" --stop >/dev/null 2>&1 || true
    test -n "$BLOCKER_PID" && kill "$BLOCKER_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

web() { bash "$ROOT/cli/system/web.sh" "$@"; }
# Код HTTP або `000`, якщо зʼєднання не відкрилось. Голе `x="$(curl …)"` під
# `set -e` валить тест на очікуваній відмові зʼєднання (саме те, що ми
# перевіряємо після `--stop`), тому невдача curl тут не є аварією тесту.
code() {
    local out
    out="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" 2>/dev/null || true)"
    printf '%s' "${out:-000}"
}

# --- 1. Запуск і живе посилання --------------------------------------------
out="$(web --background --no-open 2>&1)" || fail "запуск не вдався: $out"
URL="$(printf '%s\n' "$out" | sed -n 's~.*\(http://127\.0\.0\.1:[0-9]*/?t=[0-9a-f]*\).*~\1~p' | head -1)"
test -n "$URL" || fail "команда не надрукувала посилання. Вивід: $out"
PORT="$(printf '%s' "$URL" | sed -n 's~.*127\.0\.0\.1:\([0-9]*\)/.*~\1~p')"
TOKEN="$(printf '%s' "$URL" | sed -n 's~.*t=\([0-9a-f]*\).*~\1~p')"
test "$PORT" = "$BASE_PORT" || fail "вільний типовий порт мусив бути взятий: очікувався $BASE_PORT, у посиланні $PORT"

page="$(curl -s -m 5 "$URL")" || fail 'сторінка за надрукованим посиланням не відкрилась'
printf '%s' "$page" | grep -q 'bdo · прогін' \
    || fail 'за посиланням віддано не нашу сторінку'

# 9. Токена в тілі сторінки бути не має.
printf '%s' "$page" | grep -q "$TOKEN" \
    && fail 'токен вшитий у сторінку · він мусить приходити лише в посиланні'

test -s "$BDO_STATE_DIR/web.json" || fail 'немає state/web.json після --background'
perm="$(php -r 'printf("%o", fileperms($argv[1]) & 0777);' "$BDO_STATE_DIR/web.json")"
test "$perm" = 600 || fail "state/web.json має права $perm, а в ньому токен · потрібні 600"

# --- 2-5. Межа запитів ------------------------------------------------------
expect() {
    local want="$1" got name
    name="$2"; shift 2
    got="$(code "$@")"
    test "$got" = "$want" || fail "$name: очікувався код $want, отримано $got"
}
expect 200 'здоровʼя за токеном' "http://127.0.0.1:$PORT/api/health?t=$TOKEN"
expect 200 'стан за токеном' "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 200 'сесії за токеном' "http://127.0.0.1:$PORT/api/sessions?t=$TOKEN"
expect 403 'запит без токена' "http://127.0.0.1:$PORT/api/state"
expect 403 'чужий токен' "http://127.0.0.1:$PORT/api/state?t=00000000000000000000000000000000"
expect 403 'сторінка без токена' "http://127.0.0.1:$PORT/"
expect 405 'POST' -X POST "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 405 'DELETE' -X DELETE "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 404 'невідомий шлях' "http://127.0.0.1:$PORT/api/anything?t=$TOKEN"
expect 404 '.env' "http://127.0.0.1:$PORT/.env?t=$TOKEN"
expect 404 'обхід теки до .env' --path-as-is "http://127.0.0.1:$PORT/../.env?t=$TOKEN"
expect 404 'файл стану' "http://127.0.0.1:$PORT/state/write-log.jsonl?t=$TOKEN"
expect 404 'сам маршрутизатор' "http://127.0.0.1:$PORT/cli/system/web-router.php?t=$TOKEN"
expect 403 'чуже походження' -H 'Origin: https://evil.example' "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 403 'міжсайтовий запит' -H 'Sec-Fetch-Site: cross-site' "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 200 'своє походження' -H "Origin: http://127.0.0.1:$PORT" "http://127.0.0.1:$PORT/api/state?t=$TOKEN"

# Секрет не має витікати ЖОДНИМ шляхом, тому шукаємо його значення у відповідях.
printf 'BDO_WEB_TEST_SECRET=super-secret-value\n' >"$TMP/state/.env"
for probe in "/.env" "/state/.env" "/api/state" "/api/sessions" "/"; do
    body="$(curl -s -m 5 "http://127.0.0.1:$PORT${probe}?t=$TOKEN" || true)"
    printf '%s' "$body" | grep -q 'super-secret-value' \
        && fail "вміст .env видно за шляхом $probe"
done

# --- Помилка не має права ХОВАТИСЬ за обробником ---------------------------
# 2026-09-05 будь-який виняток під вбудованим сервером падав у самому обробнику
# (`Undefined constant STDERR`, бо `STDERR` існує лише в CLI). Наслідок гірший
# за сам виняток: `/api/state` віддавав HTML-помилку з кодом 200, сторінка
# мовчки показувала застарілий знімок, а причину не бачив ніхто (D70).
state_body="$(curl -s -m 10 "http://127.0.0.1:$PORT/api/state?t=$TOKEN")"
printf '%s' "$state_body" | grep -qi 'Fatal error\|Undefined constant\|<br />' \
    && fail "у відповіді /api/state лежить PHP-помилка замість стану: $(printf '%s' "$state_body" | head -c 200)"
printf '%s' "$state_body" | php -r 'exit(is_array(json_decode(stream_get_contents(STDIN), true)) ? 0 : 1);' \
    || fail "/api/state віддав не JSON: $(printf '%s' "$state_body" | head -c 200)"
# Складання потоку живе на сервері: сирих рядків журналу сторінка бачити не має.
printf '%s' "$state_body" | grep -q '{\\"content\\"' \
    && fail 'у зібраному тексті потоку лежить сирий NDJSON · сторінка показала б службові рядки (D67)'
grep -Fq 'assemble' "$ROOT/lib/Web/Snapshot.php" \
    || fail 'сервер не складає текст потоку · розбір поїхав би в кожну поверхню окремо (D67)'

# --- Живий потік мусить бути підписаний СВОЄЮ роллю (D73) ------------------
# Роль виклику зʼявляється в журналі лише ПІСЛЯ відповіді, тому сторінка
# чіпляла потік до попереднього, завершеного виклику: у картці «термінолог»
# друкувався текст перекладача. Імʼя береться з події `start` журналу токенів,
# а ознака `fresh` не дає картці «друкує…» висіти після завершення.
printf '%s\n' '{"at":"2026-09-05T00:00:00+00:00","role":"translation-qa","model":"m","provider":"ollama","event":"start"}' \
    '{"content":"Пере"}' '{"content":"клад"}' > "$BDO_STATE_DIR/run-stream.log"
php -r '
require $argv[1];
$s = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray()["stream"];
if (($s["role_label"] ?? "") !== "контроль якості") {
    fwrite(STDERR, "потік підписаний не тією роллю: " . json_encode($s, JSON_UNESCAPED_UNICODE) . "\n"); exit(1);
}
if (($s["text"] ?? "") !== "Переклад") {
    fwrite(STDERR, "текст потоку зібрано неправильно: " . json_encode($s, JSON_UNESCAPED_UNICODE) . "\n"); exit(1);
}
if (($s["fresh"] ?? false) !== true) { fwrite(STDERR, "свіжий журнал не визнано свіжим\n"); exit(1); }
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || fail 'потік не несе ролі або тексту (D73)'

php -r 'touch($argv[1], time() - 300);' "$BDO_STATE_DIR/run-stream.log"
php -r '
require $argv[1];
$s = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray()["stream"];
if (($s["fresh"] ?? true) !== false) {
    fwrite(STDERR, "мовчазний пʼять хвилин журнал усе ще вважається живим друком\n"); exit(1);
}' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || fail 'картка «друкує…» висітиме після завершення (D73)'
# Журнал без події `start` (пошкоджений або обрізаний) НЕ дає вигадати роль:
# порожнє імʼя чесніше за чуже. Клієнт моделі обнуляє цей файл на кожному
# виклику, тому в роботі перший рядок завжди `start` · але покладатися на це
# без перевірки не можна.
printf '%s\n' '{"content":"без початку"}' > "$BDO_STATE_DIR/run-stream.log"
php -r '
require $argv[1];
$s = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray()["stream"];
if (($s["role_label"] ?? "") !== "") {
    fwrite(STDERR, "роль вигадано з журналу без події start: " . json_encode($s, JSON_UNESCAPED_UNICODE) . "\n");
    exit(1);
}' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || fail 'сторінка підписала б потік вигаданою роллю'
rm -f "$BDO_STATE_DIR/run-stream.log"

# --- Живий потік мусить бути підписаний СВОЄЮ роллю (D73) ------------------
# Роль виклику зʼявляється в журналі лише ПІСЛЯ відповіді, тому сторінка
# чіпляла потік до попереднього, завершеного виклику: у картці «термінолог»
# друкувався текст перекладача. Імʼя береться з події `start` журналу токенів,
# а ознака `fresh` не дає картці «друкує…» висіти після завершення.
printf '%s\n' '{"at":"2026-09-05T00:00:00+00:00","role":"translation-qa","model":"m","provider":"ollama","event":"start"}' \
    '{"content":"Пере"}' '{"content":"клад"}' > "$BDO_STATE_DIR/run-stream.log"
php -r '
require $argv[1];
$s = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray()["stream"];
if (($s["role_label"] ?? "") !== "контроль якості") {
    fwrite(STDERR, "потік підписаний не тією роллю: " . json_encode($s, JSON_UNESCAPED_UNICODE) . "\n"); exit(1);
}
if (($s["text"] ?? "") !== "Переклад") {
    fwrite(STDERR, "текст потоку зібрано неправильно: " . json_encode($s, JSON_UNESCAPED_UNICODE) . "\n"); exit(1);
}
if (($s["fresh"] ?? false) !== true) { fwrite(STDERR, "свіжий журнал не визнано свіжим\n"); exit(1); }
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || fail 'потік не несе ролі або тексту (D73)'

php -r 'touch($argv[1], time() - 300);' "$BDO_STATE_DIR/run-stream.log"
php -r '
require $argv[1];
$s = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray()["stream"];
if (($s["fresh"] ?? true) !== false) {
    fwrite(STDERR, "мовчазний пʼять хвилин журнал усе ще вважається живим друком\n"); exit(1);
}' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || fail 'картка «друкує…» висітиме після завершення (D73)'
rm -f "$BDO_STATE_DIR/run-stream.log"

# --- Скрипт сторінки мусить бути синтаксично цілим -------------------------
# Зламаний JavaScript не видно ні в HTTP-коді (сторінка віддається як завжди),
# ні на скріншоті (розмітка малюється). Видно лише те, що кнопки мертві ·
# 2026-09-05 я вставив у скрипт коментар `#` замість `//`, і сторінка мовчки
# перестала працювати цілком.
if command -v node >/dev/null 2>&1; then
    php -r '$h = (string) file_get_contents($argv[1]);
        preg_match("~<script>(.*)</script>~s", $h, $m);
        file_put_contents($argv[2], $m[1] ?? "");' "$ROOT/web/index.html" "$TMP/page.js"
    node --check "$TMP/page.js" >"$TMP/node.txt" 2>&1 \
        || fail "скрипт сторінки не парситься: $(head -3 "$TMP/node.txt")"
else
    # Без node беремо грубу, але дієву ознаку того самого класу: коментар `#`
    # у JavaScript є синтаксичною помилкою завжди.
    grep -nE '^\s*# ' "$ROOT/web/index.html" \
        && fail 'у скрипті сторінки коментар # замість // · це синтаксична помилка JavaScript'
fi

# --- 6. Лише loopback -------------------------------------------------------
grep -q "127.0.0.1:" "$BDO_STATE_DIR/web.log" \
    || fail 'журнал сервера не підтверджує, що він слухає 127.0.0.1'
grep -qE '0\.0\.0\.0|\[::\]' "$BDO_STATE_DIR/web.log" \
    && fail 'сервер слухає не лише loopback'

# --- 7. Воркери: висяче SSE не блокує решти ---------------------------------
# Хибний стан тут вимірюється СЕКУНДАМИ (запит чекає кінця потоку), а не
# десятками мілісекунд, тому поріг узято з великим запасом: він мусить ловити
# однопотоковість, а не швидкість машини.
curl -s -N -m 4 "http://127.0.0.1:$PORT/api/stream?t=$TOKEN" >"$TMP/sse.txt" 2>&1 &
SSE_PID=$!
sleep 0.7
start_ms="$(php -r 'echo (int) round(microtime(true) * 1000);')"
expect 200 'здоровʼя при висячому SSE' "http://127.0.0.1:$PORT/api/health?t=$TOKEN"
end_ms="$(php -r 'echo (int) round(microtime(true) * 1000);')"
elapsed=$(( end_ms - start_ms ))
test "$elapsed" -lt 1000 \
    || fail "при висячому SSE звичайний запит чекав ${elapsed} мс · воркери не працюють, потік мусить відкотитись на опитування"
wait "$SSE_PID" 2>/dev/null || true
grep -q '^event: state' "$TMP/sse.txt" \
    || fail "SSE не надіслав першого знімка стану. Отримано: $(head -3 "$TMP/sse.txt")"

# --- --status і --stop ------------------------------------------------------
status="$(web --status)" || fail "--status упав: $status"
printf '%s' "$status" | grep -q "порт $PORT" || fail "--status не назвав порт: $status"
printf '%s' "$status" | grep -q '/api/health -> 200' || fail "--status не перевіряє живу відповідь: $status"

web --stop >/dev/null || fail '--stop упав'
test ! -e "$BDO_STATE_DIR/web.json" || fail '--stop не прибрав state/web.json'
# ГОЛОВНА перевірка зупинки · порт вільний, а не «процес зник». Воркери
# вбудованого сервера тримають той самий сокет і переживають смерть майстра:
# так `--stop` казав «зупинено», поки сторінка далі відповідала (D65).
stopped_code="$(code "http://127.0.0.1:$PORT/api/health?t=$TOKEN")"
test "$stopped_code" = 000 \
    || fail "після --stop сервер усе ще відповідає кодом $stopped_code · зупинка вбила майстра, але не воркери (D65)"

# ДРУГА половина того самого уроку, і вона тягне в протилежний бік: зупинка НЕ
# має права вбивати роботу, породжену з цього ж сервера. 2026-09-05 `--stop`
# убивав ГРУПУ процесів, і разом із сервером загинула жива пачка на кроці
# `awaiting_worker` (D68) · при обіцянці «сервер можна перезапустити, робота
# триває». Тому групового вбивства в коді бути не може.
if grep -nE 'kill[[:space:]]+--[[:space:]]+-' "$ROOT/cli/system/web.sh" | grep -v '^[0-9]*:#'; then
    fail 'зупинка вбиває ГРУПУ процесів · разом із сервером загине живий прогін (D68)'
fi
grep -Fq 'port_owners' "$ROOT/cli/system/web.sh" \
    || fail 'зупинка не цілиться у власників порту · без цього вона або не звільнить порт, або вбʼє зайве'
again="$(web --stop)" || fail 'повторний --stop упав'
printf '%s' "$again" | grep -q 'Зупиняти нічого' || fail "повторний --stop мусить сказати, що зупиняти нічого: $again"

# --- 8. Порт: зайнятий типовий і зайнятий явний -----------------------------
php -r '
$s = stream_socket_server("tcp://127.0.0.1:".$argv[1], $errno, $err);
if ($s === false) { fwrite(STDERR, "не зайняв порт: $err\n"); exit(1); }
touch($argv[2]);
sleep(40);
' "$BASE_PORT" "$TMP/blocked" 2>"$TMP/blocker.txt" &
BLOCKER_PID=$!
# Чекаємо ДОКАЗУ, що порт зайнято саме нами. Без цього перевірка «зайнятий
# типовий порт» могла б пройти з чужої причини · наприклад, через недобитий
# сервер попереднього кроку, і тоді вона доводила б не те, що написано.
waited=0
while [ ! -e "$TMP/blocked" ] && [ "$waited" -lt 40 ]; do sleep 0.1; waited=$((waited + 1)); done
test -e "$TMP/blocked" \
    || fail "не вдалося зайняти порт $BASE_PORT для перевірки: $(cat "$TMP/blocker.txt" 2>/dev/null)"

busy_out="$(web --background --no-open 2>&1)" || fail "запуск при зайнятому типовому порту упав: $busy_out"
busy_port="$(printf '%s\n' "$busy_out" | sed -n 's~.*127\.0\.0\.1:\([0-9]*\)/?t=.*~\1~p' | head -1)"
test -n "$busy_port" || fail "при зайнятому типовому порту не надруковано посилання: $busy_out"
test "$busy_port" != "$BASE_PORT" || fail 'сервер заявив зайнятий порт своїм'
busy_token="$(printf '%s\n' "$busy_out" | sed -n 's~.*t=\([0-9a-f]*\).*~\1~p' | head -1)"
expect 200 'здоровʼя на підібраному порту' "http://127.0.0.1:$busy_port/api/health?t=$busy_token"
web --stop >/dev/null || fail '--stop після підбору порту упав'

# Явний порт не переїжджає: відмова з причиною.
if BDO_WEB_PORT="$BASE_PORT" web --background --no-open >"$TMP/explicit.txt" 2>&1; then
    web --stop >/dev/null 2>&1 || true
    fail 'зайнятий ЯВНИЙ BDO_WEB_PORT мусить давати відмову, а не інший порт'
fi
grep -q 'задано явно' "$TMP/explicit.txt" \
    || fail "відмова на явний зайнятий порт мусить назвати причину. Отримано: $(cat "$TMP/explicit.txt")"

kill "$BLOCKER_PID" 2>/dev/null || true
BLOCKER_PID=""

# --- Реєстр не ширший за код ------------------------------------------------
php -r '
$r = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$found = [];
foreach ($r["guard_patterns"] ?? [] as $rule) {
    if (str_contains($rule, "bdo web")) $found[] = $rule;
}
if ($found === []) { fwrite(STDERR, "у guard allowlist немає правила для web\n"); exit(1); }
foreach ($found as $rule) {
    if (preg_match("~web \\.\\*|web \\.\\+~", $rule)) {
        fwrite(STDERR, "правило guard відкриває через web будь-що: $rule\n"); exit(1);
    }
}
' "$ROOT/cli/command-registry.json" || fail 'guard allowlist для web ширший за код'

echo 'web server: OK · посилання веде на живу сторінку, лише GET і лише перелічені шляхи, токен обовʼязковий, .env недосяжний, воркери тримають SSE, зайнятий порт названо.'
