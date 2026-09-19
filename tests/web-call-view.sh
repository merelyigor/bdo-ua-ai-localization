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
    php "$ROOT/cli/bdo.php" web --stop >/dev/null 2>&1 || true
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
{"at":"$AT","role":"translation-worker","state":"awaiting_worker","rows":1,"payload_bytes":44,"payload":"batches/20260906_120000_abc123/worker-payload.json","answer":"batches/20260906_120000_abc123/worker-answer.json","batch":"20260906_120000_abc123","model":"m","provider":"ollama","verdict":"ok","ms":1200,"in":10,"out":5,"thinking_tokens_estimate":7,"answer_tokens_estimate":5}
{"at":"2026-09-06T09:01:00+00:00","role":"translation-qa","state":"awaiting_qa","rows":1,"payload":"../outside.txt","answer":"/etc/hosts","batch":"20260906_120000_abc123","model":"m","provider":"ollama","verdict":"ok","ms":5}
JSONL

out="$(php "$ROOT/cli/bdo.php" web --background --no-open 2>&1)" || fail "сервер не піднявся: $out"
URL="$(printf '%s\n' "$out" | sed -n 's~.*\(http://127\.0\.0\.1:[0-9]*/?t=[0-9a-f]*\).*~\1~p' | head -1)"
test -n "$URL" || fail "немає посилання у виводі: $out"
PORT="$(printf '%s' "$URL" | sed -n 's~.*127\.0\.0\.1:\([0-9]*\)/.*~\1~p')"
TOKEN="$(printf '%s' "$URL" | sed -n 's~.*t=\([0-9a-f]*\).*~\1~p')"

# --- 1. Екран існує й не носить токена ---------------------------------------
page="$(curl -s -m 5 "http://127.0.0.1:$PORT/call")" || fail 'екран /call не відкрився'
grep -Fq 'bdo · робота ролі' <<<"$page" \
    || fail 'за шляхом /call віддано не той екран'
grep -q "$TOKEN" <<<"$page" \
    && fail 'токен вшитий в екран /call'
# Розгорнути на весь екран і відкрити вкладкою · саме те, що просив власник.
grep -Fq 'requestFullscreen' "$ROOT/web/call.html" \
    || fail 'екран не вміє розгортатись на весь екран'
grep -Fq 'target="_blank"' "$ROOT/web/index.html" \
    || fail 'з прогону не можна відкрити роботу окремою вкладкою'
grep -Fq 'B.streamFeed(stream, thinkStream)' "$ROOT/web/call.html" \
    || fail 'повний екран не показує живий текст і thinking через спільний feed'
for screen in "$ROOT/web/index.html" "$ROOT/web/call.html"; do
    sed -n '/function paintThinking/,/function /p' "$screen" | grep -Fq 'if (atBottom) { box.scrollTop = box.scrollHeight; }' \
        || fail "${screen#"$ROOT/"} примусово не тримає scroll thinking лише внизу"
done
grep -Fq 'if (atBottom) { box.scrollTop = box.scrollHeight; }' "$ROOT/web/call.html" \
    || fail 'окремий екран виклику не має умовного автоскролу live-відповіді'
grep -Fq 'class="empty live-answer-title">Відповідь' "$ROOT/web/index.html" \
    || fail 'live-картка прогону не має заголовка «Відповідь»'
grep -Fq 'class="empty live-section-title">Відповідь' "$ROOT/web/call.html" \
    || fail 'окремий екран виклику не має заголовка «Відповідь»'
grep -Fq 'id="livePayload"' "$ROOT/web/call.html" \
    || fail 'live-екран виклику не показує постійно відкритий запит'
grep -Fq 'id="liveRequestTokens"' "$ROOT/web/index.html" \
    || fail 'live-картка прогону не має лічильника токенів запиту'
grep -Fq 'id="liveThinkingTokens"' "$ROOT/web/index.html" \
    || fail 'live-картка прогону не має лічильника токенів роздумів'
grep -Fq 'id="liveAnswerTokens"' "$ROOT/web/index.html" \
    || fail 'live-картка прогону не має лічильника токенів відповіді'
grep -Fq 'token-count' "$ROOT/web/index.html" \
    && grep -Fq '.token-count' "$ROOT/web/app.css" \
    || fail 'live-лічильники токенів не мають окремого акцентного стилю'
grep -Fq 'tokenCountMarkup(d.out, false)' "$ROOT/web/index.html" \
    || fail 'завершений блок відповіді не має лічильника токенів'
grep -Fq 'tokenCountMarkup(d.thinking_tokens_estimate, true)' "$ROOT/web/index.html" \
    || fail 'завершений блок роздумів не має лічильника токенів'
grep -Fq "'thinking_tokens_estimate' => \$record['thinking_tokens_estimate'] ?? null" "$ROOT/cli/system/web-router.php" \
    || fail 'API завершеного виклику не передає лічильник роздумів'
grep -Fq "'answer_tokens_estimate' => \$record['answer_tokens_estimate'] ?? null" "$ROOT/cli/system/web-router.php" \
    || fail 'API завершеного виклику не передає оцінку відповіді'
grep -Fq 'answer-title' "$ROOT/web/index.html" \
    || fail 'заголовок відповіді не відділений від блока роздумів'
grep -Fq 'id="completedThinking"' "$ROOT/web/call.html" \
    || fail 'завершений виклик не має окремого блока роздумів'
grep -Fq 'id="liveThinkingTokens"' "$ROOT/web/call.html" \
    || fail 'live-блок роздумів не має лічильника токенів'
grep -Fq 'id="liveAnswerTokens"' "$ROOT/web/call.html" \
    || fail 'live-блок відповіді не має лічильника токенів'
grep -Fq 'id="payloadTokens"' "$ROOT/web/call.html" \
    || fail 'блок запиту не має лічильника токенів'
grep -Fq "thinking_tokens_estimate" "$ROOT/lib/Web/Snapshot.php" \
    || fail 'сервер не віддає live-лічильник роздумів'
grep -Fq "answer_tokens_estimate" "$ROOT/cli/model/client.php" \
    || fail 'клієнт моделі не публікує live-лічильник відповіді'
grep -Fq "dataset.autoCollapsed !== '1'" "$ROOT/web/index.html" \
    || fail 'live-прогін повторно згортає роздуми під час друку відповіді'
grep -Fq "dataset.autoCollapsed !== '1'" "$ROOT/web/call.html" \
    || fail 'окремий live-виклик повторно згортає роздуми під час відповіді'

# --- 2. Робота завершеного виклику видна ЦІЛКОМ ------------------------------
body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/call?t=$TOKEN&at=$(php -r 'echo rawurlencode($argv[1]);' "$AT")&role=translation-worker")"
grep -Fq 'Вальків меч' <<<"$body" \
    || fail "відповідь ролі не віддано: $body"
grep -Fq 'Меч Валька' <<<"$body" \
    || fail "запит до ролі не віддано: $body"
grep -Fq 'перекладач' <<<"$body" \
    || fail "роль не названо українською: $body"
grep -Fq '"thinking_tokens_estimate":7' <<<"$body" \
    || fail "API не віддав лічильник роздумів завершеного виклику: $body"
grep -Fq '"answer_tokens_estimate":5' <<<"$body" \
    || fail "API не віддав оцінку відповіді завершеного виклику: $body"

# --- 3. ЧУЖИЙ ФАЙЛ не показується, навіть якщо його просить журнал -----------
# Журнал теж є файлом. Одного джерела довіри для читання файлів мало, тому шлях
# звіряється з текою стану вже на сервері.
body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/call?t=$TOKEN&at=$(php -r 'echo rawurlencode($argv[1]);' '2026-09-06T09:01:00+00:00')&role=translation-qa")"
grep -Fq 'секрет власника' <<<"$body" \
    && fail 'сервер віддав файл ПОЗА текою стану'
grep -q 'localhost' <<<"$body" \
    && fail 'сервер віддав /etc/hosts'
grep -Fq '"payload":null' <<<"$body" \
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
printf '{"at":"2026-01-01T03:51:55+00:00","role":"translation-worker","model":"m","verdict":"ok","ms":1200}\n' \
    > "$BDO_STATE_DIR/sessions/20260101_010101/model-calls.jsonl"
body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/call?t=$TOKEN&session=20260101_010101")"
grep -Fq 'translation-worker' <<<"$body" \
    || fail "журнал сесії не віддано: $body"
grep -Fq 'прогін сесії 20260101_010101' <<<"$body" \
    || fail "вікно не називає, чий це прогін: $body"
grep -Fq '"calls":[{"at":"2026-01-01T03:51:55+00:00"' <<<"$body" \
    || fail "закрита сесія не віддала структуровані виклики ролей: $body"
grep -Fq '"model":"m"' <<<"$body" \
    || fail "закрита сесія не віддала модель виклику: $body"

# --- 6a. КОРЕНЕВИЙ ЕКРАН після закриття сесії -------------------------------
# current-batch лишається історією останньої пачки, але current-session після
# close прибирається. Звʼязок через batches.jsonl мусить повернути архівні
# картки на `/`.
printf '{"id":"20260906_120000_abc123"}\n' \
    > "$BDO_STATE_DIR/sessions/20260101_010101/batches.jsonl"
printf '{"id":"20260906_120000_abc123","state":"verified","rows":1}\n' \
    > "$B/manifest.json"
printf '%s\n' '20260906_120000_abc123' > "$BDO_STATE_DIR/current-batch"
mv "$BDO_STATE_DIR/model-calls.jsonl" \
    "$BDO_STATE_DIR/sessions/20260101_010101/model-calls.jsonl"
state_body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/state?t=$TOKEN")"
grep -Fq '"session":{"id":"20260101_010101"' <<<"$state_body" \
    || fail "закриту сесію не знайдено за поточною пачкою: $state_body"
grep -Fq '"scope":"batch"' <<<"$state_body" \
    || fail "кореневий екран не повернув виклики архівної пачки: $state_body"
grep -Fq '"role_label":"перекладач"' <<<"$state_body" \
    || fail "кореневий екран не повернув картку ролі: $state_body"

# ПОВНИЙ ВИКЛИК ЗАКРИТОЇ СЕСІЇ: модельні файли лежать у batch dir, але ключ
# виклику є лише в перенесеному session/model-calls.jsonl.
mkdir -p "$BDO_STATE_DIR/sessions/20260101_010101" "$BDO_STATE_DIR/batches/20260101_010101_xyz"
printf '{"items":[{"id":"closed","text":"закритий payload"}]}\n' \
    > "$BDO_STATE_DIR/batches/20260101_010101_xyz/closed-payload.json"
printf '{"items":[{"id":"closed","text":"закрита відповідь"}]}\n' \
    > "$BDO_STATE_DIR/batches/20260101_010101_xyz/closed-answer.json"
printf '{"id":"20260101_010101_xyz"}\n' \
    > "$BDO_STATE_DIR/sessions/20260101_010101/batches.jsonl"
CLOSED_AT='2026-01-01T03:52:00+00:00'
cat > "$BDO_STATE_DIR/sessions/20260101_010101/model-calls.jsonl" <<JSONL
{"at":"$CLOSED_AT","role":"translation-worker","state":"awaiting_worker","rows":1,"payload":"batches/20260101_010101_xyz/closed-payload.json","answer":"batches/20260101_010101_xyz/closed-answer.json","batch":"20260101_010101_xyz","model":"m","verdict":"ok","ms":1200}
JSONL
body="$(curl -s -m 5 "http://127.0.0.1:$PORT/api/call?t=$TOKEN&at=$(php -r 'echo rawurlencode($argv[1]);' "$CLOSED_AT")&role=translation-worker")"
grep -Fq 'закритий payload' <<<"$body" || fail "per-call закритої сесії не віддав payload: $body"
grep -Fq 'закрита відповідь' <<<"$body" || fail "per-call закритої сесії не віддав answer: $body"

# Кривий ідентифікатор і сесія без журналів дають ПРИЧИНУ, а не порожнечу.
got="$(code "http://127.0.0.1:$PORT/api/call?t=$TOKEN&session=../../etc")"
test "$got" = 400 || fail "кривий ідентифікатор сесії мусить дати 400, дав $got"
mkdir -p "$BDO_STATE_DIR/sessions/20260101_020202"
got="$(code "http://127.0.0.1:$PORT/api/call?t=$TOKEN&session=20260101_020202")"
test "$got" = 404 || fail "сесія без журналів мусить дати 404 з причиною, дала $got"

# --- 7. Кнопки закритої сесії стоять за СПРАВЖНІМИ командами ------------------
grep -Fq 'class="dropJ"' "$ROOT/web/sessions.html" \
    || fail 'закрита сесія не має окремої кнопки видалення журналів'
grep -Fq 'session.journals.drop' "$ROOT/lib/Run/Actions.php" \
    || fail 'дії «видалити журнали» немає в планувальнику'
grep -Fq "'journals', \$id, '--drop'" "$ROOT/lib/Run/Actions.php" \
    || fail 'видалення журналів не має CLI-команди'
grep -Fq "session.delete" "$ROOT/lib/Run/Actions.php" \
    || fail 'дії «видалити сесію» немає в планувальнику'
grep -Fq '/call?session=' "$ROOT/web/sessions.html" \
    || fail 'на закритій сесії немає посилання «відкрити прогін»'
grep -Fq 'renderSessionCalls(d.calls)' "$ROOT/web/call.html" \
    || fail 'екран закритої сесії не малює картки ролей'
grep -Fq 'class="as-button" target="_blank"' "$ROOT/web/call.html" \
    || fail 'посилання повного виклику не має читабельного оформлення'

# ЗАПИТ ЖИВОГО ВИКЛИКУ НАЗИВАЄ САМ ВИКЛИК, А НЕ ЧАС ЗМІНИ ФАЙЛА.
#
# Сервер вибирав найсвіжіший `*-payload.json` у теці пачки · тобто вгадував.
# 2026-09-19 власник побачив у судді порожній масив замість запиту: за секунду
# до того драйвер записав `names-payload.json` із `[]`, і саме він став
# найсвіжішим, хоча суддя працював над своїм payload на 1487 байтів.
# САБОТАЖ: прибрати гілку зі знаком живого виклику · перевірка почервоніє.
live_dir="$(mktemp -d)"
mkdir -p "$live_dir/batches/b1"
php -r '
$d = $argv[1];
require $argv[2];
file_put_contents("$d/current-batch", "b1");
file_put_contents("$d/batches/b1/judge-payload.json", "[{\"id\":1}]");
touch("$d/batches/b1/judge-payload.json", time() - 60);
file_put_contents("$d/batches/b1/names-payload.json", "[]");
file_put_contents("$d/current-call.json", json_encode([
    "pid" => getmypid(), "role" => "translation-judge",
    "at" => gmdate("c"), "payload" => "batches/b1/judge-payload.json",
]));
$picked = (new Bdo\Translate\Web\Snapshot($d))->livePayload();
if ($picked !== "batches/b1/judge-payload.json") {
    fwrite(STDERR, "живий запит узято не в самого виклику: $picked\n");
    exit(1);
}
' "$live_dir" "$ROOT/lib/autoload.php" || { rm -rf "$live_dir"; fail 'запит живого виклику вгадується за часом файла · суддя знову покаже чужий порожній масив'; }
rm -rf "$live_dir"
grep -Fq "'payload' => \$relative(\$payloadPath)," "$ROOT/cli/model/client.php" \
    || fail 'виклик не називає свій payload у знаку · серверу знову доведеться вгадувати'


# РОБОТА РОЛІ ВСЮДИ ВИГЛЯДАЄ ОДНАКОВО. Живий «Запит» ставив сирий `payload.text`
# від 7.8.3, тому payload у картці прогону був суцільним рядком JSON, а та сама
# робота в «розгорнути роботу» й на екрані виклику · розкладеною відступами.
# Власник помітив розбіжність 2026-09-19. Формат лишається лише показом:
# `prettyWorkText` не переписує даних, він їх розставляє.
grep -Fq 'B.prettyWorkText(text)' "$ROOT/web/index.html" \
    || fail 'живий запит показується повз prettyWorkText · payload знову буде суцільним рядком'
if grep -nE '(textContent|innerHTML) *= *\(d && d\.payload && d\.payload\.text\)' "$ROOT/web/index.html"; then
    fail 'payload ролі виводиться сирим · два різні вигляди однієї роботи'
fi

echo 'web call view: OK · роботу завершеного виклику видно цілком, чужий файл недосяжний, ключ перевіряється.'
