#!/usr/bin/env bash
# Доводить байтову ідентичність п'яти звітів до і після переносу в PHP.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-cli-api.XXXXXX")"
PORT=$((26000 + RANDOM % 1000))
SERVER=''
HASH='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

cleanup() {
    [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
    tmux kill-session -t "bdo-cli-api-pty-sh-$$" 2>/dev/null || true
    tmux kill-session -t "bdo-cli-api-pty-php-$$" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$query = [];
parse_str((string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_QUERY), $query);
header('Content-Type: application/json');

if ($path === '/me') {
    echo json_encode(['success' => true, 'data' => [
        'user' => ['email' => 'owner@example.test', 'role' => 'owner'],
        'limits' => ['requests_per_minute' => 60, 'rows_remaining_today' => 900, 'quota_resets_at' => '2030-01-01T00:00:00Z'],
    ]]);
    return;
}
if ($path === '/guide') {
    echo json_encode(['success' => true, 'data' => ['version' => 'test-1', 'hard_rules' => ['a', 'b'], 'never' => ['x']]]);
    return;
}
if ($path === '/taxonomy') {
    echo json_encode(['success' => true, 'data' => ['domains' => ['item', 'quest'], 'semantic_types' => ['name', 'description'], 'error_codes' => ['invalid']]]);
    return;
}
if (preg_match('#^/rows/[0-9a-f]{64}/context$#', $path) === 1) {
    echo json_encode(['success' => true, 'data' => ['context' => [
        'indexed' => true,
        'terms' => [['canonical_source' => 'Black Spirit', 'ukrainian' => 'Чорний дух']],
        'related_rows' => [[
            'source_text' => 'Meet the Black Spirit',
            'translation' => ['layer' => 'machine', 'freshness' => 'current', 'text' => 'Зустрінь Чорного духа'],
            'matching_terms' => [['canonical_source' => 'Black Spirit']],
        ]],
    ]]]);
    return;
}
if ($path === '/patch/summary') {
    if (($query['patch'] ?? '') === 'missing') {
        http_response_code(404);
        echo json_encode(['success' => false, 'error' => ['code' => 'not_found', 'message' => 'missing']]);
        return;
    }
    echo json_encode(['success' => true, 'meta' => ['snapshot_id' => 42], 'data' => ['summary' => [
        'total' => 100, 'translatable' => 80, 'untranslated' => 20,
        'states' => ['machine' => 70, 'manual' => 10],
        'domains' => [
            ['domain' => 'item', 'total' => 60, 'untranslated' => 15],
            ['domain' => 'quest', 'total' => 40, 'untranslated' => 5],
        ],
    ]]]);
    return;
}
if ($path === '/rows') {
    $counts = ['machine' => 20, 'manual' => 30, 'state' => 4, 'machine_provenance' => 7];
    $value = $counts[(string) ($query['missing'] ?? $query['state'] ?? $query['machine_provenance'] ?? '')] ?? 0;
    echo json_encode(['success' => true, 'meta' => ['total_matching' => $value]]);
    return;
}
if ($path === '/patches') {
    echo json_encode(['success' => true, 'data' => ['patches' => [[
        'snapshot_id' => '42', 'patch_number' => 7, 'published_at' => '2029-12-31T00:00:00Z',
        'is_active' => true, 'status' => 'active',
        'rows' => ['total' => 100, 'untranslated' => 20, 'states' => ['machine' => 70, 'manual' => 10]],
        'changes' => ['added' => 3, 'changed' => 2, 'removed' => 1],
    ]]]]);
    return;
}
http_response_code(404);
echo json_encode(['success' => false, 'error' => ['code' => 'not_found', 'message' => 'unknown']]);
PHP

cat > "$TMP/env" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test-key
EOF

php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$socket = @fsockopen("127.0.0.1", (int) $argv[1], $errno, $error, 0.2); if (is_resource($socket)) { fclose($socket); exit(0); } exit(1);' "$PORT" && break
    sleep 0.1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }

cat > "$TMP/rows.json" <<'JSON'
{"success":true,"data":{"rows":[{"identity_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","ordinal":3,"source_text":"Use the Black Spirit","classification":{"domain":"item","semantic_type":"name"},"reference":{"text":"Use it"},"layers":{"machine":{"text":"Використай Чорного духа"}},"glossary":{"terms":[{"canonical_source":"Black Spirit","ukrainian":"Чорний дух"}]},"tokens":{"must_preserve":{"%s":1}},"constraints":{"length":{"enforced":true,"min_chars":1,"max_chars":40,"source_chars":20}}}]}}
JSON

BASE_ENV=(TRANSLATE_ENV_FILE="$TMP/env" BDO_STATE_DIR="$TMP/state")
mkdir -p "$TMP/state"

run_capture() {
    local name="$1" orchestrator="$2"
    shift 2
    set +e
    env "${BASE_ENV[@]}" BDO_ORCHESTRATOR="$orchestrator" "$ROOT/bdo" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
    local code=$?
    set -e
    printf '%s\n' "$code" >"$TMP/$name.code"
}

compare_case() {
    local label="$1"; shift
    run_capture "${label}.sh" sh "$@"
    run_capture "${label}.php" php "$@"
    cmp -s "$TMP/${label}.sh.out" "$TMP/${label}.php.out" \
        || { echo "FAIL: $label stdout" >&2; exit 1; }
    cmp -s "$TMP/${label}.sh.err" "$TMP/${label}.php.err" \
        || { echo "FAIL: $label stderr" >&2; exit 1; }
    cmp -s "$TMP/${label}.sh.code" "$TMP/${label}.php.code" \
        || { echo "FAIL: $label exit code" >&2; exit 1; }
    if grep -Fq 'test-key' "$TMP/${label}.sh.err" "$TMP/${label}.php.err"; then
        echo "FAIL: $label API key leaked" >&2
        exit 1
    fi
}

compare_case api api
compare_case context context "$HASH"
compare_case show show "$TMP/rows.json" 1
compare_case patch patch active
compare_case patches patches 1 both --full
compare_case patch-error patch missing

cat > "$TMP/color-probe.php" <<'PHP'
<?php
require $argv[1];
$output = new Bdo\Translate\Cli\Output();
echo $output->color('__COLOR_PROBE__', '34')."\n";
PHP

pty_capture() {
    local name="$1" orchestrator="$2"
    local session="bdo-cli-api-${name}-$$"
    tmux new-session -d -s "$session" -x 200 -y 40 \
        "env ${BASE_ENV[*]} BDO_ORCHESTRATOR=$orchestrator '$ROOT/bdo' api; code=\$?; php '$TMP/color-probe.php' '$ROOT/lib/autoload.php'; printf '\\n__CODE__:%s\\n' \$code; sleep 1"
    for _ in $(seq 1 80); do
        if tmux capture-pane -e -t "$session" -p | grep -Fq '__CODE__:'; then
            tmux capture-pane -e -t "$session" -p >"$TMP/$name.pty"
            break
        fi
        sleep 0.1
    done
    test -s "$TMP/$name.pty" || { echo "FAIL: $name PTY не завершився" >&2; exit 1; }
    local escapes
    escapes="$(LC_ALL=C grep -ao $'\033' "$TMP/$name.pty" | wc -l | tr -d ' ')"
    printf '%s\n' "$escapes" >"$TMP/$name.ansi"
    test "$escapes" -ge 4 || {
        echo "FAIL: $name: у PTY-виводі немає кольору, тому порівняння нічого не доводить" >&2
        exit 1
    }
    grep -Fq $'\033[34m__COLOR_PROBE__' "$TMP/$name.pty" || {
        echo "FAIL: $name: у PTY-виводі немає кольору Output::color, тому порівняння нічого не доводить" >&2
        exit 1
    }
    printf 'PTY ANSI: %s=%s\n' "$name" "$escapes"
    tmux kill-session -t "$session" 2>/dev/null || true
}

pty_capture pty-sh sh
pty_capture pty-php php
cmp -s "$TMP/pty-sh.pty" "$TMP/pty-php.pty" || { echo 'FAIL: api PTY stdout' >&2; exit 1; }

echo 'cli api reports: 5 команд, rollback, помилка API, stderr/stdout і PTY: OK'
