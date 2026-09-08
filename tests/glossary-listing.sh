#!/usr/bin/env bash
# Перевірити повний обхід, кеш, захист від циклу й неповний результат.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PORT=$((26000 + RANDOM % 1000))
SERVER=''
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

printf 'ok\n' > "$TMP/mode"
cat > "$TMP/router.php" <<'PHP'
<?php
$mode = trim((string) @file_get_contents((string) getenv('STUB_MODE_FILE')));
$request = (string) ($_SERVER['REQUEST_URI'] ?? '/');
$query = [];
parse_str((string) parse_url($request, PHP_URL_QUERY), $query);
header('Content-Type: application/json');
if ($mode === 'fail') {
    http_response_code(404);
    echo json_encode(['success' => false, 'error' => ['code' => 'not_found', 'message' => 'offline']]);
    return;
}
if ($mode === 'loop') {
    echo json_encode(['data' => ['terms' => [['term_id' => 1, 'canonical_source' => 'A B', 'ukrainian' => 'А Б']]], 'meta' => ['has_more' => true, 'next_cursor' => 'same']]);
    return;
}
if (($query['cursor'] ?? '') === '2') {
    echo json_encode(['data' => ['terms' => [['term_id' => 3, 'canonical_source' => 'Week', 'ukrainian' => 'Місяць']]], 'meta' => ['has_more' => false, 'next_cursor' => null]]);
    return;
}
echo json_encode(['data' => ['terms' => [
    ['term_id' => 1, 'canonical_source' => 'Iron Sword', 'ukrainian' => 'Залізний меч'],
    ['term_id' => 2, 'canonical_source' => 'GO', 'ukrainian' => 'ВПЕ'],
]], 'meta' => ['has_more' => true, 'next_cursor' => '2']]);
PHP
cat > "$TMP/env" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test-key
EOF
STUB_MODE_FILE="$TMP/mode" php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break
    sleep .1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }

export TRANSLATE_ENV_FILE="$TMP/env"
export BDO_STATE_DIR="$TMP/state"
mkdir -p "$BDO_STATE_DIR"
out="$(env BDO_ORCHESTRATOR=sh bash "$ROOT/cli/api/glossary-list.sh" --fresh 2>"$TMP/ok.err")" || { cat "$TMP/ok.err" >&2; fail 'повний обхід не завершився'; }
test "$(grep -c . <<<"$out")" -eq 3 || fail "обхід зібрав не всі сторінки: $out"
test "$(printf '%s\n' "$out" | jq -r '.canonical_source' | paste -sd, -)" = 'Iron Sword,GO,Week' || fail 'зіпсовано порядок сторінок'

printf 'fail\n' > "$TMP/mode"
cached="$(BDO_ORCHESTRATOR=php bash "$ROOT/cli/api/glossary-list.sh" 2>"$TMP/cache.err")" || fail 'кеш не використано при 404'
test "$(grep -c . <<<"$cached")" -eq 3 || fail 'кеш повного обходу не повернув усі рядки'
rm -f "$BDO_STATE_DIR/glossary-full.json"

printf 'loop\n' > "$TMP/mode"
set +e
BDO_ORCHESTRATOR=php bash "$ROOT/cli/api/glossary-list.sh" --fresh >"$TMP/loop.out" 2>"$TMP/loop.err"
code=$?
set -e
test "$code" -eq 4 || fail "зациклення має код 4, отримано $code"
grep -q 'зациклилась' "$TMP/loop.err" || fail 'причина зациклення не названа'

printf 'fail\n' > "$TMP/mode"
set +e
BDO_ORCHESTRATOR=php bash "$ROOT/cli/api/glossary-list.sh" --fresh >"$TMP/fail.out" 2>"$TMP/fail.err"
code=$?
set -e
test "$code" -eq 3 || fail "невдалий обхід має код 3, отримано $code"
test ! -s "$TMP/fail.out" || fail 'при помилці залишився stdout'
test ! -e "$BDO_STATE_DIR/glossary-full.json" || fail 'кеш зʼявився після невдалого обходу'
grep -q 'недоступний' "$TMP/fail.err" || fail 'причина недоступності не названа'

printf 'ok\n' > "$TMP/mode"
printf 'not a directory\n' > "$TMP/blocked-state"
set +e
BDO_STATE_DIR="$TMP/blocked-state" BDO_ORCHESTRATOR=php bash "$ROOT/cli/api/glossary-list.sh" --fresh \
    >"$TMP/blocked.out" 2>"$TMP/blocked.err"
code=$?
set -e
test "$code" -ne 0 || fail 'неможливу теку кеша прийнято за успішний обхід'
grep -q 'Кеш глосарію не пишеться' "$TMP/blocked.err" || fail 'причина неможливої теки не названа'

mkdir -p "$TMP/rename-state/glossary-full.json"
set +e
BDO_STATE_DIR="$TMP/rename-state" BDO_ORCHESTRATOR=php bash "$ROOT/cli/api/glossary-list.sh" --fresh \
    >"$TMP/rename.out" 2>"$TMP/rename.err"
code=$?
set -e
test "$code" -ne 0 || fail 'невдалий rename прийнято за успішний обхід'
grep -q 'Кеш глосарію не записано' "$TMP/rename.err" || fail 'причина невдалого rename не названа'

echo 'glossary listing: 6 сценаріїв OK'
