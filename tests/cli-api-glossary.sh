#!/usr/bin/env bash
# Довести байтову ідентичність шести glossary/terms-команд і їхніх файлів.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PORT=$((27000 + RANDOM % 1000))
SERVER=''
HASH='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
cleanup() { [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$query = [];
parse_str((string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_QUERY), $query);
$log = (string) getenv('STUB_LOG');
file_put_contents($log, ($_SERVER['REQUEST_METHOD'] ?? 'GET').' '.$path."\n", FILE_APPEND);
header('Content-Type: application/json');

if ($path === '/glossary/terms/list') {
    if (($query['cursor'] ?? '') === '2') {
        echo json_encode(['data' => ['terms' => [['term_id' => 3, 'canonical_source' => 'Week', 'ukrainian' => 'Місяць']]], 'meta' => ['has_more' => false, 'next_cursor' => null]]);
    } else {
        echo json_encode(['data' => ['terms' => [['term_id' => 1, 'canonical_source' => 'Iron Sword', 'ukrainian' => 'Залізний меч'], ['term_id' => 2, 'canonical_source' => 'GO', 'ukrainian' => 'ВПЕ']]], 'meta' => ['has_more' => true, 'next_cursor' => '2']]);
    }
    return;
}
if ($path === '/glossary/concepts') {
    echo json_encode(['data' => ['concepts' => [
        ['term' => 'AP', 'ua' => 'AP', 'gist' => 'Сила атаки'],
        ['term' => 'Set Effect', 'ua' => 'Ефект комплекту', 'gist' => 'Бонус набору'],
    ]], 'meta' => ['complete' => true]]);
    return;
}
if ($path === '/glossary/terms') {
    $name = (string) ($query['q'] ?? '');
    $term = ['term_id' => 10, 'ukrainian' => 'Українська назва'];
    if ($name === 'NoDefinition') {
        echo json_encode(['data' => ['terms' => [$name => $term]]]);
    } elseif ($name === 'ExistingDefinition') {
        $term['definition'] = 'Готовий опис';
        echo json_encode(['data' => ['terms' => [$name => $term]]]);
    } else {
        $term['definition'] = '';
        echo json_encode(['data' => ['terms' => [$name => $term]]]);
    }
    return;
}
if ($path === '/glossary/terms/resolve') {
    echo json_encode(['success' => true, 'data' => ['resolution' => [
        'status' => 'ready',
        'candidate' => ['term_id' => 10, 'entity_type' => 'item', 'category' => 'item', 'external_id' => 'x', 'source_identity' => ['identity_hash' => '0123456789abcdef'],],
    ]]]);
    return;
}
if ($path === '/glossary/proposals') {
    $body = (string) file_get_contents('php://input');
    file_put_contents($log, 'PROPOSAL '.$body."\n", FILE_APPEND);
    echo json_encode(['success' => true, 'data' => ['proposal_id' => 99]]);
    return;
}
http_response_code(404);
echo json_encode(['success' => false, 'error' => ['code' => 'not_found', 'message' => $path]]);
PHP
cat > "$TMP/env" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test-key
EOF
: > "$TMP/requests.log"
STUB_LOG="$TMP/requests.log" php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break
    sleep .1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }

export TRANSLATE_ENV_FILE="$TMP/env"
export BDO_API_TARGET=legacy
run_command() {
    local mode="$1" state="$2" script="$3"; shift 3
    env BDO_ORCHESTRATOR="$mode" BDO_STATE_DIR="$state" bash "$ROOT/$script" "$@"
}
save_outputs() {
    local label="$1"
    cp "$TMP/run.out" "$TMP/$label.out"
    cp "$TMP/run.err" "$TMP/$label.err"
    printf '%s\n' "$2" > "$TMP/$label.code"
}
compare_outputs() {
    local label="$1"
    cmp -s "$TMP/$label.sh.out" "$TMP/$label.php.out" || fail "$label stdout"
    cmp -s "$TMP/$label.sh.err" "$TMP/$label.php.err" || fail "$label stderr"
    cmp -s "$TMP/$label.sh.code" "$TMP/$label.php.code" || fail "$label exit code"
}
compare_files() {
    local label="$1" state="$2" file
    while IFS= read -r file; do
        file="${file#./}"
        cmp -s "$TMP/$label.files/$file" "$state/$file" || return 1
    done < <(cd "$TMP/$label.files" && find . -type f -print | sort)
    diff -qr "$TMP/$label.files" "$state" >/dev/null
}
run_pair() {
    local label="$1" script="$2" setup="$3"; shift 3
    local state="$TMP/state-$label"
    for _ in 1 2 3 4 5; do
        rm -rf "$state" "$TMP/$label.files"
        for mode in sh php; do
            rm -rf "$state"
            mkdir -p "$state"
            "$setup" "$state"
            : > "$TMP/requests.log"
            set +e
            run_command "$mode" "$state" "$script" "$@" >"$TMP/run.out" 2>"$TMP/run.err"
            local code=$?
            set -e
            save_outputs "$label.$mode" "$code"
            cp "$TMP/requests.log" "$TMP/$label.$mode.requests"
            if [ "$mode" = sh ]; then
                cp -a "$state" "$TMP/$label.files"
            fi
        done
    compare_outputs "$label"
        cmp -s "$TMP/$label.sh.requests" "$TMP/$label.php.requests" || fail "$label HTTP requests"
        if compare_files "$label" "$state"; then
            return 0
        fi
    done
    fail "$label files"
}

setup_empty() { :; }
setup_list() { :; }
setup_concepts() { :; }
setup_resolve() { :; }
setup_queue() {
    local state="$1"
    printf '[{"canonical_source":"Offline Term","ukrainian":"Офлайн термін","has_definition":false}]\n' > "$TMP/$label-terms.json"
    printf '{"data":{"rows":[{"identity_hash":"%s","source_text":"Offline Term"}]} }\n' "$HASH" > "$TMP/$label-rows.json"
}
setup_describe() {
    local state="$1"
    cat > "$state/term-notes-queue.json" <<JSON
{"updated_at":"x","terms":[{"canonical_source":"Ancient Relic","ukrainian":"Стародавня реліквія","entity_type":"item","seen":4,"samples":["Ancient Relic glows."],"identity_hash":"$HASH","snapshot_id":7}]}
JSON
}
setup_submit() {
    local state="$1"
    cat > "$state/term-notes-queue.json" <<JSON
{"updated_at":"x","terms":[{"canonical_source":"EmptyDefinition","ukrainian":"Порожній опис","identity_hash":"$HASH","snapshot_id":7}]}
JSON
    printf '{"items":[{"canonical_source":"EmptyDefinition","gist":"Короткий gist","confidence":90}]}\n' > "$state/term-notes-response.json"
}

label=list run_pair list cli/api/glossary-list.sh setup_list --fresh
label=concepts run_pair concepts cli/api/glossary-concepts.sh setup_concepts
label=resolve run_pair resolve cli/api/glossary-resolve.sh setup_resolve 'Iron Sword' "$HASH"
label=queue run_pair queue cli/api/term-notes-queue.sh setup_queue "$TMP/queue-terms.json" "$TMP/queue-rows.json"
label=describe run_pair describe cli/api/term-notes-describe.sh setup_describe
label=submit run_pair submit cli/api/term-notes-submit.sh setup_submit

safety_case() {
    local name="$1" response="$2" expected="$3"
    local state="$TMP/safety-$name"
    rm -rf "$state"; mkdir -p "$state"
    cat > "$state/term-notes-queue.json" <<JSON
{"terms":[{"canonical_source":"$name","ukrainian":"Українська назва","identity_hash":"$HASH","snapshot_id":7}]}
JSON
    printf '%s\n' "$response" > "$state/term-notes-response.json"
    : > "$TMP/requests.log"
    set +e
    BDO_ORCHESTRATOR=php BDO_STATE_DIR="$state" bash "$ROOT/cli/api/term-notes-submit.sh" >"$TMP/safety-$name.out" 2>"$TMP/safety-$name.err"
    local code=$?
    set -e
    test "$code" -eq 0 || fail "безпековий випадок $name має код 0"
    local count
    count="$(grep -c '^PROPOSAL ' "$TMP/requests.log" || true)"
    test "$count" -eq "$expected" || fail "$name: очікувано proposal=$expected, отримано $count"
    grep -q 'Пропозицій надіслано:' "$TMP/safety-$name.out" || fail "$name: немає машиночитаного підсумку"
}

safety_case NoDefinition '{"items":[{"canonical_source":"NoDefinition","gist":"gist","confidence":90}]}' 0
safety_case ExistingDefinition '{"items":[{"canonical_source":"ExistingDefinition","gist":"gist","confidence":90}]}' 0
safety_case EmptyDefinition '{"items":[{"canonical_source":"EmptyDefinition","gist":"gist","confidence":90}]}' 1

echo 'cli api glossary: 6 команд, файли й безпека: OK'
