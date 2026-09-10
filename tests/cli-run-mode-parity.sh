#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_PHP="$(command -v php)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ПРАВИЛО: run-mode tests use only an isolated repository and a localhost DEV API.
# САБОТАЖ: production state/output or a non-local URL must stop the test.
HARNESS="$TMP/repo"
mkdir -p "$HARNESS"
for directory in cli lib config roles; do
    cp -R "$ROOT/$directory" "$HARNESS/$directory"
done

mkdir -p "$HARNESS/state" "$HARNESS/output"

REQUEST_LOG="$TMP/requests.log"
ZERO_FILE="$TMP/zero-rows"
FETCH_FAILURE_FILE="$TMP/fetch-failure"
ROUTER="$TMP/router.php"
cat >"$ROUTER" <<'ROUTER'
<?php
$log = getenv('RUN_MODE_REQUEST_LOG');
$method = $_SERVER['REQUEST_METHOD'] ?? '';
$uri = $_SERVER['REQUEST_URI'] ?? '';
file_put_contents($log, json_encode(['method' => $method, 'uri' => $uri], JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND | LOCK_EX);
if ($method !== 'GET') {
    http_response_code(405);
    echo json_encode(['error' => 'GET only']);
    return;
}
if (str_contains($uri, '/taxonomy')) {
    echo json_encode(['data' => ['field_groups' => ['classification', 'tokens', 'constraints', 'glossary', 'reference', 'patch', 'layers']]]);
    return;
}
if (str_contains($uri, '/rows')) {
    if (is_file(getenv('RUN_MODE_FETCH_FAILURE_FILE'))) {
        http_response_code(400);
        echo json_encode(['error' => 'stub failure']);
        return;
    }
    if (is_file(getenv('RUN_MODE_ZERO_FILE'))) {
        echo json_encode(['data' => ['rows' => []], 'meta' => ['total_matching' => 0, 'has_more' => false, 'next_cursor' => null]]);
        return;
    }
    echo json_encode(['data' => ['rows' => [[
        'identity_hash' => str_repeat('a', 64),
        'source_text' => 'Тестовий рядок run-mode',
        'classification' => ['domain' => 'item', 'semantic_type' => 'name'],
        'tokens' => [], 'constraints' => [], 'glossary' => ['terms' => []],
        'reference' => null, 'patch' => 'active',
    ]]], 'meta' => ['total_matching' => 1, 'has_more' => false, 'next_cursor' => null]]);
    return;
}
http_response_code(404);
echo json_encode(['error' => 'not found']);
ROUTER
RUN_MODE_REQUEST_LOG="$REQUEST_LOG" RUN_MODE_ZERO_FILE="$ZERO_FILE" RUN_MODE_FETCH_FAILURE_FILE="$FETCH_FAILURE_FILE" \
    "$REAL_PHP" -S 127.0.0.1:0 -t "$TMP" "$ROUTER" >"$TMP/server.out" 2>"$TMP/server.err" &
SERVER_PID=$!
for _ in $(seq 1 50); do
    if grep -Fq 'Development Server' "$TMP/server.err"; then break; fi
    sleep 0.02
done
PORT="$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$TMP/server.err" | head -1)"
test -n "$PORT" || fail 'local stub did not start'
trap 'kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
BASE="http://127.0.0.1:$PORT"
case "$BASE" in http://127.0.0.1:*) ;; *) fail 'stub URL is not localhost HTTP' ;; esac

ENV_FILE="$TMP/dev.env"
cat >"$ENV_FILE" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=$BASE
BDO_API_KEY_DEV=test-key
EOF

real_ms() {
    "$REAL_PHP" -r 'echo (int) floor(microtime(true) * 1000);'
}

assert_timestamp() {
    local label="$1" state="$2" before="$3" after="$4" raw value
    [ -f "$state/run-started-at" ] || return 0
    raw="$(<"$state/run-started-at")"
    [[ "$raw" =~ ^[0-9]+$ ]] || fail "$label: run-started-at is not decimal milliseconds"
    value=$((10#$raw))
    (( value >= before - 1500 && value <= after + 1500 )) || fail "$label: run-started-at outside launch window"
}

run_side() {
    local side="$1" state="$2" out="$3" err="$4" code="$5"
    shift 5
    local before after
    before="$(real_ms)"
    set +e
    if [ "$side" = sh ]; then
        BDO_ORCHESTRATOR=sh TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            BDO_RUN_MAX_BATCHES="${RUN_MAX_BATCHES:-25}" bash "$HARNESS/cli/run/run-mode.sh" "$@" >"$out" 2>"$err"
    else
        BDO_ORCHESTRATOR=php TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            BDO_RUN_MAX_BATCHES="${RUN_MAX_BATCHES:-25}" RUN_MODE_REQUEST_LOG="$REQUEST_LOG" \
            "$REAL_PHP" "$HARNESS/cli/bdo.php" run-mode "$@" >"$out" 2>"$err"
    fi
    local status=$?
    set -e
    after="$(real_ms)"
    if [ "$status" -eq 0 ]; then
        assert_timestamp "$side $state" "$state" "$before" "$after"
    fi
    printf '%s\n' "$status" >"$code"
}

run_logged_side() {
    local request_copy="$1"
    shift
    find "$HARNESS/output" -maxdepth 1 -type f -name 'rows_*.json' -delete
    : >"$REQUEST_LOG"
    run_side "$@"
    cp "$REQUEST_LOG" "$request_copy"
}

normalize_text() {
    sed -e "s|$TMP/[^/ ]*-sh|STATE|g" -e "s|$TMP/[^/ ]*-php|STATE|g" \
        -e 's|STATE/batches/[0-9_]*_[0-9a-f]*|STATE/batches/BATCH|g'
}

# ПРАВИЛО: normalization may hide only generated batch paths, never contract fields.
# САБОТАЖ: changing mode, channel, query, domain, count, reason, or identity must stay visible.
normalizer_self_test() {
    local left right
    left="$(normalize_text <<'EOF'
mode=patch channel=machine query=patch=active domain=item count=1 reason=fetch_failed identity=aaaaaaaa
EOF
)"
    right="$(normalize_text <<'EOF'
mode=manual channel=manual query=patch=1 domain=quest count=2 reason=budget_exhausted identity=bbbbbbbb
EOF
)"
    [ "$left" != "$right" ] || fail 'normalizer masked stable contract fields'
}

normalizer_self_test

normalize_batch_file() {
    sed -e 's/[0-9][0-9]*_[0-9][0-9]*_[0-9a-f][0-9a-f]*/BATCH/g'
}

manifest_projection() {
    "$REAL_PHP" -r '$m=json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR); echo json_encode(array_intersect_key($m, array_flip(["state","rows","identity_key","mode","channel","query","memory_layers","patch","domain"])), JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);' "$1"
}

assert_json_fragment() {
    local file="$1" fragment="$2" label="$3"
    grep -Fq "$fragment" "$file" || fail "$label: missing JSON fragment $fragment"
}

assert_request_pair() {
    local label="$1" query="$2"
    cmp -s "$TMP/$label.sh.requests" "$TMP/$label.php.requests" || {
        diff -u "$TMP/$label.sh.requests" "$TMP/$label.php.requests" >&2 || true
        fail "$label: HTTP request logs differ"
    }
    grep -Fq '"method":"GET"' "$TMP/$label.sh.requests" || fail "$label: request was not GET"
    grep -Fq "$query" "$TMP/$label.sh.requests" || fail "$label: request query missing $query"
}

compare_pair() {
    local label="$1" state_sh="$2" state_php="$3"
    normalize_text <"$TMP/$label.sh.out" >"$TMP/$label.sh.norm"
    normalize_text <"$TMP/$label.php.out" >"$TMP/$label.php.norm"
    normalize_text <"$TMP/$label.sh.err" >"$TMP/$label.sh.err.norm"
    normalize_text <"$TMP/$label.php.err" >"$TMP/$label.php.err.norm"
    cmp -s "$TMP/$label.sh.norm" "$TMP/$label.php.norm" || { diff -u "$TMP/$label.sh.norm" "$TMP/$label.php.norm" >&2 || true; printf 'shell stderr:\n' >&2; cat "$TMP/$label.sh.err" >&2; printf 'php stderr:\n' >&2; cat "$TMP/$label.php.err" >&2; fail "$label: stdout differs"; }
    cmp -s "$TMP/$label.sh.err.norm" "$TMP/$label.php.err.norm" || { diff -u "$TMP/$label.sh.err.norm" "$TMP/$label.php.err.norm" >&2 || true; fail "$label: stderr differs"; }
    cmp -s "$TMP/$label.sh.code" "$TMP/$label.php.code" || fail "$label: exit code differs"
    for relative in run-target run-batches.json run-goal.json current-batch; do
        if [ -e "$state_sh/$relative" ] || [ -e "$state_php/$relative" ]; then
            test -e "$state_sh/$relative" && test -e "$state_php/$relative" || fail "$label: missing state $relative"
            if [ -d "$state_sh/$relative" ] || [ -d "$state_php/$relative" ]; then
                test -d "$state_sh/$relative" && test -d "$state_php/$relative" || fail "$label: state type differs: $relative"
                continue
            fi
            if [ "$relative" = run-started-at ]; then continue; fi
            if [ "$relative" = current-batch ]; then
                normalize_batch_file <"$state_sh/$relative" >"$TMP/$label.sh.$relative"
                normalize_batch_file <"$state_php/$relative" >"$TMP/$label.php.$relative"
                cmp -s "$TMP/$label.sh.$relative" "$TMP/$label.php.$relative" || fail "$label: state differs: $relative"
            else
                cmp -s "$state_sh/$relative" "$state_php/$relative" || fail "$label: state differs: $relative"
            fi
        fi
    done
    for state in "$state_sh" "$state_php"; do
        if [ -f "$state/run-started-at" ]; then
            raw="$(<"$state/run-started-at")"
            [[ "$raw" =~ ^[0-9]+$ ]] || fail "$label: invalid run-started-at"
            test "${#raw}" -ge 12 || fail "$label: run-started-at is not milliseconds"
        fi
    done
}

copy_fixture() {
    local state="$1"
    mkdir -p "$state"
    : >"$state/run-target"
}

# ПРАВИЛО: default wrappers route to the exact internal Kernel command.
# САБОТАЖ: missing dispatcher or wrong route must fail before behavior checks.
ROUTE_BIN="$TMP/route-bin"
mkdir -p "$ROUTE_BIN"
cat >"$ROUTE_BIN/php" <<'ROUTE'
#!/bin/sh
if [ "${1:-}" != "$ROUTE_ROOT/cli/bdo.php" ] || [ "${2:-}" != run-mode ]; then
    printf 'unexpected route: %s %s\n' "${1:-}" "${2:-}" >&2
    exit 99
fi
printf 'ROUTED:run-mode\n'
ROUTE
chmod +x "$ROUTE_BIN/php"
ROUTE_ROOT="$HARNESS" PATH="$ROUTE_BIN:$PATH" BDO_ORCHESTRATOR=php \
    bash "$HARNESS/cli/run/run-mode.sh" patch 50 active >"$TMP/route.out" 2>"$TMP/route.err" \
    || fail 'run-mode routing proof'
grep -Fxq 'ROUTED:run-mode' "$TMP/route.out" || fail 'run-mode marker missing'

# ПРАВИЛО: fresh modes preserve rows, target, goal, budget and selected manifest.
# САБОТАЖ: stale output rows or a changed step order must fail structural parity.
for mode in patch manual proposal improve; do
    sh_state="$TMP/fresh-$mode-sh"; php_state="$TMP/fresh-$mode-php"
    copy_fixture "$sh_state"; copy_fixture "$php_state"
    find "$HARNESS/output" -maxdepth 1 -name 'rows_*.json' -delete
    printf '%s\n' '{"data":{"rows":[{"identity_hash":"stale-sentinel"}]}}' >"$HARNESS/output/rows_99999999_999999.json"
    : >"$REQUEST_LOG"
    run_side sh "$sh_state" "$TMP/fresh-$mode.sh.out" "$TMP/fresh-$mode.sh.err" "$TMP/fresh-$mode.sh.code" "$mode" 50 ''
    run_side php "$php_state" "$TMP/fresh-$mode.php.out" "$TMP/fresh-$mode.php.err" "$TMP/fresh-$mode.php.code" "$mode" 50 ''
    compare_pair "fresh-$mode" "$sh_state" "$php_state"
    test -f "$sh_state/current-batch" || fail "fresh-$mode: batch not created"
    test -f "$php_state/current-batch" || fail "fresh-$mode: PHP batch not created"
    sh_batch="$(<"$sh_state/current-batch")"; php_batch="$(<"$php_state/current-batch")"
    test -f "$sh_state/batches/$sh_batch/rows.json" || fail "fresh-$mode: shell rows missing"
    test -f "$php_state/batches/$php_batch/rows.json" || fail "fresh-$mode: PHP rows missing"
    cmp -s "$sh_state/batches/$sh_batch/rows.json" "$php_state/batches/$php_batch/rows.json" || fail "fresh-$mode: rows composition differs"
    manifest_projection "$sh_state/batches/$sh_batch/manifest.json" >"$TMP/fresh-$mode.manifest.sh"
    manifest_projection "$php_state/batches/$php_batch/manifest.json" >"$TMP/fresh-$mode.manifest.php"
    cmp -s "$TMP/fresh-$mode.manifest.sh" "$TMP/fresh-$mode.manifest.php" || fail "fresh-$mode: manifest projection differs"
    grep -Fq "$(printf 'a%.0s' {1..64})" "$sh_state/batches/$sh_batch/rows.json" || fail "fresh-$mode: stale rows selected"
    grep -Fq "$(printf 'a%.0s' {1..64})" "$php_state/batches/$php_batch/rows.json" || fail "fresh-$mode: PHP stale rows selected"
done

# ПРАВИЛО: positional patch/domain arguments must reach the actual run-mode
# orchestration and produce the same HTTP query, goal, manifest and rows.
# САБОТАЖ: dropping either argument or changing query construction must make
# this shell/PHP differential fail on stable state or request evidence.
for case_name in numeric improve; do
    sh_state="$TMP/$case_name-args-sh"; php_state="$TMP/$case_name-args-php"
    copy_fixture "$sh_state"; copy_fixture "$php_state"
    if [ "$case_name" = numeric ]; then
        mode='patch'
        size='20'
        patch='3'
        domain='premium_shop'
    else
        mode='improve'
        size='20'
        patch='2'
        domain='quest'
    fi
    run_logged_side "$TMP/$case_name.sh.requests" sh "$sh_state" "$TMP/$case_name.sh.out" "$TMP/$case_name.sh.err" "$TMP/$case_name.sh.code" "$mode" "$size" "$patch" "$domain"
    run_logged_side "$TMP/$case_name.php.requests" php "$php_state" "$TMP/$case_name.php.out" "$TMP/$case_name.php.err" "$TMP/$case_name.php.code" "$mode" "$size" "$patch" "$domain"
    compare_pair "$case_name" "$sh_state" "$php_state"
    test "$(<"$TMP/$case_name.sh.code")" = 0 || fail "$case_name: shell failed"
    test "$(<"$TMP/$case_name.php.code")" = 0 || fail "$case_name: PHP failed"
    assert_request_pair "$case_name" "patch=$patch"
    assert_request_pair "$case_name" "domain=$domain"
    sh_batch="$(<"$sh_state/current-batch")"; php_batch="$(<"$php_state/current-batch")"
    cmp -s "$sh_state/batches/$sh_batch/rows.json" "$php_state/batches/$php_batch/rows.json" || fail "$case_name: rows composition differs"
    assert_json_fragment "$TMP/$case_name.sh.out" '"mode":"'$mode'"' "$case_name shell output"
    assert_json_fragment "$TMP/$case_name.sh.out" '"patch":"'$patch'"' "$case_name shell output"
    assert_json_fragment "$TMP/$case_name.sh.out" '"domain":"'$domain'"' "$case_name shell output"
    assert_json_fragment "$sh_state/run-goal.json" '"patch":"'$patch'"' "$case_name goal"
    assert_json_fragment "$sh_state/run-goal.json" '"domain":"'$domain'"' "$case_name goal"
    assert_json_fragment "$sh_state/run-goal.json" '"channel":"machine"' "$case_name goal"
    assert_json_fragment "$sh_state/run-goal.json" "patch=$patch" "$case_name goal query"
    assert_json_fragment "$sh_state/run-goal.json" "domain=$domain" "$case_name goal query"
    manifest_projection "$sh_state/batches/$sh_batch/manifest.json" >"$TMP/$case_name.args.manifest.sh"
    manifest_projection "$php_state/batches/$php_batch/manifest.json" >"$TMP/$case_name.args.manifest.php"
    cmp -s "$TMP/$case_name.args.manifest.sh" "$TMP/$case_name.args.manifest.php" || fail "$case_name: manifest projection differs"
    assert_json_fragment "$TMP/$case_name.args.manifest.sh" '"patch":"'$patch'"' "$case_name manifest"
    assert_json_fragment "$TMP/$case_name.args.manifest.sh" '"domain":"'$domain'"' "$case_name manifest"
    assert_json_fragment "$TMP/$case_name.args.manifest.sh" '"channel":"machine"' "$case_name manifest"
    if [ "$case_name" = improve ]; then
        assert_json_fragment "$sh_state/run-goal.json" 'machine_provenance=legacy' "$case_name improve goal query"
        assert_json_fragment "$sh_state/run-goal.json" 'exclude_proposed=1' "$case_name improve goal query"
        assert_json_fragment "$TMP/$case_name.args.manifest.sh" '"memory_layers":"manual"' "$case_name improve manifest"
        assert_json_fragment "$TMP/$case_name.args.manifest.sh" 'machine_provenance=legacy' "$case_name improve manifest query"
        assert_json_fragment "$TMP/$case_name.args.manifest.sh" 'exclude_proposed=1' "$case_name improve manifest query"
    fi
done

# ПРАВИЛО: an incomplete current batch resumes before any fetch or new batch.
# САБОТАЖ: removing the resume return must expose a GET or a second batch.
for side in sh php; do
    resume_state="$TMP/resume-$side"
    mkdir -p "$resume_state/batches/existing"
    printf 'local\n' >"$resume_state/run-target"
    printf '1700000000000\n' >"$resume_state/run-started-at"
    printf 'existing\n' >"$resume_state/current-batch"
    printf '%s\n' '{"state":"awaiting_worker","mode":"manual","channel":"manual","query":"patch=7&missing=manual&exclude_proposed=1&domain=quest","memory_layers":"all","patch":"7","domain":"quest","rows":1}' >"$resume_state/batches/existing/manifest.json"
    cp "$resume_state/batches/existing/manifest.json" "$TMP/resume-$side.manifest.before"
done
run_logged_side "$TMP/resume.sh.requests" sh "$TMP/resume-sh" "$TMP/resume.sh.out" "$TMP/resume.sh.err" "$TMP/resume.sh.code" improve 20 2 premium_shop
run_logged_side "$TMP/resume.php.requests" php "$TMP/resume-php" "$TMP/resume.php.out" "$TMP/resume.php.err" "$TMP/resume.php.code" improve 20 2 premium_shop
compare_pair resume "$TMP/resume-sh" "$TMP/resume-php"
test ! -s "$TMP/resume.sh.requests" || fail 'shell resume performed an HTTP fetch'
test ! -s "$TMP/resume.php.requests" || fail 'PHP resume performed an HTTP fetch'
test "$(<"$TMP/resume-sh/current-batch")" = existing || fail 'shell resume changed current batch'
test "$(<"$TMP/resume-php/current-batch")" = existing || fail 'PHP resume changed current batch'
test "$(find "$TMP/resume-php/batches" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 || fail 'resume created a second batch'
for side in sh php; do
    cmp -s "$TMP/resume-$side.manifest.before" "$TMP/resume-$side/batches/existing/manifest.json" || fail "resume-$side overwrote existing spec"
    assert_json_fragment "$TMP/resume.$side.out" '"mode":"manual"' "resume-$side response"
    assert_json_fragment "$TMP/resume.$side.out" '"patch":"7"' "resume-$side response"
done

# ПРАВИЛО: an incomplete batch on a foreign target blocks before HTTP and keeps
# every lock/workspace byte unchanged.
# САБОТАЖ: bypassing RunStartCommand's nonzero result must expose a request or
# a mutated target/batch state.
for side in sh php; do
    target_state="$TMP/target-mismatch-$side"
    mkdir -p "$target_state/batches/foreign"
    printf 'hub-local\n' >"$target_state/run-target"
    real_ms >"$target_state/run-started-at"
    printf 'foreign\n' >"$target_state/current-batch"
    printf '%s\n' '{"state":"awaiting_worker","mode":"patch","channel":"machine","query":"patch=active&missing=machine","memory_layers":"all","patch":"active","domain":"","rows":1}' >"$target_state/batches/foreign/manifest.json"
    cp -R "$target_state" "$TMP/target-mismatch-$side.before"
done
run_logged_side "$TMP/target-mismatch.sh.requests" sh "$TMP/target-mismatch-sh" "$TMP/target-mismatch.sh.out" "$TMP/target-mismatch.sh.err" "$TMP/target-mismatch.sh.code" patch 20
run_logged_side "$TMP/target-mismatch.php.requests" php "$TMP/target-mismatch-php" "$TMP/target-mismatch.php.out" "$TMP/target-mismatch.php.err" "$TMP/target-mismatch.php.code" patch 20
compare_pair target-mismatch "$TMP/target-mismatch-sh" "$TMP/target-mismatch-php"
test "$(<"$TMP/target-mismatch.sh.code")" != 0 || fail 'target mismatch shell succeeded'
test "$(<"$TMP/target-mismatch.php.code")" != 0 || fail 'target mismatch PHP succeeded'
grep -Fq 'ЗАБЛОКОВАНО' "$TMP/target-mismatch.sh.err" || fail 'target mismatch blocker missing in shell output'
grep -Fq 'ЗАБЛОКОВАНО' "$TMP/target-mismatch.php.err" || fail 'target mismatch blocker missing in PHP output'
test ! -s "$TMP/target-mismatch.sh.requests" || fail 'target mismatch shell performed HTTP'
test ! -s "$TMP/target-mismatch.php.requests" || fail 'target mismatch PHP performed HTTP'
for side in sh php; do
    diff -rq "$TMP/target-mismatch-$side.before" "$TMP/target-mismatch-$side" >/dev/null || fail "target mismatch mutated $side state"
    test ! -e "$TMP/target-mismatch-$side/run-batches.json" || fail "target mismatch wrote $side budget"
    test ! -e "$TMP/target-mismatch-$side/run-goal.json" || fail "target mismatch wrote $side goal"
done

# ПРАВИЛО: invalid fetch size fails before HTTP, budget, goal, or batch creation.
# САБОТАЖ: replacing the actual size with a valid default must make this proof
# observe a request or lose the named fetch_failed reason.
for side in sh php; do
    mkdir -p "$TMP/size15-$side"
done
run_logged_side "$TMP/size15.sh.requests" sh "$TMP/size15-sh" "$TMP/size15.sh.out" "$TMP/size15.sh.err" "$TMP/size15.sh.code" patch 15
run_logged_side "$TMP/size15.php.requests" php "$TMP/size15-php" "$TMP/size15.php.out" "$TMP/size15.php.err" "$TMP/size15.php.code" patch 15
compare_pair size15 "$TMP/size15-sh" "$TMP/size15-php"
for side in sh php; do
    test "$(<"$TMP/size15.$side.code")" = 1 || fail "size15 $side code changed"
    assert_json_fragment "$TMP/size15.$side.out" '"state":"waiting_dependency"' "size15 $side state"
    assert_json_fragment "$TMP/size15.$side.out" '"reason":"fetch_failed"' "size15 $side reason"
    assert_json_fragment "$TMP/size15.$side.out" '"size":"15"' "size15 $side size"
    grep -Fq 'від 20 до 100' "$TMP/size15.$side.out" || fail "size15 $side reason detail missing"
    test ! -s "$TMP/size15.$side.requests" || fail "size15 $side performed HTTP"
    test ! -e "$TMP/size15-$side/run-batches.json" || fail "size15 $side wrote budget"
    test ! -e "$TMP/size15-$side/run-goal.json" || fail "size15 $side wrote goal"
    test ! -e "$TMP/size15-$side/current-batch" || fail "size15 $side created batch"
done

# ПРАВИЛО: zero rows completes without budget, goal, or batch creation; fetch failures
# become waiting_dependency. САБОТАЖ: skipping the structured result or hiding HTTP
# failure must make these assertions red.
touch "$ZERO_FILE"
run_side sh "$TMP/zero-sh" "$TMP/zero.sh.out" "$TMP/zero.sh.err" "$TMP/zero.sh.code" patch 50
run_side php "$TMP/zero-php" "$TMP/zero.php.out" "$TMP/zero.php.err" "$TMP/zero.php.code" patch 50
rm -f "$ZERO_FILE"
compare_pair zero "$TMP/zero-sh" "$TMP/zero-php"
grep -Fq '"state":"complete"' "$TMP/zero.sh.out" || fail 'zero rows was not complete'
test ! -e "$TMP/zero-php/current-batch" || fail 'zero rows created a batch'

touch "$FETCH_FAILURE_FILE"
run_side sh "$TMP/fetch-failure-sh" "$TMP/fetch-failure.sh.out" "$TMP/fetch-failure.sh.err" "$TMP/fetch-failure.sh.code" patch 50
run_side php "$TMP/fetch-failure-php" "$TMP/fetch-failure.php.out" "$TMP/fetch-failure.php.err" "$TMP/fetch-failure.php.code" patch 50
rm -f "$FETCH_FAILURE_FILE"
compare_pair fetch-failure "$TMP/fetch-failure-sh" "$TMP/fetch-failure-php"
test "$(<"$TMP/fetch-failure.sh.code")" = 1 || fail 'fetch failure code changed'
grep -Fq 'fetch_failed' "$TMP/fetch-failure.php.out" || fail 'fetch failure reason missing'

# ПРАВИЛО: budget is checked after GET and before durable goal/batch creation.
# САБОТАЖ: changing >= to > must let an exhausted run create work.
for side in sh php; do
    budget_state="$TMP/budget-$side"
    mkdir -p "$budget_state"
    printf '%s\n' '{"scope":"local:patch:active:","batches":1}' >"$budget_state/run-batches.json"
    printf 'local\n' >"$budget_state/run-target"
done
RUN_MAX_BATCHES=1
run_logged_side "$TMP/budget.sh.requests" sh "$TMP/budget-sh" "$TMP/budget.sh.out" "$TMP/budget.sh.err" "$TMP/budget.sh.code" patch 50
run_logged_side "$TMP/budget.php.requests" php "$TMP/budget-php" "$TMP/budget.php.out" "$TMP/budget.php.err" "$TMP/budget.php.code" patch 50
RUN_MAX_BATCHES=''
cmp -s "$TMP/budget.sh.requests" "$TMP/budget.php.requests" || fail 'budget HTTP request logs differ'
grep -Fq '"method":"GET"' "$TMP/budget.sh.requests" || fail 'budget did not fetch before exhaustion'
grep -Fq '/rows?' "$TMP/budget.sh.requests" || fail 'budget request log has no rows GET'
test "$(<"$TMP/budget.sh.code")" = 1 || fail 'budget shell did not stop'
test "$(<"$TMP/budget.php.code")" = 1 || fail 'budget PHP did not stop'
grep -Fq 'budget_exhausted' "$TMP/budget.php.out" || fail 'budget reason missing'
test ! -e "$TMP/budget-php/run-goal.json" || fail 'budget wrote goal'
test ! -e "$TMP/budget-php/current-batch" || fail 'budget created batch'

# ПРАВИЛО: existing invalid budget/goal state is fail-closed and names its path.
# САБОТАЖ: treating corrupt state as empty or ignoring a failed goal write is unsafe.
for side in sh php; do
    mkdir -p "$TMP/corrupt-$side"
    printf 'local\n' >"$TMP/corrupt-$side/run-target"
    printf '{broken\n' >"$TMP/corrupt-$side/run-batches.json"
done
run_side sh "$TMP/corrupt-sh" "$TMP/corrupt.sh.out" "$TMP/corrupt.sh.err" "$TMP/corrupt.sh.code" patch 50 ''
run_side php "$TMP/corrupt-php" "$TMP/corrupt.php.out" "$TMP/corrupt.php.err" "$TMP/corrupt.php.code" patch 50 ''
compare_pair corrupt "$TMP/corrupt-sh" "$TMP/corrupt-php"
grep -Fq 'run-batches.json' "$TMP/corrupt.php.err" || fail 'corrupt budget path missing'
test ! -e "$TMP/corrupt-php/current-batch" || fail 'corrupt budget created batch'

for side in sh php; do
    mkdir -p "$TMP/budget-directory-$side/run-batches.json"
    printf 'local\n' >"$TMP/budget-directory-$side/run-target"
done
run_side sh "$TMP/budget-directory-sh" "$TMP/budget-directory.sh.out" "$TMP/budget-directory.sh.err" "$TMP/budget-directory.sh.code" patch 50
run_side php "$TMP/budget-directory-php" "$TMP/budget-directory.php.out" "$TMP/budget-directory.php.err" "$TMP/budget-directory.php.code" patch 50
compare_pair budget-directory "$TMP/budget-directory-sh" "$TMP/budget-directory-php"
grep -Fq 'run-batches.json' "$TMP/budget-directory.php.err" || fail 'directory budget path missing'
test ! -e "$TMP/budget-directory-php/current-batch" || fail 'directory budget created batch'

# ПРАВИЛО: a readable valid but unwritable regular budget file must reach the
# write-result guard after fetch, without being confused with read/decode failure.
# САБОТАЖ: ignoring file_put_contents() failure must make this PHP/shell proof
# diverge through continuation or state creation.
for side in sh php; do
    budget_write_state="$TMP/budget-write-failure-$side"
    mkdir -p "$budget_write_state"
    printf '%s\n' '{"scope":"local:patch:active:","batches":0}' >"$budget_write_state/run-batches.json"
    printf 'local\n' >"$budget_write_state/run-target"
    chmod 0444 "$budget_write_state/run-batches.json"
    test -r "$budget_write_state/run-batches.json" || fail "budget-write-failure $side fixture is not readable"
    "$REAL_PHP" -r '$d=json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR); if (($d["scope"] ?? null) !== "local:patch:active:" || ($d["batches"] ?? null) !== 0) { exit(1); }' "$budget_write_state/run-batches.json" || fail "budget-write-failure $side fixture JSON invalid"
    test ! -w "$budget_write_state/run-batches.json" || fail "budget-write-failure $side fixture is writable; cannot prove write failure"
    cp "$budget_write_state/run-batches.json" "$TMP/budget-write-failure-$side.before"
done
run_logged_side "$TMP/budget-write-failure.sh.requests" sh "$TMP/budget-write-failure-sh" "$TMP/budget-write-failure.sh.out" "$TMP/budget-write-failure.sh.err" "$TMP/budget-write-failure.sh.code" patch 20
run_logged_side "$TMP/budget-write-failure.php.requests" php "$TMP/budget-write-failure-php" "$TMP/budget-write-failure.php.out" "$TMP/budget-write-failure.php.err" "$TMP/budget-write-failure.php.code" patch 20
compare_pair budget-write-failure "$TMP/budget-write-failure-sh" "$TMP/budget-write-failure-php"
for side in sh php; do
    test "$(<"$TMP/budget-write-failure.$side.code")" != 0 || fail "budget-write-failure $side succeeded"
    grep -Fq 'Не вдалося записати файл стану:' "$TMP/budget-write-failure.$side.err" || fail "budget-write-failure $side write reason missing"
    grep -Fq 'run-batches.json' "$TMP/budget-write-failure.$side.err" || fail "budget-write-failure $side path missing"
    if grep -Fq 'Не вдалося прочитати файл стану:' "$TMP/budget-write-failure.$side.err" || grep -Fq 'Пошкоджений файл стану:' "$TMP/budget-write-failure.$side.err"; then
        fail "budget-write-failure $side took read/corrupt branch"
    fi
    test -s "$TMP/budget-write-failure.$side.requests" || fail "budget-write-failure $side did not fetch"
    cmp -s "$TMP/budget-write-failure-$side.before" "$TMP/budget-write-failure-$side/run-batches.json" || fail "budget-write-failure $side changed budget file"
    test ! -e "$TMP/budget-write-failure-$side/run-goal.json" || fail "budget-write-failure $side wrote goal"
    test ! -e "$TMP/budget-write-failure-$side/current-batch" || fail "budget-write-failure $side created batch"
done

for side in sh php; do
    mkdir -p "$TMP/goal-failure-$side"
    printf 'local\n' >"$TMP/goal-failure-$side/run-target"
    mkdir -p "$TMP/goal-failure-$side/run-goal.json"
done
run_side sh "$TMP/goal-failure-sh" "$TMP/goal-failure.sh.out" "$TMP/goal-failure.sh.err" "$TMP/goal-failure.sh.code" patch 50 ''
run_side php "$TMP/goal-failure-php" "$TMP/goal-failure.php.out" "$TMP/goal-failure.php.err" "$TMP/goal-failure.php.code" patch 50 ''
compare_pair goal-failure "$TMP/goal-failure-sh" "$TMP/goal-failure-php"
test "$(<"$TMP/goal-failure.php.code")" != 0 || fail 'goal write failure became success'
grep -Fq 'run-goal.json' "$TMP/goal-failure.php.err" || fail 'goal failure path missing'
test ! -e "$TMP/goal-failure-php/current-batch" || fail 'goal failure created batch'

# ПРАВИЛО: direct Run PHP needs no Unix helpers on zero-row and resume paths.
# САБОТАЖ: a subprocess dependency must make this isolated PATH proof fail.
NO_UNIX="$TMP/no-unix"
mkdir -p "$NO_UNIX"
for command in bash date grep tail ls head sed awk tr; do
    printf '#!/bin/sh\nexit 99\n' >"$NO_UNIX/$command"
    chmod +x "$NO_UNIX/$command"
done
touch "$ZERO_FILE"
PATH="$NO_UNIX" TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$TMP/no-unix-zero" \
    "$REAL_PHP" "$HARNESS/cli/bdo.php" run-mode patch 50 >"$TMP/no-unix-zero.out" 2>"$TMP/no-unix-zero.err" \
    || fail 'direct PHP zero-row no-Unix proof'
rm -f "$ZERO_FILE"
mkdir -p "$TMP/no-unix-resume/batches/existing"
printf 'local\n' >"$TMP/no-unix-resume/run-target"
printf 'existing\n' >"$TMP/no-unix-resume/current-batch"
printf '%s\n' '{"state":"awaiting_worker","mode":"patch","rows":1}' >"$TMP/no-unix-resume/batches/existing/manifest.json"
PATH="$NO_UNIX" TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$TMP/no-unix-resume" \
    "$REAL_PHP" "$HARNESS/cli/bdo.php" run-mode patch 50 >"$TMP/no-unix-resume.out" 2>"$TMP/no-unix-resume.err" \
    || fail 'direct PHP resume no-Unix proof'

printf 'cli run-mode parity: routing, four modes, resume, fetch/budget/goal failures, structured rows and no-Unix proof: OK\n'
