#!/usr/bin/env bash
# Рядок не крутиться по колу без межі (D58).
#
# Заміряно 2026-09-04: `state/quarantine.jsonl` мав 597 записів на 84 унікальні
# identity; рядок `32c077fc69e5` пройшов повний конвеєр 21 раз. Вибірка
# `missing=machine&exclude_proposed=1` віддає рядок, доки він не записаний і не
# став пропозицією, а рядку з відмовою в обох каналах (D56) стати ні тим, ні
# тим не дано. Межа мусить бути в нашому коді, незалежно від сервера.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"; mkdir -p "$STATE"

H1="$(printf '%064d' 1)"; H2="$(printf '%064d' 2)"; H3="$(printf '%064d' 3)"

# 1. Журнал рахує спроби по identity; стеля відсікає, нуль вимикає фільтр.
php -r '
require $argv[1];
use Bdo\Translate\Pipeline\RowAttempts;
$a = new RowAttempts($argv[2]);
$a->record($argv[3], "api_glossary_violation", "b1", "proposal");
$a->record($argv[3], "api_glossary_violation", "b2", "proposal");
$a->record($argv[4], "empty_text", "b2", "machine");
$a->record("", "порожній хеш не є рядком", "b2", "machine");
$counts = $a->counts();
if (($counts[$argv[3]] ?? 0) !== 2 || ($counts[$argv[4]] ?? 0) !== 1 || count($counts) !== 2) { fwrite(STDERR, json_encode($counts)); exit(1); }
if ($a->exhausted(2) !== [$argv[3]]) { fwrite(STDERR, "exhausted(2)"); exit(1); }
if ($a->exhausted(0) !== []) { fwrite(STDERR, "нуль мусить вимикати фільтр"); exit(1); }
if (RowAttempts::maxAttempts("") !== RowAttempts::DEFAULT_MAX || RowAttempts::maxAttempts("0") !== 0 || RowAttempts::maxAttempts("5") !== 5) { fwrite(STDERR, "maxAttempts"); exit(1); }
$rows = [["identity_hash" => $argv[3]], ["identity_hash" => $argv[4]], ["identity_hash" => $argv[5]]];
$f = $a->filterRows($rows, 2);
if (count($f["kept"]) !== 2 || $f["dropped"] !== [$argv[3]]) { fwrite(STDERR, json_encode($f)); exit(1); }
$f = $a->filterRows($rows, 0);
if (count($f["kept"]) !== 3) { fwrite(STDERR, "фільтр при нулі"); exit(1); }
$a->clear();
if ($a->counts() !== []) { fwrite(STDERR, "clear"); exit(1); }
' "$ROOT/lib/autoload.php" "$STATE" "$H1" "$H2" "$H3" || fail 'RowAttempts рахує або фільтрує неправильно'

# 2. Вибірка справді фільтрує рядки й зупиняється на порожній сторінці.
PORT=$((29000 + RANDOM % 1000))
cat > "$TMP/router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$log = (string) getenv('ROW_ATTEMPTS_LOG');
file_put_contents($log, $path."\n", FILE_APPEND);
header('Content-Type: application/json');
if ($path === '/taxonomy') {
    echo '{"data":{"field_groups":["classification","tokens","constraints","glossary","reference","patch"]}}';
    return;
}
if ($path === '/rows') {
    $query = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_QUERY);
    if (str_contains($query, 'cursor=next')) {
        echo '{"data":{"rows":[]},"meta":{"has_more":true,"next_cursor":"next"}}';
    } else {
        echo '{"data":{"rows":[{"identity_hash":"' . str_repeat('0', 63) . '1","source_text":"kept"},{"identity_hash":"' . str_repeat('0', 63) . '2","source_text":"exhausted"}]},"meta":{"has_more":true,"next_cursor":"next"}}';
    }
    return;
}
http_response_code(404);
echo '{}';
PHP
cat > "$TMP/env" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test-key
EOF
H_EXHAUSTED="$(printf '%064d' 2)"
printf '%s\n' '{"target":"local","base":"stub","at":"2026-01-01T00:00:00Z","field_groups":"classification,tokens,constraints,glossary,reference,patch","items":{}}' > "$STATE/api-capabilities.local.json"
printf '%s\n%s\n' "{\"identity_hash\":\"$H_EXHAUSTED\"}" "{\"identity_hash\":\"$H_EXHAUSTED\"}" > "$STATE/row-attempts.jsonl"
: > "$TMP/rows.log"
ROW_ATTEMPTS_LOG="$TMP/rows.log" php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break
    sleep .1
done
set +e
out="$(TRANSLATE_ENV_FILE="$TMP/env" BDO_STATE_DIR="$STATE" BDO_FETCH_MAX_PAGES=5 bash "$ROOT/cli/api/fetch-rows.sh" 20 2>"$TMP/fetch.err")"
code=$?
set -e
test "$code" -eq 0 || fail "fetch з фільтром завершився кодом $code: $(cat "$TMP/fetch.err")"
printf '%s' "$out" | grep -Fq 'Отримано: 1 рядків' || fail "вичерпаний рядок потрапив у результат: $out"
grep -Fq 'Пропущено 1 рядків із вичерпаними спробами' "$TMP/fetch.err" || fail 'stderr не назвав число пропущених рядків'
test "$(grep -c '^/rows$' "$TMP/rows.log")" -eq 2 || fail 'порожня сторінка не зупинила обхід'
kill "$SERVER" 2>/dev/null || true
SERVER=''
grep -Fq 'attempts->record' "$ROOT/cli/write/write-translations.sh" || fail 'відмова API не пише в журнал спроб'
grep -Fq 'attempts->record' "$ROOT/cli/batch/batch-commit.sh" || fail 'збій на коміті не пише в журнал спроб'
grep -Fq 'RowAttempts($argv[2]))->clear()' "$ROOT/cli/audit/quarantine-report.sh" || fail '--clear не обнуляє журнал спроб'

# 3. Ціль прогону враховує виключені рядки: сервер каже «лишилось 3», усі три
#    вичерпали спроби · це `goal_complete`, а не вічний `continue_run`.
php -r '
$rows = [["identity_hash" => $argv[2], "source_hash" => hash("sha256", "One"), "source_text" => "One"]];
file_put_contents($argv[1], json_encode(["data" => ["rows" => $rows]], JSON_THROW_ON_ERROR));' "$STATE/rows.json" "$H1"
BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-new.sh" "$STATE/rows.json" >/dev/null
B="$(BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-dir.sh")"
# Завершена пачка · фікстура: перевіряємо конверт completion, не шлях до нього.
php -r '$m=json_decode(file_get_contents($argv[1]),true);$m["state"]="verified";$m["mode"]="patch";$m["patch"]="7";$m["channel"]="machine";
    file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));' "$B/manifest.json"
printf '{"rows":1,"channel":"machine","target_written":1,"target_skipped":0,"target_rejected":0,"moderation_written":0,"moderation_skipped":0,"moderation_rejected":0,"quarantine":0}' > "$B/batch-summary.json"
printf '{"mode":"patch","patch":"7","domain":"","channel":"machine","query":"patch=7&missing=machine"}' > "$STATE/run-goal.json"
printf '{"query":"patch=7&missing=machine","identities":["%s","%s","%s"]}' "$H1" "$H2" "$H3" > "$STATE/run-excluded.json"
out="$(BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 BDO_GOAL_REMAINING_STUB=3 BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null | tail -1)"
jq -e '.next.kind == "goal_complete" and .next.waiting_human == 3' <<<"$out" >/dev/null \
    || fail "три виключені рядки мусили дати goal_complete з waiting_human=3: $out"
jq -e '.next.hint | contains("чекають людину")' <<<"$out" >/dev/null || fail "підказка не каже, що рядки чекають людину: $out"

# 3б. Список від ІНШОЇ цілі не рахується.
printf '{"query":"patch=8&missing=machine","identities":["%s"]}' "$H1" > "$STATE/run-excluded.json"
out="$(BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 BDO_GOAL_REMAINING_STUB=3 BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null | tail -1)"
jq -e '.next.kind == "continue_run" and .next.remaining == 3' <<<"$out" >/dev/null \
    || fail "виключення чужої цілі не мало вплинути на залишок: $out"

echo 'row attempts: OK · рядок має стелю спроб, а ціль прогону її враховує.'
