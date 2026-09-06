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

# Екрани окремі (рішення власника 2026-09-05), тому кожен мусить відкриватись
# СВОЇМ шляхом. Один зламаний шлях = екран, у який неможливо потрапити, і на
# сторінці прогону це видно лише мертвим посиланням у навігації.
while IFS='|' read -r screen_path screen_title; do
    body="$(curl -s -m 5 "http://127.0.0.1:$PORT${screen_path}")" \
        || fail "екран $screen_path не відкрився"
    printf '%s' "$body" | grep -Fq "$screen_title" \
        || fail "за шляхом $screen_path віддано не той екран (немає «${screen_title}»)"
    printf '%s' "$body" | grep -q "$TOKEN" \
        && fail "токен вшитий в екран $screen_path · він мусить приходити лише в посиланні"
done <<'SCREENS'
/|bdo · прогін
/queue|bdo · черга до людини
/sessions|bdo · сесії роботи
/start|bdo · почати прогін
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
expect 403 'запит без токена' "http://127.0.0.1:$PORT/api/state"
expect 403 'чужий токен' "http://127.0.0.1:$PORT/api/state?t=00000000000000000000000000000000"
# Сама сторінка · ПОРОЖНЯ оболонка й віддається без токена. Інакше оновлення
# вкладки давало б голий JSON `bad_token`: сторінка навмисно прибирає токен з
# адреси, тому F5 йде на `/` без нього (D75). Дані лишаються за токеном ·
# перевірки нижче це доводять.
expect 200 'сторінка без токена' "http://127.0.0.1:$PORT/"
# Пояснення «немає токена» живе у спільному скрипті, а місце під нього · у
# кожній оболонці. Без обох частин власник побачив би порожнє вікно без причини.
grep -Fq 'Немає токена' "$ROOT/web/app.js" \
    || fail 'спільний скрипт не має екрана «немає токена»'
for page in index queue sessions start; do
    grep -Fq 'id="gate"' "$ROOT/web/$page.html" \
        || fail "у web/$page.html немає місця під пояснення «немає токена»"
done
for page_path in / /queue /sessions /start; do
    shell="$(curl -s -m 5 "http://127.0.0.1:$PORT$page_path")"
    for secret in 'batch-summary' 'identity_hash' 'write-log' 'model-calls'; do
        printf '%s' "$shell" | grep -q "$secret" \
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


# --- Вкладки не мають вибирати всі воркери (D76) ---------------------------
# Кожне SSE-зʼєднання займає ОДИН воркер. При чотирьох воркерах і чотирьох
# відкритих вкладках звичайний запит чекав 10.5 с · сторінка «підвисала».
# Дві межі проти цього: воркерів більше за типову кількість вкладок, і схована
# вкладка сама відпускає зʼєднання.
workers_default="$(sed -n 's/^WORKERS="${BDO_WEB_WORKERS:-\([0-9]*\)}"/\1/p' "$ROOT/cli/system/web.sh")"
test -n "$workers_default" || fail 'не вдалося прочитати кількість воркерів із cli/system/web.sh'
test "$workers_default" -ge 8 \
    || fail "воркерів $workers_default · чотирьох не вистачало вже на четвертій вкладці (D76)"
grep -Fq 'visibilitychange' "$ROOT/web/app.js" \
    || fail 'схована вкладка не відпускає SSE · кілька вкладок вибирають усі воркери (D76)'
grep -Fq 'pagehide' "$ROOT/web/app.js" \
    || fail 'закрита вкладка не відпускає SSE'

# --- Скрипт сторінки мусить бути синтаксично цілим -------------------------
# Зламаний JavaScript не видно ні в HTTP-коді (сторінка віддається як завжди),
# ні на скріншоті (розмітка малюється). Видно лише те, що кнопки мертві ·
# 2026-09-05 я вставив у скрипт коментар `#` замість `//`, і сторінка мовчки
# перестала працювати цілком.
if command -v node >/dev/null 2>&1; then
    node --check "$ROOT/web/app.js" >"$TMP/node.txt" 2>&1 \
        || fail "спільний скрипт web/app.js не парситься: $(head -3 "$TMP/node.txt")"
    for page in index queue sessions start; do
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

# --- На екран іде ТЕКСТ, а не JSON ------------------------------------------
#
# Ролі відповідають під strict-схемою, тому модель друкує JSON. 2026-09-06 на
# живому прогоні власник побачив у вікні друку рівно це:
#   ext":"[Доса] Оберіть свій комплект зброї\n\n<PAColor0xFFE9BD23>※ …
# тобто переклад упереміш зі службовими лапками й екранованими переносами.
if command -v node >/dev/null 2>&1; then
    cat > "$TMP/readable.js" <<'JS'
const fs = require('fs');
global.window = { addEventListener() {}, location: { href: 'http://127.0.0.1/' } };
global.document = { addEventListener() {}, getElementById() { return null; }, hidden: false };
global.sessionStorage = { getItem() { return ''; }, setItem() {}, removeItem() {} };
global.history = { replaceState() {} };
global.fetch = () => Promise.resolve({});
eval(fs.readFileSync(process.argv[2], 'utf8'));
const readable = window.BDO.readable;
function check(name, got, want) {
    if (got !== want) {
        console.error(name + ': отримано ' + JSON.stringify(got) + ', очікувалось ' + JSON.stringify(want));
        process.exit(1);
    }
}
// 1. Службове зникає, переноси розгортаються.
check('переклад', readable('{"items":[{"id":"r1","text":"Меч\\nдругий рядок"}]}'), 'Меч\nдругий рядок');
// 2. Обрив посеред значення · нормальний стан потоку, показуємо що є.
check('обрив', readable('{"items":[{"id":"r1","text":"Почав пис'), 'Почав пис');
// 3. Кілька рядків ідуть у ТОМУ порядку, у якому друкувались.
check('порядок', readable('{"items":[{"text":"перший"},{"text":"другий"}]}'), 'перший\n\nдругий');
// 4. Екранована лапка не обриває значення.
check('лапка', readable('{"items":[{"text":"Щит \\"Дуб\\""}]}'), 'Щит "Дуб"');
// 5. Вирок QA і думка судді теж читаються людиною.
check('вирок', readable('{"items":[{"id":"r1","status":"REVIEW","issue":"Русизм у слові"}]}'), 'Русизм у слові');
// 6. Не впізнали формат · мовчати гірше, ніж показати сире.
check('чужий формат', readable('просто текст'), 'просто текст');
// 7. JSON із ВІДСТУПАМИ · саме так друкує термінолог, і саме на ньому перша
//    редакція показувала власнику сирий JSON (виявлено оком 2026-09-06).
check('відступи', readable('{\n  "items": [\n    {\n      "canonical_source": "X",\n'
    + '      "ukrainian_proposal": "[Школяр] Набір",\n      "next_action": ""\n    }\n  ]\n}'),
    '[Школяр] Набір');
// 8а. Порожні поля не дають порожніх рядків: у вироку QA `issue` порожній на
//     кожному чистому рядку, і вікно починалось із десятка переносів.
check('порожні поля', readable('{"items":[{"id":"r1","status":"PASS","issue":""},'
    + '{"id":"r2","status":"REVIEW","issue":"Русизм"}]}'), 'Русизм');
// 8б. Початок конверта · ще не текст. Показаний сирий JSON осідав у
//     накопичувачі назавжди (D83).
check('початок конверта', readable('{"items":[{"id":"r1","te'), '');
check('не JSON узагалі', readable('роль відповіла прозою'), 'роль відповіла прозою');
// 8. Ключ, який трапився НЕ як пара «ключ: значення», не має ламати розбір.
check('ключ у тексті', readable('{"items":[{"text":"слово text без двокрапки"}]}'), 'слово text без двокрапки');
console.log('ok');
JS
    node "$TMP/readable.js" "$ROOT/web/app.js" >/dev/null \
        || fail 'живий друк показує JSON замість тексту моделі (див. причину вище)'
fi
# Потік проходить через `B.readable` усередині `B.streamFeed` · екран лише
# віддає йому обидва джерела (D83: раніше це знання жило на екрані й роздвоїлось).
grep -Fq 'readable(raw)' "$ROOT/web/app.js" \
    || fail 'потік ролі не проганяється через B.readable · у вікні друку знову буде JSON'
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
printf '%s' "$second" | grep -q 'уже працює' \
    || fail "другий запуск мусив сказати, що сервер уже працює. Отримано: $second"
printf '%s' "$second" | grep -q "$PORT" || fail "другий запуск не назвав чинного порту: $second"
# Рахуємо не рядки (їх стільки, скільки воркерів), а САМ ФАКТ нового старту:
# журнал не має рости після повторного запуску.
started_now="$(grep -c 'Development Server' "$BDO_STATE_DIR/web.log" || true)"
test "$started_now" = "$started_before" \
    || fail "після другого запуску журнал виріс ($started_before -> $started_now) · піднявся ще один сервер"

# Те саме, коли запис зник: сервер живий, а `state/web.json` немає.
cp "$BDO_STATE_DIR/web.json" "$TMP/web.json.bak"
rm -f "$BDO_STATE_DIR/web.json"
lost="$(web --background --no-open 2>&1 || true)"
printf '%s' "$lost" | grep -q 'уже працює' \
    || fail "без запису й із живим сервером треба віддати чинне посилання, а не підняти другий: $lost"
printf '%s' "$lost" | grep -q "$TOKEN" \
    || fail "втрачений запис · посилання мусить лишитись тим самим (токен живе окремим файлом): $lost"
lost_started="$(grep -c 'Development Server' "$BDO_STATE_DIR/web.log" || true)"
test "$lost_started" = "$started_before" \
    || fail "після запуску з утраченим записом піднявся ще один сервер ($started_before -> $lost_started)"
cp "$TMP/web.json.bak" "$BDO_STATE_DIR/web.json"

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
