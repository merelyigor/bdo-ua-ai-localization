#!/usr/bin/env bash
# Довести байтову ідентичність fetch-rows, capabilities і validate.
# Старі shell-тіла лишаються rollback-шляхом, тому тест порівнює їх із PHP на
# одному stub API, включно з файлами кешу та файлами результатів.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PORT=$((28000 + RANDOM % 1000))
SERVER=''
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"; rm -f "$ROOT"/output/rows_*.json "$ROOT"/output/validate_*.json; }
trap cleanup EXIT

cat > "$TMP/router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$query = [];
parse_str((string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_QUERY), $query);
$log = (string) getenv('STUB_LOG');
file_put_contents($log, ($_SERVER['REQUEST_METHOD'] ?? 'GET').' '.$path.'?'.http_build_query($query)."\n", FILE_APPEND);
header('Content-Type: application/json');
if ($path === '/taxonomy') {
    echo json_encode(['data' => ['field_groups' => ['classification', 'tokens', 'constraints', 'glossary', 'reference', 'patch']]]);
    return;
}
if ($path === '/rows') {
    echo json_encode(['data' => ['rows' => [
        ['identity_hash' => str_repeat('a', 64), 'source_text' => 'Iron Sword', 'classification' => ['domain' => 'item', 'semantic_type' => 'name'], 'glossary' => ['terms' => [['ukrainian' => 'Залізний меч']]]],
        ['identity_hash' => str_repeat('b', 64), 'source_text' => 'Set Effect', 'classification' => ['domain' => 'system', 'semantic_type' => 'name'], 'glossary' => ['terms' => []]],
    ]], 'meta' => ['total_matching' => 2, 'has_more' => false, 'next_cursor' => null]]);
    return;
}
if ($path === '/translations/validate') {
    echo json_encode(['success' => true, 'data' => ['results' => [
        ['index' => 0, 'status' => 'ok'],
        ['index' => 1, 'status' => 'repaired', 'repairs' => ['spacing'], 'repaired_text' => 'Виправлений текст'],
        ['index' => 2, 'status' => 'unchanged'],
        ['index' => 3, 'status' => 'rejected', 'message' => 'небезпечна розмітка', 'code' => 'markup'],
    ]]]);
    return;
}
if (in_array($path, ['/glossary/terms/list', '/translations/memory', '/patches', '/guide', '/translations/proposals'], true)) {
    http_response_code(404);
    echo json_encode(['success' => false]);
    return;
}
http_response_code(404);
echo json_encode(['success' => false]);
PHP
cat > "$TMP/env" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test-key
EOF
STUB_LOG="$TMP/requests.log" php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break
    sleep .1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }

export TRANSLATE_ENV_FILE="$TMP/env"
export BDO_API_TARGET=legacy
export STUB_LOG="$TMP/requests.log"
run() { env BDO_ORCHESTRATOR="$1" BDO_STATE_DIR="$2" bash "$ROOT/$3" "${@:4}"; }

pair() {
    local name="$1" script="$2" state="$TMP/state-$1"; shift 2
    local setup="$1"; shift
    for _ in 1 2 3 4 5; do
        rm -rf "$state" "$TMP/$name.sh.out" "$TMP/$name.php.out" "$TMP/$name.sh.err" "$TMP/$name.php.err" "$TMP/$name.sh.files"
        rm -f "$ROOT"/output/rows_*.json "$ROOT"/output/validate_*.json
        mkdir -p "$state"
        "$setup" "$state" "$@"
        : > "$TMP/requests.log"
        set +e
        run sh "$state" "$script" "$@" >"$TMP/$name.sh.out" 2>"$TMP/$name.sh.err"
        local sh_code=$?
        cp -a "$state" "$TMP/$name.sh.files"
        case "$name" in
            fetch) cp "$(ls -t "$ROOT"/output/rows_*.json | head -1)" "$TMP/$name.sh.rows" ;;
            validate) cp "$(ls -t "$ROOT"/output/validate_*.json | head -1)" "$TMP/$name.sh.validate" ;;
        esac
        run php "$state" "$script" "$@" >"$TMP/$name.php.out" 2>"$TMP/$name.php.err"
        local php_code=$?
        set -e
        printf '%s\n' "$sh_code" > "$TMP/$name.sh.code"
        printf '%s\n' "$php_code" > "$TMP/$name.php.code"
        cmp -s "$TMP/$name.sh.out" "$TMP/$name.php.out" || continue
        cmp -s "$TMP/$name.sh.err" "$TMP/$name.php.err" || continue
        cmp -s "$TMP/$name.sh.code" "$TMP/$name.php.code" || continue
        diff -qr "$TMP/$name.sh.files" "$state" >/dev/null || continue
        : # sabotage-only: isolate the path-contract assertion from pair comparison
        case "$name" in
            fetch) cmp -s "$TMP/$name.sh.rows" "$(ls -t "$ROOT"/output/rows_*.json | head -1)" || continue ;;
            validate) cmp -s "$TMP/$name.sh.validate" "$(ls -t "$ROOT"/output/validate_*.json | head -1)" || continue ;;
        esac
        return 0
    done
    diff -u "$TMP/$name.sh.out" "$TMP/$name.php.out" >&2 || true
    diff -u "$TMP/$name.sh.err" "$TMP/$name.php.err" >&2 || true
    fail "$name: stdout/stderr/exit code не збігаються"
}

setup_none() { :; }
setup_validate() {
    printf '%s\n' '[{"identity_hash":"aaaaaaaa","source_hash":"bbbbbbbb","text":"Готовий текст"}]' > "$TMP/items.json"
}
setup_fetch() {
    local state="$1"
    mkdir -p "$state"
    printf '%s\n' '{"target":"local","base":"stub","at":"2026-01-01T00:00:00Z","field_groups":"classification,tokens,constraints,glossary,reference,patch","items":{"glossary":"no","memory":"no","patches":"no","guide":"no","proposals":"no"}}' > "$state/api-capabilities.local.json"
}

pair capabilities cli/api/capabilities.sh setup_none
test -f "$TMP/state-capabilities/api-capabilities.local.json" || fail 'capabilities не створила cache'
test "$(jq -r '.target' "$TMP/state-capabilities/api-capabilities.local.json")" = local || fail 'cache capabilities має неправильну ціль'

pair validate cli/api/validate.sh setup_validate "$TMP/items.json"
test -s "$ROOT"/output/validate_*.json || fail 'validate не створила файл відповіді'

pair fetch cli/api/fetch-rows.sh setup_fetch 20
for path_output in sh php; do
    path="$(grep -oE '/[^ ]*/output/rows_[0-9_]+\.json' "$TMP/fetch.$path_output.out" | tail -1 || true)"
    test -n "$path" && test -f "$path" || fail "шлях rows у $path_output-виводі не відповідає контракту run-mode.sh:65"
done
rows="$(ls -t "$ROOT"/output/rows_*.json | head -1)"
test "$(jq '.data.rows | length' "$rows")" -eq 2 || fail 'fetch не зберіг рядки'

for size in 15 19 101; do
    set +e
    invalid_err="$(TRANSLATE_ENV_FILE="$TMP/env" BDO_STATE_DIR="$TMP/invalid-$size" bash "$ROOT/cli/api/fetch-rows.sh" "$size" 2>&1 >/dev/null)"
    invalid_code=$?
    set -e
    test "$invalid_code" -eq 2 || fail "розмір $size не відхилено кодом 2"
    printf '%s' "$invalid_err" | grep -Fq 'від 20 до 100' || fail "для розміру $size немає пояснення межі"
done

echo 'cli api fetch: 3 команди, stdout/stderr, коди й файли: OK'
