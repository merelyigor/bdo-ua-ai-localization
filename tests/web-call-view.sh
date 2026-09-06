#!/usr/bin/env bash
# Робота ролі відкривається ПІСЛЯ завершення виклику · і тільки з теки стану.
#
# Власник попросив 2026-09-06: побачити всю роботу моделі, коли роль уже
# договорила, розгорнути її на весь екран і відкрити окремою вкладкою. До того
# екран показував лише живий потік, тобто рівно те, що встигло проїхати.
#
# Небезпека тут очевидна: «покажи файл» є читанням файлів. Тому перевіряється не
# тільки те, що потрібний файл видно, а й те, що ЧУЖИЙ · ні, скільки б журнал
# не просив.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v php >/dev/null 2>&1 || fail 'немає php'
command -v curl >/dev/null 2>&1 || { echo 'web call view: ПРОПУЩЕНО · немає curl'; exit 0; }

TMP="$(mktemp -d)"
export BDO_STATE_DIR="$TMP/state"
mkdir -p "$BDO_STATE_DIR/batches/20260906_120000_abc123"
export BDO_WEB_DEFAULT_PORT=$(( 45000 + RANDOM % 3000 ))
cleanup() {
    bash "$ROOT/cli/system/web.sh" --stop >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

B="$BDO_STATE_DIR/batches/20260906_120000_abc123"
printf '%s\n' '{"items":[{"id":"r1","text":"Меч Валька"}]}' > "$B/worker-payload.json"
printf '%s\n' '{"items":[{"id":"r1","text":"Вальків меч"}]}' > "$B/worker-answer.json"
# Файл ПОЗА текою стану · його не має бути видно, скільки б журнал не просив.
printf 'секрет власника\n' > "$TMP/outside.txt"

AT='2026-09-06T09:00:00+00:00'
cat > "$BDO_STATE_DIR/model-calls.jsonl" <<JSONL
{"at":"$AT","role":"translation-worker","state":"awaiting_worker","rows":1,"payload_bytes":44,"payload":"batches/20260906_120000_abc123/worker-payload.json","answer":"batches/20260906_120000_abc123/worker-answer.json","batch":"20260906_120000_abc123","model":"m","provider":"ollama","verdict":"ok","ms":1200,"in":10,"out":5}
{"at":"2026-09-06T09:01:00+00:00","role":"translation-qa","state":"awaiting_qa","rows":1,"payload":"../outside.txt","answer":"/etc/hosts","batch":"20260906_120000_abc123","model":"m","provider":"ollama","verdict":"ok","ms":5}
JSONL

out="$(bash "$ROOT/cli/system/web.sh" --background --no-open 2>&1)" || fail "сервер не піднявся: $out"
URL="$(printf '%s\n' "$out" | sed -n 's~.*\(http://127\.0\.0\.1:[0-9]*/?t=[0-9a-f]*\).*~\1~p' | head -1)"
test -n "$URL" || fail "немає посилання у виводі: $out"
PORT="$(printf '%s' "$URL" | sed -n 's~.*127\.0\.0\.1:\([0-9]*\)/.*~\1~p')"
TOKEN="$(printf '%s' "$URL" | sed -n 's~.*t=\([0-9a-f]*\).*~\1~p')"

# --- 1. Екран існує й не носить токена ---------------------------------------
page="$(curl -s -m 5 "http://127.0.0.1:$PORT/call")" || fail 'екран /call не відкрився'
printf '%s' "$page" | grep -Fq 'bdo · робота ролі' \
    || fail 'за шляхом /call віддано не той екран'
printf '%s' "$page" | grep -q "$TOKEN" \
    && fail 'токен вшитий в екран /call'
# Розгорнути на весь екран і відкрити вкладкою · саме те, що просив власник.
grep -Fq 'requestFullscreen' "$ROOT/web/call.html" \
    || fail 'екран не вміє розгортатись на весь екран'
grep -Fq 'target="_blank"' "$ROOT/web/index.html" \
    || fail 'з прогону не можна відкрити роботу окремою вкладкою'
grep -Fq 'B.streamFeed(stream)' "$ROOT/web/call.html" \
    || fail 'повний екран не показує живого друку тим самим буфером · зʼявиться друга реалізація'

# --- 2. Робота завершеного виклику видна ЦІЛКОМ ------------------------------
body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/call?t=$TOKEN&at=$(php -r 'echo rawurlencode($argv[1]);' "$AT")&role=translation-worker")"
printf '%s' "$body" | grep -Fq 'Вальків меч' \
    || fail "відповідь ролі не віддано: $body"
printf '%s' "$body" | grep -Fq 'Меч Валька' \
    || fail "запит до ролі не віддано: $body"
printf '%s' "$body" | grep -Fq 'перекладач' \
    || fail "роль не названо українською: $body"

# --- 3. ЧУЖИЙ ФАЙЛ не показується, навіть якщо його просить журнал -----------
# Журнал теж є файлом. Одного джерела довіри для читання файлів мало, тому шлях
# звіряється з текою стану вже на сервері.
body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/call?t=$TOKEN&at=$(php -r 'echo rawurlencode($argv[1]);' '2026-09-06T09:01:00+00:00')&role=translation-qa")"
printf '%s' "$body" | grep -Fq 'секрет власника' \
    && fail 'сервер віддав файл ПОЗА текою стану'
printf '%s' "$body" | grep -q 'localhost' \
    && fail 'сервер віддав /etc/hosts'
printf '%s' "$body" | grep -Fq '"payload":null' \
    || fail "шлях за межі теки стану мусить дати null: $body"

# --- 4. Невідомий виклик і кривий ключ дають ПРИЧИНУ --------------------------
code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" 2>/dev/null || printf '000'; }
got="$(code "http://127.0.0.1:$PORT/api/call?t=$TOKEN&at=$(php -r 'echo rawurlencode($argv[1]);' '2026-01-01T00:00:00+00:00')&role=translation-worker")"
test "$got" = 404 || fail "невідомий виклик мусить дати 404, дав $got"
got="$(code "http://127.0.0.1:$PORT/api/call?t=$TOKEN&at=../../etc&role=..")"
test "$got" = 400 || fail "кривий ключ виклику мусить дати 400, дав $got"
got="$(code "http://127.0.0.1:$PORT/api/call?at=$(php -r 'echo rawurlencode($argv[1]);' "$AT")&role=translation-worker")"
test "$got" = 403 || fail "робота ролі без токена мусить дати 403, дала $got"

# --- 5. Журнал СПРАВДІ пише шляхи роботи -------------------------------------
# Без цього все вище перевіряло б лише фікстуру тесту.
grep -Fq "'payload' => \$relative(\$payloadPath)" "$ROOT/cli/model/client.php" \
    || fail 'клієнт моделі не пише шляху payload у журнал викликів'
grep -Fq "'answer' => \$relative(\$responsePath)" "$ROOT/cli/model/client.php" \
    || fail 'клієнт моделі не пише шляху відповіді у журнал викликів'

# --- 6. ЖУРНАЛ ЗАКРИТОЇ СЕСІЇ · те саме вікно, інше джерело -------------------
#
# Прогін, який уже завершився, ніде не було подивитись: екран прогону показує
# ЖИВИЙ стан, а журнали лежать у теці сесії. Власник попросив кнопку «відкрити
# прогін» (макет 02) · це вона.
mkdir -p "$BDO_STATE_DIR/sessions/20260101_010101"
printf '[03:51:55] awaiting_worker · роль translation-worker\n' \
    > "$BDO_STATE_DIR/sessions/20260101_010101/transcript.log"
printf '{"role":"translation-worker","ms":1200}\n' \
    > "$BDO_STATE_DIR/sessions/20260101_010101/model-calls.jsonl"
body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/call?t=$TOKEN&session=20260101_010101")"
printf '%s' "$body" | grep -Fq 'translation-worker' \
    || fail "журнал сесії не віддано: $body"
printf '%s' "$body" | grep -Fq 'прогін сесії 20260101_010101' \
    || fail "вікно не називає, чий це прогін: $body"

# Кривий ідентифікатор і сесія без журналів дають ПРИЧИНУ, а не порожнечу.
got="$(code "http://127.0.0.1:$PORT/api/call?t=$TOKEN&session=../../etc")"
test "$got" = 400 || fail "кривий ідентифікатор сесії мусить дати 400, дав $got"
mkdir -p "$BDO_STATE_DIR/sessions/20260101_020202"
got="$(code "http://127.0.0.1:$PORT/api/call?t=$TOKEN&session=20260101_020202")"
test "$got" = 404 || fail "сесія без журналів мусить дати 404 з причиною, дала $got"

# --- 7. Кнопки закритої сесії стоять за СПРАВЖНІМИ командами ------------------
# Намальована кнопка без команди означала б другу систему поруч із наявною
# (правило 4 теки прототипів).
grep -Fq "session.journals.drop" "$ROOT/lib/Run/Actions.php" \
    || fail 'дії «видалити журнали» немає в планувальнику'
grep -Fq "'journals', \$id, '--drop'" "$ROOT/lib/Run/Actions.php" \
    || fail 'дія не веде до справжньої команди ./bdo session journals'
grep -Fq 'journals [0-9_]' "$ROOT/cli/command-registry.json" \
    || fail 'команда session journals не оголошена в реєстрі · guard її не пустить'
grep -Fq 'class="dropJ"' "$ROOT/web/sessions.html" \
    || fail 'на закритій сесії немає кнопки видалення журналів'
grep -Fq '/call?session=' "$ROOT/web/sessions.html" \
    || fail 'на закритій сесії немає посилання «відкрити прогін»'

echo 'web call view: OK · роботу завершеного виклику видно цілком, чужий файл недосяжний, ключ перевіряється.'
