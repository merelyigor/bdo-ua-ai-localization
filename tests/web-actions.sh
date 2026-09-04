#!/usr/bin/env bash
# Дії сторінки: межа, підтвердження й відповідність реєстру команд.
#
# Що саме тут небезпечно і тому перевіряється.
#
# 1. КНОПКА НЕ МАЄ ВЛАСНОЇ ЛОГІКИ. Кожна дія перетворюється в команду, дозволену
#    в `cli/command-registry.json`. Інакше GUI став би другою системою поруч із
#    конвеєром · тим класом, що дав D50 (меню передало `патч` замість `patch`).
# 2. ДІЯ ЛИШЕ POST І ЛИШЕ ЗІ СВОЄЮ Origin. GET-посилання відкриває будь-хто:
#    картинка на чужому сайті, історія браузера, попередній перегляд у чаті.
# 3. ЗАПИС У PROD ВИМАГАЄ ПІДТВЕРДЖЕННЯ В КОДІ, а не галочки в розмітці:
#    розмітку видно й можна обійти запитом.
# 4. РЯДОК ІЗ БРАУЗЕРА НЕ СТАЄ КОМАНДОЮ. `patch=8; rm -rf /`, `ids=12; ls`,
#    невідомий режим · відмова з причиною, а не спроба виконати.
# 5. ПОМИЛКА JAVASCRIPT ЛИШАЄ СЛІД У ФАЙЛІ. Скріншот показує цілу сторінку й
#    мертву кнопку однаково, тому слід потрібен текстом (§12).
#
# Прогін НЕ запускається: `run.start` перевіряється лише планом і відмовами.
# Виконуються тільки дії сесії · вони живуть у теці стану тесту.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v php >/dev/null 2>&1 || fail 'немає php'
command -v curl >/dev/null 2>&1 || { echo 'web actions: ПРОПУЩЕНО · немає curl'; exit 0; }

# --- 1. План кожної дії мусить бути дозволений реєстром ---------------------
# Це перевірка ЧИСТА: план будується без запуску, тому звірка з allowlist
# нічого не виконує й нічого не змінює.
php -r '
require $argv[1];
use Bdo\Translate\Run\Actions;

$registry = json_decode((string) file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
$patterns = $registry["guard_patterns"] ?? [];
$cases = [
    ["run.start", ["mode" => "patch", "patch" => "8", "batches" => 2]],
    ["run.start", ["mode" => "improve", "patch" => "active", "domain" => "premium_shop"]],
    ["run.start", ["mode" => "manual", "patch" => "1"]],
    ["run.stop", []],
    ["session.new", []],
    ["session.close", []],
    ["session.close", ["drop_journals" => true]],
    ["moderation.approve", ["ids" => [356, 357]]],
    ["moderation.reject", ["ids" => "361", "reason" => "русизм у назві"]],
];
$checked = 0;
foreach ($cases as [$action, $payload]) {
    foreach (Actions::commands($action, $payload) as $command) {
        $ok = false;
        foreach ($patterns as $pattern) {
            if (preg_match("#".str_replace("#", "\\#", $pattern)."#u", $command) === 1) { $ok = true; break; }
        }
        if (! $ok) {
            fwrite(STDERR, "дія $action дає команду поза allowlist реєстру: $command\n");
            exit(1);
        }
        $checked++;
    }
}
// Кожна названа дія мусить мати план: перелік у коді не має права розійтися
// з тим, що сторінка справді може попросити.
foreach (Actions::names() as $name) {
    $payload = match ($name) {
        "run.start" => ["mode" => "patch", "patch" => "1"],
        "moderation.approve" => ["ids" => [1]],
        "moderation.reject" => ["ids" => [1], "reason" => "тест"],
        default => [],
    };
    Actions::plan($name, $payload);
}
printf("планів звірено з реєстром: %d\n", $checked);
' "$ROOT/lib/autoload.php" "$ROOT/cli/command-registry.json" >/dev/null \
    || fail 'план дії не відповідає дозволеним командам реєстру'

# --- 4. Відмови валідації (без сервера, чистою логікою) ---------------------
php -r '
require $argv[1];
use Bdo\Translate\Run\Actions;
$bad = [
    ["run.start", ["mode" => "патч", "patch" => "8"], "чужий режим"],
    ["run.start", ["mode" => "patch", "patch" => "8; rm -rf /"], "команда в патчі"],
    ["run.start", ["mode" => "patch", "patch" => "8", "batches" => 0], "нуль пачок"],
    ["run.start", ["mode" => "patch", "patch" => "8", "batches" => 9999], "понад стелю пачок"],
    ["run.start", ["mode" => "patch", "patch" => "8", "domain" => "bogus"], "чужа категорія"],
    ["moderation.approve", ["ids" => ["12; ls"]], "команда в id"],
    ["moderation.approve", ["ids" => []], "порожній перелік"],
    ["moderation.reject", ["ids" => [1]], "відхилення без причини"],
    ["bogus", [], "невідома дія"],
];
foreach ($bad as [$action, $payload, $label]) {
    try {
        Actions::plan($action, $payload);
        fwrite(STDERR, "пропущено те, що мусило бути відмовлене: $label\n");
        exit(1);
    } catch (Throwable $e) {
        if (trim($e->getMessage()) === "") {
            fwrite(STDERR, "відмова без причини: $label\n");
            exit(1);
        }
    }
}
' "$ROOT/lib/autoload.php" || fail 'валідація дій пропускає небезпечний ввід'

# --- Далі · живий сервер у власній теці стану -------------------------------
TMP="$(mktemp -d)"
export BDO_STATE_DIR="$TMP/state"
mkdir -p "$BDO_STATE_DIR"
export BDO_WEB_DEFAULT_PORT=$(( 45000 + RANDOM % 3000 ))
cleanup() {
    bash "$ROOT/cli/system/web.sh" --stop >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

out="$(bash "$ROOT/cli/system/web.sh" --background --no-open 2>&1)" || fail "сервер не запустився: $out"
URL="$(printf '%s\n' "$out" | sed -n 's~.*\(http://127\.0\.0\.1:[0-9]*/?t=[0-9a-f]*\).*~\1~p' | head -1)"
PORT="$(printf '%s' "$URL" | sed -n 's~.*127\.0\.0\.1:\([0-9]*\)/.*~\1~p')"
TOKEN="$(printf '%s' "$URL" | sed -n 's~.*t=\([0-9a-f]*\).*~\1~p')"
test -n "$PORT" && test -n "$TOKEN" || fail "не розібрав посилання: $out"
BASE="http://127.0.0.1:$PORT"

post() {
    local path="$1" body="$2"
    shift 2
    curl -s -o /dev/null -m 20 -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -H "X-Bdo-Token: $TOKEN" \
        "$@" --data "$body" "$BASE$path?t=$TOKEN" 2>/dev/null || true
}
post_body() {
    local path="$1" body="$2"
    shift 2
    curl -s -m 20 -X POST -H 'Content-Type: application/json' -H "X-Bdo-Token: $TOKEN" \
        "$@" --data "$body" "$BASE$path?t=$TOKEN" 2>/dev/null || true
}
ORIGIN="Origin: $BASE"

# --- 2. Метод і походження --------------------------------------------------
got="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$BASE/api/action?t=$TOKEN" 2>/dev/null || true)"
test "$got" = 405 || fail "GET на /api/action мусить бути 405, отримано $got"

got="$(post /api/action '{"action":"session.new"}')"
test "$got" = 403 || fail "дія без Origin мусить бути 403, отримано $got"

got="$(post /api/action '{"action":"session.new"}' -H 'Origin: https://evil.example')"
test "$got" = 403 || fail "дія з чужим Origin мусить бути 403, отримано $got"

got="$(curl -s -o /dev/null -m 10 -w '%{http_code}' -X POST -H "$ORIGIN" \
    -H 'Content-Type: application/json' --data '{"action":"session.new"}' "$BASE/api/action" 2>/dev/null || true)"
test "$got" = 403 || fail "дія без токена мусить бути 403, отримано $got"

got="$(post /api/action 'не json' -H "$ORIGIN")"
test "$got" = 400 || fail "тіло не-JSON мусить бути 400, отримано $got"

# --- 3. Підтвердження для запису в PROD -------------------------------------
# Патч у цих перевірках навмисно неіснуючий (999999). Якщо перевірка confirm
# колись регресує, дія не має торкнутися справжньої роботи: заміряно на собі ·
# під час фальсифікації цієї самої перевірки сервер пішов виконувати
# `./bdo mode start patch 50 1` проти PROD.
body="$(post_body /api/action '{"action":"run.start","payload":{"mode":"patch","patch":"999999"}}' -H "$ORIGIN")"
printf '%s' "$body" | grep -q 'вимагає підтвердження' \
    || fail "старт без confirm мусить бути відмовлений із причиною. Отримано: $body"
printf '%s' "$body" | grep -q 'action_refused' \
    || fail "відмова мусить мати машиночитаний код. Отримано: $body"

body="$(post_body /api/action '{"action":"moderation.approve","payload":{"ids":[1]}}' -H "$ORIGIN")"
printf '%s' "$body" | grep -q 'вимагає підтвердження' \
    || fail "схвалення без confirm мусить бути відмовлене. Отримано: $body"

# 4. Небезпечний ввід не доходить до команди навіть через сервер.
body="$(post_body /api/action '{"action":"run.start","payload":{"mode":"patch","patch":"1; touch /tmp/bdo-pwned"},"confirm":true}' -H "$ORIGIN")"
printf '%s' "$body" | grep -q 'patch: потрібно' \
    || fail "підстановка в патч мусить бути відмовлена з причиною. Отримано: $body"
test ! -e /tmp/bdo-pwned || { rm -f /tmp/bdo-pwned; fail 'підстановка в патч виконалась · рядок став командою'; }

body="$(post_body /api/action '{"action":"bogus.action","payload":{}}' -H "$ORIGIN")"
printf '%s' "$body" | grep -q 'невідома дія' || fail "невідома дія мусить бути названа. Отримано: $body"

# --- Дії, які МОЖНА виконати в тесті: сесія живе в теці стану ---------------
body="$(post_body /api/action '{"action":"session.new"}' -H "$ORIGIN")"
printf '%s' "$body" | grep -q '"ok":true' || fail "session.new не виконалась: $body"
printf '%s' "$body" | grep -q './bdo session new' \
    || fail "відповідь мусить називати ВИКОНАНУ команду, а не лише результат: $body"
test -f "$BDO_STATE_DIR/current-session" || fail 'session.new не відкрила сесію на диску'

body="$(post_body /api/action '{"action":"session.close"}' -H "$ORIGIN")"
printf '%s' "$body" | grep -q '"ok":true' || fail "session.close не виконалась: $body"
test ! -e "$BDO_STATE_DIR/current-session" || fail 'session.close не закрила сесію'

# Замок: дві дії одночасно неможливі. Перевіряємо сам механізм, а не гонку ·
# зайнятий замок мусить давати відмову з причиною, а не тихо ставати в чергу.
php -r '
require $argv[1];
$fh = fopen($argv[2]."/web-action.lock", "c");
flock($fh, LOCK_EX);
$runner = new Bdo\Translate\Web\Runner($argv[3], $argv[2]);
try {
    $runner->execute("session.new", [], false);
    fwrite(STDERR, "друга дія пройшла під зайнятим замком\n");
    exit(1);
} catch (Throwable $e) {
    if (! str_contains($e->getMessage(), "вже виконується")) {
        fwrite(STDERR, "відмова замка без причини: ".$e->getMessage()."\n");
        exit(1);
    }
}
' "$ROOT/lib/autoload.php" "$BDO_STATE_DIR" "$ROOT" || fail 'замок дій не тримає одночасні виклики'

# --- Ознака «прогін іде» мусить бути ПРАВДИВОЮ -----------------------------
# 2026-09-05 на живому прогоні сторінка писала «драйвер не працює» посеред
# роботи: замок `drive.lock` існує лише під час кроку `run drive`, а найдовше
# в пачці · виклик моделі. Наслідок був не косметичний · кнопка старту лишалась
# живою, і другий прогін на тому самому стані ставав можливим (D69).
#
# Ознака мусить бути ще й СВОЄЮ: на машині може йти інший прогін з іншої теки
# стану, і показувати чужу роботу як свою не можна (це спіймала перша редакція
# цієї ж перевірки · вона бачила справжній прогін власника з тимчасової теки).
running() {
    php -r '
    require $argv[1];
    echo (new Bdo\Translate\Web\Snapshot($argv[2]))->running() ? "yes" : "no";
    ' "$ROOT/lib/autoload.php" "$1"
}
test "$(running "$BDO_STATE_DIR")" = no \
    || fail 'порожній стан вважається прогоном · сторінка показала б чужу роботу як свою'

printf '{"content":"жи"}\n' > "$BDO_STATE_DIR/run-stream.log"
test "$(running "$BDO_STATE_DIR")" = yes \
    || fail 'свіжий рух у журналі токенів не вважається прогоном · сторінка казала б «не працює» посеред роботи (D69)'

# Довга тиша · це «не працює», і саме так і треба показати: завислий прогін не
# має виглядати як робочий.
php -r 'touch($argv[1], time() - 600);' "$BDO_STATE_DIR/run-stream.log"
test "$(running "$BDO_STATE_DIR")" = no \
    || fail 'десятихвилинна тиша все ще вважається прогоном'
rm -f "$BDO_STATE_DIR/run-stream.log"

# --- 5. Помилка сторінки лишає слід у файлі ---------------------------------
got="$(post /api/client-error '{"message":"TypeError: el(...) is null","source":"http://127.0.0.1/index.html","line":42,"stack":"at render"}' -H "$ORIGIN")"
test "$got" = 200 || fail "журнал помилки сторінки відповів $got"
test -s "$BDO_STATE_DIR/web-client.log" || fail 'помилка сторінки не потрапила в state/web-client.log'
grep -q 'TypeError' "$BDO_STATE_DIR/web-client.log" \
    || fail "у журналі немає тексту помилки: $(cat "$BDO_STATE_DIR/web-client.log")"
grep -q ':42' "$BDO_STATE_DIR/web-client.log" \
    || fail 'у журналі немає номера рядка · без нього слід не показує на місце'

# --- Сторінка справді має ці кнопки ----------------------------------------
# Без цієї перевірки дії могли б жити лише в API, а власник не мав би чим їх
# натиснути · і «етап готовий» означало б готовий сервер при мертвому вікні.
page="$(curl -s -m 10 "$URL")"
for marker in 'id="startBtn"' 'id="stopBtn"' 'id="sessNew"' 'id="sessClose"' 'id="modApprove"' 'id="preview"'; do
    printf '%s' "$page" | grep -q "$marker" || fail "на сторінці немає елемента $marker"
done
printf '%s' "$page" | grep -q "api/client-error" \
    || fail 'сторінка не надсилає своїх помилок у журнал'

echo 'web actions: OK · кожна дія є командою з реєстру, POST зі своєю Origin, PROD вимагає підтвердження, рядок із браузера не стає командою, помилка сторінки лишає слід у файлі.'
