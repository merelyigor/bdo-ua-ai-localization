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
    php "$ROOT/cli/bdo.php" web --stop >/dev/null 2>&1 || true
    test -n "$BLOCKER_PID" && kill "$BLOCKER_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

web() { php "$ROOT/cli/bdo.php" web "$@"; }
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
grep -q 'bdo · прогін' <<<"$page" \
    || fail 'за посиланням віддано не нашу сторінку'

# Екрани окремі (рішення власника 2026-09-05), тому кожен мусить відкриватись
# СВОЇМ шляхом. Один зламаний шлях = екран, у який неможливо потрапити, і на
# сторінці прогону це видно лише мертвим посиланням у навігації.
while IFS='|' read -r screen_path screen_title; do
    body="$(curl -s -m 5 "http://127.0.0.1:$PORT${screen_path}")" \
        || fail "екран $screen_path не відкрився"
    grep -Fq "$screen_title" <<<"$body" \
        || fail "за шляхом $screen_path віддано не той екран (немає «${screen_title}»)"
    grep -q "$TOKEN" <<<"$body" \
        && fail "токен вшитий в екран $screen_path · він мусить приходити лише в посиланні"
done <<'SCREENS'
/|bdo · прогін
/queue|bdo · черга до людини
/sessions|bdo · сесії роботи
/start|bdo · почати прогін
/models|bdo · моделі
SCREENS

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
expect 200 'каталог моделей за токеном' "http://127.0.0.1:$PORT/api/models?t=$TOKEN"
# ІСТОРІЯ МОДЕЛЕЙ ПРИВʼЯЗАНА ДО ПАЧКИ, а не вгадується з порядку часу.
# Дві ролі з різними моделями мусять повернути розгортання з обома ролями.
MODEL_SESSION='20260101_010101'
MODEL_BATCH="${MODEL_SESSION}_aaaaaaaaaaaaaaaa"
mkdir -p "$BDO_STATE_DIR/sessions/$MODEL_SESSION" "$BDO_STATE_DIR/batches/$MODEL_BATCH"
printf '%s\n' '{"id":"20260101_010101","status":"closed","started_at":"2026-01-01T01:01:01+00:00","closed_at":"2026-01-01T01:02:01+00:00","batches":1}' > "$BDO_STATE_DIR/sessions/$MODEL_SESSION/summary.json"
printf '%s\n' "{\"id\":\"$MODEL_BATCH\",\"at\":\"2026-01-01T01:01:01+00:00\"}" > "$BDO_STATE_DIR/sessions/$MODEL_SESSION/batches.jsonl"
printf '%s\n' "{\"id\":\"$MODEL_BATCH\",\"rows\":2,\"state\":\"verified\",\"write\":true}" > "$BDO_STATE_DIR/batches/$MODEL_BATCH/manifest.json"
printf '%s\n' "{\"rows\":2,\"target_written\":2,\"moderation_written\":0,\"quarantine\":0}" > "$BDO_STATE_DIR/batches/$MODEL_BATCH/batch-summary.json"
printf '%s\n' \
    "{\"batch\":\"$MODEL_BATCH\",\"role\":\"translation-worker\",\"state\":\"awaiting_worker\",\"model\":\"model-a\"}" \
    "{\"batch\":\"$MODEL_BATCH\",\"role\":\"translation-qa\",\"state\":\"awaiting_qa\",\"model\":\"model-b\"}" \
    > "$BDO_STATE_DIR/sessions/$MODEL_SESSION/model-calls.jsonl"
model_body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/sessions?t=$TOKEN")"
MODEL_BODY="$model_body" MODEL_BATCH="$MODEL_BATCH" php -r '
$d = json_decode((string) getenv("MODEL_BODY"), true);
foreach ($d["sessions"] ?? [] as $session) {
    foreach ($session["batch_rows"] ?? [] as $row) {
        if (($row["id"] ?? "") !== getenv("MODEL_BATCH")) continue;
        $info = $row["model_info"] ?? [];
        if (($info["kind"] ?? "") !== "multiple" || count($info["roles"] ?? []) !== 2) {
            fwrite(STDERR, "API не повернув моделі за ролями для багатомодельної пачки\n"); exit(1);
        }
        exit(0);
    }
}
fwrite(STDERR, "тестову пачку моделей не знайдено в /api/sessions\n"); exit(1);
' || fail 'моделі ролей не привʼязані до пачки в API'
printf '{"items":["state work"]}\n' >"$BDO_STATE_DIR/work.json"
work_body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/work?path=work.json&t=$TOKEN")"
grep -Fq 'state work' <<<"$work_body" || fail "endpoint файла не віддав state-файл: $work_body"
work_type="$(curl -s -D - -o /dev/null -m 5 "http://127.0.0.1:$PORT/api/work?path=work.json&t=$TOKEN" | tr -d '\r' | grep -i '^Content-Type:' | head -1)"
grep -Fq 'text/plain' <<<"$work_type" || fail "endpoint файла віддав не text/plain: $work_type"
expect 403 'файл без токена' "http://127.0.0.1:$PORT/api/work?path=work.json"
expect 403 'шлях із ..' --get --data-urlencode 'path=../outside.txt' "http://127.0.0.1:$PORT/api/work?t=$TOKEN"
printf 'outside state\n' >"$TMP/outside.txt"
ln -s "$TMP/outside.txt" "$BDO_STATE_DIR/outside-link.txt"
expect 403 'символьне посилання назовні' "http://127.0.0.1:$PORT/api/work?path=outside-link.txt&t=$TOKEN"
expect 403 'абсолютний шлях' --get --data-urlencode "path=$TMP/outside.txt" "http://127.0.0.1:$PORT/api/work?t=$TOKEN"
expect 403 'запит без токена' "http://127.0.0.1:$PORT/api/state"
expect 403 'чужий токен' "http://127.0.0.1:$PORT/api/state?t=00000000000000000000000000000000"
# Сама сторінка · ПОРОЖНЯ оболонка й віддається без токена. Інакше оновлення
# вкладки давало б голий JSON `bad_token`: сторінка навмисно прибирає токен з
# адреси, тому F5 йде на `/` без нього (D75). Дані лишаються за токеном ·
# перевірки нижче це доводять.
expect 200 'сторінка без токена' "http://127.0.0.1:$PORT/"
# Пояснення «немає ключа» живе у спільному скрипті, а місце під нього · у
# кожній оболонці. Без обох частин власник побачив би порожнє вікно без причини.
grep -Fq 'Ця вкладка відкрита без ключа' "$ROOT/web/app.js" \
    || fail 'спільний скрипт не має екрана «немає ключа»'
# І воно мусить казати, що зробити РУКАМИ. Порада «відкрий посилання, яке
# надрукувала команда ./bdo web» адресована тому, хто в термінал не заходить.
grep -Fq 'значком <b>BDO</b>' "$ROOT/web/app.js" \
    || fail 'екран без ключа не каже, чим саме відкрити інтерфейс'
if grep -nE '\./bdo( |<)' "$ROOT/web/app.js" | grep -vE '^\s*[0-9]+: *(//|\*)' | grep -q .; then
    fail 'у спільному скрипті сторінки лишилась команда ./bdo у тексті для власника'
fi
for page in index queue sessions start models; do
    grep -Fq 'id="gate"' "$ROOT/web/$page.html" \
        || fail "у web/$page.html немає місця під пояснення «немає токена»"
done
for page_path in / /queue /sessions /start /models; do
    shell="$(curl -s -m 5 "http://127.0.0.1:$PORT$page_path")"
    for secret in 'batch-summary' 'identity_hash' 'write-log' 'model-calls'; do
        grep -q "$secret" <<<"$shell" \
            && fail "в оболонці екрана $page_path лежать дані ($secret) · вона мусить бути порожньою"
    done
done
expect 200 'ping без токена' "http://127.0.0.1:$PORT/api/ping"
expect 405 'POST' -X POST "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 405 'DELETE' -X DELETE "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 404 'невідомий шлях' "http://127.0.0.1:$PORT/api/anything?t=$TOKEN"
expect 404 '.env' "http://127.0.0.1:$PORT/.env?t=$TOKEN"
expect 404 'обхід теки до .env' --path-as-is "http://127.0.0.1:$PORT/../.env?t=$TOKEN"
expect 404 'файл стану' "http://127.0.0.1:$PORT/state/write-log.jsonl?t=$TOKEN"
expect 404 'сам маршрутизатор' "http://127.0.0.1:$PORT/cli/system/web-router.php?t=$TOKEN"
expect 403 'чуже походження' -H 'Origin: https://evil.example' "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
# Підроблений `Host` не має відкривати чуже походження.
#
# Перелік дозволених джерел раніше будувався з заголовка `Host`, тобто з даних
# КЛІЄНТА: пара `Host: evil.example` + `Origin: http://evil.example` проходила
# перевірку сама себе. Тепер перелік будується з порту, на якому ми слухаємо.
expect 403 'підроблений Host' -H 'Host: evil.example' -H 'Origin: http://evil.example' \
    "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 200 'localhost як своє походження' -H "Origin: http://localhost:$PORT" \
    "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 403 'міжсайтовий запит' -H 'Sec-Fetch-Site: cross-site' "http://127.0.0.1:$PORT/api/state?t=$TOKEN"
expect 200 'своє походження' -H "Origin: http://127.0.0.1:$PORT" "http://127.0.0.1:$PORT/api/state?t=$TOKEN"

# Секрет не має витікати ЖОДНИМ шляхом, тому шукаємо його значення у відповідях.
printf 'BDO_WEB_TEST_SECRET=super-secret-value\n' >"$TMP/state/.env"
for probe in "/.env" "/state/.env" "/api/state" "/api/sessions" "/"; do
    body="$(curl -s -m 5 "http://127.0.0.1:$PORT${probe}?t=$TOKEN" || true)"
    grep -q 'super-secret-value' <<<"$body" \
        && fail "вміст .env видно за шляхом $probe"
done

# --- Помилка не має права ХОВАТИСЬ за обробником ---------------------------
# 2026-09-05 будь-який виняток під вбудованим сервером падав у самому обробнику
# (`Undefined constant STDERR`, бо `STDERR` існує лише в CLI). Наслідок гірший
# за сам виняток: `/api/state` віддавав HTML-помилку з кодом 200, сторінка
# мовчки показувала застарілий знімок, а причину не бачив ніхто (D70).
state_body="$(curl -s -m 10 "http://127.0.0.1:$PORT/api/state?t=$TOKEN")"
grep -qi 'Fatal error\|Undefined constant\|<br />' <<<"$state_body" \
    && fail "у відповіді /api/state лежить PHP-помилка замість стану: $(printf '%s' "$state_body" | head -c 200)"
printf '%s' "$state_body" | php -r 'exit(is_array(json_decode(stream_get_contents(STDIN), true)) ? 0 : 1);' \
    || fail "/api/state віддав не JSON: $(printf '%s' "$state_body" | head -c 200)"
# Складання потоку живе на сервері: сирих рядків журналу сторінка бачити не має.
grep -q '{\\"content\\"' <<<"$state_body" \
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


# --- Вкладки не мають вибирати всі воркери (D76) ---------------------------
# Кожне SSE-зʼєднання займає ОДИН воркер. При чотирьох воркерах і чотирьох
# відкритих вкладках звичайний запит чекав 10.5 с · сторінка «підвисала».
# Дві межі проти цього: воркерів більше за типову кількість вкладок, і схована
# вкладка сама відпускає зʼєднання.
workers_default="$(sed -n 's/.*BDO_WEB_WORKERS.*'"'"'8'"'"'.*/8/p' "$ROOT/lib/Cli/Command/System/WebCommand.php" | head -1)"
test -n "$workers_default" || fail 'не вдалося прочитати кількість воркерів із WebCommand.php'
test "$workers_default" -ge 8 \
    || fail "воркерів $workers_default · чотирьох не вистачало вже на четвертій вкладці (D76)"
grep -Fq 'visibilitychange' "$ROOT/web/app.js" \
    || fail 'схована вкладка не відпускає SSE · кілька вкладок вибирають усі воркери (D76)'
grep -Fq 'pagehide' "$ROOT/web/app.js" \
    || fail 'закрита вкладка не відпускає SSE'

# --- Потік живе стільки, скільки сам собі відміряв ---------------------------
# `max_execution_time` вбудованого сервера (30 с) убивав SSE ФАТАЛЬНОЮ помилкою
# посеред прогону: подія `bye` не приходила ніколи, а `BDO_WEB_STREAM_SECONDS`
# був мертвим числом. Видно це було лише в `state/web.log` · сторінка мовчки
# перепідключалась, тому знімок і зелений тест нічого не показували (помічено на
# живій пачці 20260918_233227).
#
# Перевіряємо тим самим шляхом, але з КОРОТКОЮ стелею php: якщо функція не
# піднімає ліміт сама, потік помре на другій секунді замість пʼятої.
stream_port=$(( BASE_PORT + 900 ))
stream_log="$TMP/stream-server.log"
BDO_WEB_TOKEN="$TOKEN" BDO_WEB_STREAM_SECONDS=5 php -d max_execution_time=2 \
    -S "127.0.0.1:$stream_port" -t "$ROOT/web" "$ROOT/cli/system/web-router.php" \
    >"$stream_log" 2>&1 &
STREAM_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    test "$(code "http://127.0.0.1:$stream_port/api/ping")" = 200 && break
    sleep 0.3
done
stream_body="$(curl -s -m 12 -N "http://127.0.0.1:$stream_port/api/stream?t=$TOKEN" 2>/dev/null || true)"
kill "$STREAM_PID" 2>/dev/null || true
wait "$STREAM_PID" 2>/dev/null || true
grep -Fq 'event: bye' <<<"$stream_body" \
    || fail 'потік обірвався без події bye · стелю виконання тримає php, а не сама функція'
if grep -Fq 'Maximum execution time' "$stream_log"; then
    fail 'SSE падає фатальною помилкою часу виконання · у журналі сервера сміття, а сторінка мовчки перепідключається'
fi

# --- Токени їдуть у ТЕМПІ моделі, а не пачками раз на секунду ----------------
# `filesize()` кешується В МЕЖАХ ЗАПИТУ, а запит потоку живе хвилинами: цикл
# питає розмір 30 разів на секунду й отримує те саме старе число. Заміряно
# 2026-09-19 на живій пачці · модель друкувала ~100 символів/с, а сторінка
# отримувала їх двома подіями по ~70, тобто «ривками по цілому рядку».
# САБОТАЖ: прибрати clearstatcache зі Snapshot · подій знову стане одиниці.
stream2_port=$(( BASE_PORT + 901 ))
stream2_state="$TMP/tempo-state"
mkdir -p "$stream2_state"
: > "$stream2_state/run-stream.log"
BDO_STATE_DIR="$stream2_state" BDO_WEB_TOKEN="$TOKEN" BDO_WEB_STREAM_SECONDS=8 \
    php -S "127.0.0.1:$stream2_port" -t "$ROOT/web" "$ROOT/cli/system/web-router.php" \
    >"$TMP/tempo-server.log" 2>&1 &
TEMPO_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    test "$(code "http://127.0.0.1:$stream2_port/api/ping")" = 200 && break
    sleep 0.3
done
# Пишемо 20 «токенів» на секунду · так друкує локальна модель.
( for i in $(seq 1 80); do
      printf '{"content":"слово%s "}\n' "$i" >> "$stream2_state/run-stream.log"
      sleep 0.05
  done ) &
WRITER_PID=$!
tempo_events="$(curl -s -m 5 -N "http://127.0.0.1:$stream2_port/api/stream?t=$TOKEN" 2>/dev/null \
    | grep -c '^event: tokens' || true)"
kill "$WRITER_PID" "$TEMPO_PID" 2>/dev/null || true
wait "$WRITER_PID" "$TEMPO_PID" 2>/dev/null || true
test "${tempo_events:-0}" -ge 15 \
    || fail "за 4 секунди друку прийшло лише ${tempo_events:-0} подій потоку · сторінка друкуватиме ривками"

# КЛАС, А НЕ ОДИН РЯДОК. Кеш stat живе стільки ж, скільки запит, тому кожне
# читання розміру або часу файла ВСЕРЕДИНІ довгого потоку мусить його скидати.
# Без цього «прогін іде» й вік останнього руху завмирали б на значеннях,
# знятих у мить підключення вкладки.
stat_reads="$(grep -cE 'file(size|mtime)\(' "$ROOT/lib/Web/Snapshot.php")"
stat_clears="$(grep -c 'clearstatcache' "$ROOT/lib/Web/Snapshot.php")"
test "$stat_clears" -ge 3 \
    || fail "у знімку ${stat_reads} читань stat і лише ${stat_clears} скидань кешу · довгий потік бачитиме старі числа"

# --- Скрипт сторінки мусить бути синтаксично цілим -------------------------
# Зламаний JavaScript не видно ні в HTTP-коді (сторінка віддається як завжди),
# ні на скріншоті (розмітка малюється). Видно лише те, що кнопки мертві ·
# 2026-09-05 я вставив у скрипт коментар `#` замість `//`, і сторінка мовчки
# перестала працювати цілком.
if command -v node >/dev/null 2>&1; then
    node --check "$ROOT/web/app.js" >"$TMP/node.txt" 2>&1 \
        || fail "спільний скрипт web/app.js не парситься: $(head -3 "$TMP/node.txt")"
    for page in index queue sessions start models; do
        # Береться ОСТАННІЙ вбудований скрипт: перший · це <script src>.
        php -r '$h = (string) file_get_contents($argv[1]);
            preg_match_all("~<script>(.*?)</script>~s", $h, $m);
            file_put_contents($argv[2], $m[1] ? end($m[1]) : "");' \
            "$ROOT/web/$page.html" "$TMP/$page.js"
        test -s "$TMP/$page.js" || fail "у web/$page.html немає вбудованого скрипта"
        node --check "$TMP/$page.js" >"$TMP/node.txt" 2>&1 \
            || fail "скрипт web/$page.html не парситься: $(head -3 "$TMP/node.txt")"
    done
else
    # Без node беремо грубу, але дієву ознаку того самого класу: коментар `#`
    # у JavaScript є синтаксичною помилкою завжди.
    grep -nE '^\s*# ' "$ROOT/web/"*.html "$ROOT/web/app.js" \
        && fail 'у скрипті сторінки коментар # замість // · це синтаксична помилка JavaScript'
fi

# --- Живий друк мусить бути ПЛАВНИЙ ------------------------------------------
#
# 2026-09-06 власник побачив «дьорганий» друк: сервер читав журнал токенів раз
# на 200 мс, тому за такт прилітав десяток символів, і сторінка малювала їх
# стрибком. Виправлення має ДВІ половини, і жодна сама по собі не досить:
# коротший такт сервера й рівномірний буфер на клієнті.
tick_us="$(sed -n 's/^const STREAM_TICK_US = \([0-9]*\);.*/\1/p' "$ROOT/cli/system/web-router.php")"
test -n "$tick_us" || fail 'не вдалося прочитати такт потоку з cli/system/web-router.php'
test "$tick_us" -le 120000 \
    || fail "такт читання токенів ${tick_us} мкс · за такий час набігає десяток символів, і друк смикає"
for mark in 'requestAnimationFrame' 'carry +=' 'typer:'; do
    grep -Fq "$mark" "$ROOT/web/app.js" \
        || fail "на клієнті немає рівномірного буфера друку (немає «${mark}») · порція малюватиметься стрибком"
done
grep -Fq 'B.typer(' "$ROOT/web/index.html" \
    || fail 'екран прогону не користується буфером друку'
# І навпаки: буфер не має права ковтати текст назавжди · роль договорила,
# залишок показуємо негайно.
grep -Fq 'stream.flush()' "$ROOT/web/index.html" \
    || fail 'буфер друку не спорожняється після завершення ролі · хвіст відповіді не буде видно'

# --- На екран іде СИРИЙ вивід моделі ----------------------------------------
#
# Тут колись жила перевірка вижимки `readable()`: сторінка витягала значення
# відомих ключів і показувала лише їх. Власник 2026-09-17 скасував цей підхід ·
# «друкуй як віддає модель, без додумування», тому й функція, і перевірка
# прибрані разом. Новий контракт стереже `tests/web-live-typing.sh`: показане
# мусить збігатися з надісланим, а JSON лише розкладається відступами.
# Знання про показ живе в `B.streamFeed`, а не на екрані · екран лише віддає
# йому обидва джерела (D83: раніше це знання роздвоїлось між двома місцями).
grep -Fq 'prettyIfJson(raw)' "$ROOT/web/app.js" \
    || fail 'потік ролі не проходить через показ · сторінка знову малюватиме по-своєму'
# Друга друкарка · для роздумів моделі (прототип 01): вони йдуть окремим
# вікном, а не замість відповіді.
grep -Fq 'B.streamFeed(stream, thinkStream)' "$ROOT/web/index.html" \
    || fail 'екран прогону не веде потік через B.streamFeed · логіка показу знову роздвоїлась'

# --- «Модель вантажиться» · окремий підпис, а не мовчання --------------------
#
# Ollama вивантажує вагу за налаштуванням машини власника, і перший виклик
# після паузи тягне 23 ГБ: на живому прогоні це дало 960 с повного мовчання при
# `in=2248`. Для власника це виглядало як «зависло».
grep -Fq 'модель вантажиться' "$ROOT/web/index.html" \
    || fail 'екран не пояснює довгого мовчання перед першим символом'
printf '%s\n' '{"at":"'"$(date -u -v-60S +%Y-%m-%dT%H:%M:%S+00:00 2>/dev/null || date -u -d "60 seconds ago" +%Y-%m-%dT%H:%M:%S+00:00)"'","role":"translation-worker","model":"m","provider":"ollama","event":"start"}' \
    > "$BDO_STATE_DIR/run-stream.log"
php -r '
require $argv[1];
$s = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray()["stream"];
if (($s["waiting"] ?? 0) < 30) {
    fwrite(STDERR, "мовчання від старту виклику не пораховано: ".json_encode($s, JSON_UNESCAPED_UNICODE)."\n"); exit(1);
}
if (($s["role_label"] ?? "") === "") { fwrite(STDERR, "роль не названо\n"); exit(1); }
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || fail 'сервер не рахує, скільки роль мовчить від старту виклику'
# Щойно пішов перший символ · це вже не завантаження.
printf '%s\n' '{"content":"Пере"}' >> "$BDO_STATE_DIR/run-stream.log"
php -r '
require $argv[1];
$s = (new Bdo\Translate\Web\Snapshot($argv[2]))->toArray()["stream"];
if ((int) ($s["waiting"] ?? 0) !== 0) {
    fwrite(STDERR, "після першого символу все ще «вантажиться»: ".json_encode($s, JSON_UNESCAPED_UNICODE)."\n"); exit(1);
}' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" || fail 'підпис «вантажиться» не зникає після першого символу'
rm -f "$BDO_STATE_DIR/run-stream.log"

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
# ПЕРШИЙ ЗНІМОК ЩЕ НЕ Є ПОТОКОМ. Він відправляється ДО циклу, тому перевірка
# лише на нього мовчала, коли цикл падав на першому ж кроці: константи такту
# лежали НИЖЧЕ за `switch`, `const` не піднімається, і `/api/stream` рвався з
# `Undefined constant "STATE_EVERY"` (D84). Сторінка тихо жила на запасному
# опитуванні · тобто отримувала текст раз на секунду цілим шматком.
#
# Тому пишемо в журнал токенів ПОКИ зʼєднання відкрите й вимагаємо подію.
printf '%s\n' '{"at":"'"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"'","role":"translation-worker","model":"m","provider":"ollama","event":"start"}' \
    > "$BDO_STATE_DIR/run-stream.log"
sleep 0.4
printf '%s\n' '{"content":"жива порція потоку"}' >> "$BDO_STATE_DIR/run-stream.log"
wait "$SSE_PID" 2>/dev/null || true
grep -q '^event: state' "$TMP/sse.txt" \
    || fail "SSE не надіслав першого знімка стану. Отримано: $(head -3 "$TMP/sse.txt")"
grep -q '^event: tokens' "$TMP/sse.txt" \
    || fail "SSE не довіз жодної порції тексту · цикл потоку падає одразу після першого знімка. Отримано: $(head -20 "$TMP/sse.txt")"
grep -q 'жива порція потоку' "$TMP/sse.txt" \
    || fail "порція потоку не доїхала до сторінки. Отримано: $(head -20 "$TMP/sse.txt")"
if grep -qE 'Undefined (constant|variable|function)|Fatal error|Uncaught' "$BDO_STATE_DIR/web.log"; then
    fail "сервер писав помилку PHP під час потоку: $(grep -m 3 -E 'Undefined|Fatal|Uncaught' "$BDO_STATE_DIR/web.log")"
fi

# НОВИЙ ВИКЛИК РОЛІ перезаписує журнал токенів із нуля, і зсув потоку від
# попередньої відповіді опиняється ЗА кінцем файла. Поки скидання зсуву було
# недосяжною гілкою, потік після цього мовчав до перепідключення через 300 с ·
# вікно застигало на попередній відповіді (D86). Перевіряємо саме перехід.
curl -s -N -m 5 "http://127.0.0.1:$PORT/api/stream?t=$TOKEN" >"$TMP/sse2.txt" 2>&1 &
SSE2_PID=$!
sleep 0.5
printf '%s\n' '{"content":"перша відповідь ролі"}' >> "$BDO_STATE_DIR/run-stream.log"
sleep 0.5
# Роль договорила · наступний виклик пише журнал ЗАНОВО й коротшим.
printf '%s\n' '{"at":"'"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"'","role":"translation-qa","model":"m","provider":"ollama","event":"start"}' \
    > "$BDO_STATE_DIR/run-stream.log"
printf '%s\n' '{"content":"друга"}' >> "$BDO_STATE_DIR/run-stream.log"
sleep 0.6
wait "$SSE2_PID" 2>/dev/null || true
grep -q 'друга' "$TMP/sse2.txt" \
    || fail "після нового виклику ролі потік замовк · вікно застигне на попередній відповіді. Отримано: $(tail -6 "$TMP/sse2.txt")"

# ПОРОЖНІЙ ПОТІК МУСИТЬ МОВЧАТИ (D168).
#
# «Знімок раз на секунду, і лише коли він СПРАВДІ змінився» не працювало
# ЖОДНОГО разу: `run.elapsed` цокає щосекунди, тому хеш стану щоразу інший, і
# сервер слав ПОВНИЙ знімок кожну секунду навіть на порожній сторінці.
# Заміряно 2026-09-18 на живому сервері: 4 с потоку · 335 КБ, пʼять однакових
# кадрів по 65 КБ, єдина відмінність між сусідніми · `elapsed: 6:15:43 ->
# 6:15:45`. Саме цим каналом і не встигало перезавантаження з великим потоком.
# САБОТАЖ: повернути `md5($encoded)` замість `$fingerprint($state)` · кадрів
# стане стільки ж, скільки секунд.
rm -f "$BDO_STATE_DIR/run-stream.log"
# ТЕСТ НА МЕЖІ, А НЕ НА ЗРУЧНОМУ СТАНІ. Без `run-started-at` поле `elapsed`
# порожнє й не цокає · тоді хеш не міняється САМ СОБОЮ, і перевірка проходить
# навіть на зламаному сервері. Саме так вона й пройшла з поверненим `md5`
# першого разу. Тому спершу робимо прогін «живим».
php -r 'echo time() - 3700;' > "$BDO_STATE_DIR/run-started-at"
curl -s -N -m 4 "http://127.0.0.1:$PORT/api/stream?t=$TOKEN" >"$TMP/sse-idle.txt" 2>&1 || true
rm -f "$BDO_STATE_DIR/run-started-at"
idle_states="$(grep -c '^event: state' "$TMP/sse-idle.txt" || true)"
test "$idle_states" -le 1 \
    || fail "порожній потік надіслав $idle_states знімків за 4 с · сервер шле стан навіть коли нічого не змінилось (D168)"
# І зворотний бік: перший знімок усе одно мусить приїхати, інакше рядок вище
# проходив би на мертвому потоці.
test "$idle_states" -eq 1 \
    || fail 'порожній потік не надіслав ЖОДНОГО знімка · сторінці нічого показати'
# Лічильник сторінка веде сама, тому в знімку мусить бути точка відліку.
grep -q 'started_at' "$TMP/sse-idle.txt" \
    || fail 'у знімку немає run.started_at · сторінці нема від чого рахувати тривалість прогону'

# --- Другий запуск не піднімає другий сервер (вимога власника 2026-09-05) ---
# Без цієї межі зниклий `state/web.json` давав два сервери на одному стані: два
# різні посилання й два токени, і власник не знає, яке з них живе.
started_before="$(grep -c 'Development Server' "$BDO_STATE_DIR/web.log" || true)"
second="$(web --background --no-open 2>&1)" || fail "другий запуск упав: $second"
# Повторний запуск БЕЗ `--no-open` мусить відкрити сторінку: це майже завжди
# «хочу подивитись» (клік по `make web`, повторний `./bdo`), а не «повідом і
# нічого не роби». Підміняємо відкривач і дивимось, що саме він отримав.
mkdir -p "$TMP/fake"
printf '#!/bin/sh\nprintf "%%s" "$1" > "%s/opened.txt"\n' "$TMP/fake" > "$TMP/fake/open"
printf '#!/bin/sh\nprintf "%%s" "$1" > "%s/opened.txt"\n' "$TMP/fake" > "$TMP/fake/xdg-open"
chmod +x "$TMP/fake/open" "$TMP/fake/xdg-open"
rm -f "$TMP/fake/opened.txt"
PATH="$TMP/fake:$PATH" web >/dev/null 2>&1 || true
test -s "$TMP/fake/opened.txt" \
    || fail 'повторний запуск не відкрив сторінку · власник мусив би копіювати посилання руками'
grep -q "$TOKEN" "$TMP/fake/opened.txt" \
    || fail "відкрито не те посилання: $(cat "$TMP/fake/opened.txt")"
rm -f "$TMP/fake/opened.txt"
PATH="$TMP/fake:$PATH" web --no-open >/dev/null 2>&1 || true
test ! -s "$TMP/fake/opened.txt" || fail '--no-open усе одно відкрив браузер'
grep -q 'уже працює' <<<"$second" \
    || fail "другий запуск мусив сказати, що сервер уже працює. Отримано: $second"
grep -q "$PORT" <<<"$second" || fail "другий запуск не назвав чинного порту: $second"
# Рахуємо не рядки (їх стільки, скільки воркерів), а САМ ФАКТ нового старту:
# журнал не має рости після повторного запуску.
started_now="$(grep -c 'Development Server' "$BDO_STATE_DIR/web.log" || true)"
test "$started_now" = "$started_before" \
    || fail "після другого запуску журнал виріс ($started_before -> $started_now) · піднявся ще один сервер"

# Те саме, коли запис зник: сервер живий, а `state/web.json` немає.
cp "$BDO_STATE_DIR/web.json" "$TMP/web.json.bak"
rm -f "$BDO_STATE_DIR/web.json"
lost="$(web --background --no-open 2>&1 || true)"
grep -q 'уже працює' <<<"$lost" \
    || fail "без запису й із живим сервером треба віддати чинне посилання, а не підняти другий: $lost"
grep -q "$TOKEN" <<<"$lost" \
    || fail "втрачений запис · посилання мусить лишитись тим самим (токен живе окремим файлом): $lost"
lost_started="$(grep -c 'Development Server' "$BDO_STATE_DIR/web.log" || true)"
test "$lost_started" = "$started_before" \
    || fail "після запуску з утраченим записом піднявся ще один сервер ($started_before -> $lost_started)"
cp "$TMP/web.json.bak" "$BDO_STATE_DIR/web.json"

# --- --status і --stop ------------------------------------------------------
status="$(web --status)" || fail "--status упав: $status"
grep -q "порт $PORT" <<<"$status" || fail "--status не назвав порт: $status"
grep -q '/api/health -> 200' <<<"$status" || fail "--status не перевіряє живу відповідь: $status"

# ЗАПИС ЗНИК, А СЕРВЕР ЖИВИЙ · найчастіша скарга власника (2026-09-18).
# `state/web.json` прибирає чистка стану, видалення сесії або падіння без
# штатного завершення, а сам сервер далі слухає порт і віддає сторінку. Раніше
# `--status` у цьому разі казав «Сервер не запущено», і `BDO.app` показував
# власникові вікно «посилання на сторінку не знайшлося» · при тому, що
# сторінка в браузері працювала.
# САБОТАЖ: прибрати відновлення в `WebCommand::status` · цей блок червоніє.
mv "$BDO_STATE_DIR/web.json" "$BDO_STATE_DIR/web.json.hidden" || fail 'не вдалося сховати web.json'
lost="$(web --status)" || fail "--status упав без web.json: $lost"
grep -q "порт $PORT" <<<"$lost" \
    || fail "--status не впізнав живий сервер без web.json: $lost"
grep -q "t=$TOKEN" <<<"$lost" \
    || fail "--status віддав не той токен без web.json · сторінка відхилить посилання: $lost"
mv "$BDO_STATE_DIR/web.json.hidden" "$BDO_STATE_DIR/web.json" || fail 'не вдалося повернути web.json'

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
# Дивимось ЛИШЕ на код. Текст довідки переїхав із `web.sh` у сам клас
# (підетап 9.1) і ОПИСУЄ цей дефект словами, разом із прикладом `kill -- -PGID`.
# Перевірка на всьому файлі падала саме на прозі · тобто карала за те, що ми
# пояснили власнику причину. Нижче вирізається nowdoc-блок довідки, і лишається
# виконуваний код, який і є предметом правила.
web_command_code="$(awk '/<<</ && /BDO_HELP_TEXT/ {skip=1} skip && /^BDO_HELP_TEXT;/ {skip=0; next} !skip' \
    "$ROOT/lib/Cli/Command/System/WebCommand.php")"
if grep -nE "['\"]--['\"]|kill[[:space:]]+--[[:space:]]+-" <<<"$web_command_code" | grep -v '^[0-9]*:[[:space:]]*//'; then
    fail 'зупинка вбиває ГРУПУ процесів · разом із сервером загине живий прогін (D68)'
fi
grep -Fq 'portOwners' "$ROOT/lib/Cli/Command/System/WebCommand.php" \
    || fail 'зупинка не цілиться у власників порту · без цього вона або не звільнить порт, або вбʼє зайве'
again="$(web --stop)" || fail 'повторний --stop упав'
grep -q 'Зупиняти нічого' <<<"$again" || fail "повторний --stop мусить сказати, що зупиняти нічого: $again"

# --- Токен переживає перезапуск (D75) --------------------------------------
# Новий токен на кожен запуск робив мертвими і відкриту вкладку, і закладку:
# після рестарту сервера кожен запит даних отримував 403.
restart_out="$(web --background --no-open 2>&1)" || fail "запуск після зупинки впав: $restart_out"
restart_token="$(printf '%s\n' "$restart_out" | sed -n 's~.*t=\([0-9a-f]*\).*~\1~p' | head -1)"
test "$restart_token" = "$TOKEN" \
    || fail "після перезапуску токен змінився ($TOKEN -> $restart_token) · стара вкладка й закладка мертві"
web --stop >/dev/null || fail '--stop після перевірки токена впав'

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
