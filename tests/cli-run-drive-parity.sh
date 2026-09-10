#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_PHP="$(command -v php)"
TMP="$(mktemp -d)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
note() { printf 'run-drive parity: %s\n' "$1"; }

# ПРАВИЛО: усі drive scenarios працюють у власному repo/state/output і лише з
# synthetic DEV environment.
# САБОТАЖ: запуск wrapper із production root або неповідомий API path має валити test.
HARNESS="$TMP/repo"
mkdir -p "$HARNESS"
for directory in cli lib config roles; do cp -R "$ROOT/$directory" "$HARNESS/$directory"; done
mkdir -p "$HARNESS/state" "$HARNESS/output"

# ПРАВИЛО: HTTP evidence дозволений лише для localhost DEV і тільки GET.
# САБОТАЖ: будь-який POST, unknown path або non-local URL зупиняє сценарій.
REQUEST_LOG="$TMP/requests.log"
ROUTER="$TMP/router.php"
cat >"$ROUTER" <<'ROUTER'
<?php
$log = getenv('RUN_DRIVE_REQUEST_LOG');
$method = $_SERVER['REQUEST_METHOD'] ?? '';
$uri = $_SERVER['REQUEST_URI'] ?? '';
$body = (string) file_get_contents('php://input');
$headers = function_exists('getallheaders') ? (getallheaders() ?: []) : [];
$contentType = '';
$idempotencyPresent = false;
foreach ($headers as $name => $value) {
    if (strtolower((string) $name) === 'content-type') $contentType = (string) $value;
    if (strtolower((string) $name) === 'idempotency-key') $idempotencyPresent = $value !== '';
}
file_put_contents($log, json_encode(['method' => $method, 'uri' => $uri, 'content_type' => $contentType, 'idempotency_present' => $idempotencyPresent, 'body' => $body], JSON_UNESCAPED_SLASHES)."\n", FILE_APPEND | LOCK_EX);
if ($method === 'POST' && str_starts_with($uri, '/translations/validate')) { echo json_encode(['success' => true, 'data' => ['results' => []], 'meta' => ['items' => 1, 'rejected' => 0]]); return; }
if ($method === 'POST' && $uri === '/translations') { echo json_encode(['data' => ['meta' => ['layer' => 'machine', 'mode' => 'direct', 'auto_approve' => true, 'items' => 1, 'written' => 1, 'skipped' => 0, 'rejected' => 0], 'results' => [['index' => 0, 'identity_hash' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'status' => 'ok']]]]); return; }
if ($method !== 'GET') { http_response_code(405); echo json_encode(['error' => 'GET only']); return; }
if ($uri === '/me') { echo json_encode(['data' => ['user' => ['role' => 'super_admin'], 'effective_abilities' => ['translations:write-machine'], 'limits' => ['rows_remaining_today' => 100], 'writes' => ['channels' => [['layer' => 'machine', 'mode' => 'direct', 'allowed' => true], ['layer' => 'manual', 'mode' => 'proposal', 'allowed' => true]]]]]); return; }
if (is_file((string) getenv('RUN_DRIVE_GOAL_FAILURE_FILE')) && str_contains($uri, 'exclude_proposed')) { echo '{"meta":{}}'; return; }
if (str_contains($uri, '/rows')) { echo json_encode(['data' => ['rows' => []], 'meta' => ['total_matching' => 0]]); return; }
http_response_code(404); echo json_encode(['error' => 'unknown path']);
ROUTER
RUN_DRIVE_REQUEST_LOG="$REQUEST_LOG" RUN_DRIVE_GOAL_FAILURE_FILE="$TMP/goal-failure" "$REAL_PHP" -S 127.0.0.1:0 -t "$TMP" "$ROUTER" >"$TMP/server.out" 2>"$TMP/server.err" &
SERVER_PID=$!
for _ in $(seq 1 50); do grep -Fq 'Development Server' "$TMP/server.err" && break; sleep 0.02; done
PORT="$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$TMP/server.err" | head -1)"
test -n "$PORT" || fail 'local HTTP stub did not start'
BASE="http://127.0.0.1:$PORT"
case "$BASE" in http://127.0.0.1:*) ;; *) fail "unsafe stub URL: $BASE" ;; esac
ENV_FILE="$TMP/dev.env"
cat >"$ENV_FILE" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=$BASE
BDO_API_KEY_DEV=test-key
EOF

ROW_FILE="$TMP/rows.json"
cat >"$ROW_FILE" <<'ROWS'
{"data":{"rows":[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_hash":"0237531195208572bd46f6736d33b2f6de15af3809f50d8d6162c1f506784e06","source_text":"Run drive fixture","classification":{"domain":"item","semantic_type":"name"},"tokens":[],"constraints":[],"glossary":{"terms":[]},"reference":null,"patch":"active"}]}}
ROWS

make_workspace() {
    local state="$1" mode="$2" batch_state="$3"
    mkdir -p "$state"
    "$REAL_PHP" -r '
        require $argv[3];
        $w=Bdo\Translate\Batch\Workspace::create($argv[1], Bdo\Translate\Batch\RowSet::fromFile($argv[2]), "20260910_120000");
        copy($argv[2], $w->path("rows.json"));
        $w->updateManifest(function(array $m) use ($argv): array {
            $m["mode"]=$argv[4]; $m["channel"]="machine"; $m["query"]="patch=active";
            $m["memory_layers"]="all"; $m["patch"]="active"; $m["domain"]=""; $m["state"]=$argv[5]; return $m;
        }, "fixture");
    ' "$state" "$ROW_FILE" "$HARNESS/lib/autoload.php" "$mode" "$batch_state"
}

run_side() {
    local side="$1" state="$2" out="$3" err="$4"
    set +e
    if [ "$side" = sh ]; then
        BDO_ORCHESTRATOR=sh BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            bash "$HARNESS/cli/run/run-drive.sh" >"$out" 2>"$err"
    else
        BDO_ORCHESTRATOR=php BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$out" 2>"$err"
    fi
    local code=$?
    set -e
    printf '%s\n' "$code"
}

normalize() { sed -E -e "s#$TMP#TMP#g" -e "s#TMP/(sh|php)-#TMP/side-#g" -e "s#$HARNESS#HARNESS#g" "$1"; }
assert_same_output() {
    local a="$1" b="$2"
    diff -u <(normalize "$a") <(normalize "$b") || fail "shell/PHP output mismatch: $a $b"
}

# ПРАВИЛО: default wrapper маршрутизує саме live internal command.
# САБОТАЖ: прибраний/зіпсований dispatcher має впасти до behavior matrix.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat >"$BIN/php" <<'PHP'
#!/usr/bin/env bash
set -eu
test "$#" -ge 2 || exit 91
test "$1" = "__EXPECTED_REAL_PHP__" && test "$2" = "run-drive" || { printf 'wrong route\n' >&2; exit 92; }
printf 'ROUTING_MARKER:run-drive\n'
PHP
sed "s#__EXPECTED_REAL_PHP__#$HARNESS/cli/bdo.php#" "$BIN/php" >"$BIN/php.tmp"
mv "$BIN/php.tmp" "$BIN/php"
chmod +x "$BIN/php"
routing_out="$TMP/routing.out"
PATH="$BIN:$PATH" BDO_STATE_DIR="$TMP/no-routing-state" bash "$HARNESS/cli/run/run-drive.sh" >"$routing_out"
grep -Fqx 'ROUTING_MARKER:run-drive' "$routing_out" || fail 'run-drive wrapper routing proof failed'

# ПРАВИЛО: missing current batch is a real blocked envelope and must match rollback.
# САБОТАЖ: default PHP route or rollback route returning success invalidates the proof.
mkdir -p "$TMP/sh-no-batch" "$TMP/php-no-batch"
sh_code="$(run_side sh "$TMP/sh-no-batch" "$TMP/sh-no-batch.out" "$TMP/sh-no-batch.err")"
php_code="$(run_side php "$TMP/php-no-batch" "$TMP/php-no-batch.out" "$TMP/php-no-batch.err")"
test "$sh_code" = 1 && test "$php_code" = 1 || fail "no_batch codes: $sh_code/$php_code"
assert_same_output "$TMP/sh-no-batch.out" "$TMP/php-no-batch.out"

# ПРАВИЛО: selected offline реально emit-ить child із payload-файлом, а не synthetic envelope.
# САБОТАЖ: newest-file/stdout fallback або unknown role має зробити fixture red.
for side in sh php; do
    make_workspace "$TMP/$side-child" patch selected
    code="$(run_side "$side" "$TMP/$side-child" "$TMP/$side-child.out" "$TMP/$side-child.err")"
    test "$code" = 0 || fail "$side selected child code=$code: $(cat "$TMP/$side-child.err")"
    grep -Fq '"kind":"child"' "$TMP/$side-child.out" || fail "$side did not emit child"
    grep -Fq '"role":"translation-worker"' "$TMP/$side-child.out" || fail "$side emitted wrong child role"
    test -s "$TMP/$side-child/next-child.json" || fail "$side did not write next-child.json"
done
assert_same_output "$TMP/sh-child.out" "$TMP/php-child.out"

make_dry_workspace() {
    local state="$1"
    make_workspace "$state" patch ready_to_commit
    local batch_dir
    batch_dir="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Прогін"}]' >"$batch_dir/final-candidate.json"
    printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"PASS","severity":"none","issue":"","fix":""}]' >"$batch_dir/final-verdicts.json"
    printf 'local\n' >"$state/run-target"
}

run_dry_side() {
    local side="$1" state="$2" out="$3" err="$4"
    set +e
    if [ "$side" = sh ]; then
        BDO_ORCHESTRATOR=sh BDO_PIPELINE_OFFLINE=1 BDO_DRY_RUN=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            bash "$HARNESS/cli/run/run-drive.sh" >"$out" 2>"$err"
    else
        BDO_ORCHESTRATOR=php BDO_PIPELINE_OFFLINE=1 BDO_DRY_RUN=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$out" 2>"$err"
    fi
    local code=$?
    set -e
    printf '%s\n' "$code"
}

# ПРАВИЛО: BDO_DRY_RUN=1 знімає рівно --write і не робить translation POST.
# САБОТАЖ: примусовий --write має дати captured localhost POST або різний стан.
: >"$REQUEST_LOG"
for side in sh php; do
    make_dry_workspace "$TMP/$side-dry"
    dry_code="$(run_dry_side "$side" "$TMP/$side-dry" "$TMP/$side-dry.out" "$TMP/$side-dry.err")"
    test "$dry_code" = 0 || fail "dry-run/$side code=$dry_code: $(cat "$TMP/$side-dry.err")"
    grep -Fq '"kind":"complete"' "$TMP/$side-dry.out" || fail "dry-run/$side did not complete"
done
assert_same_output "$TMP/sh-dry.out" "$TMP/php-dry.out"
if grep -Fq '"method":"POST"' "$REQUEST_LOG"; then
    fail "dry-run зробив POST: $(cat "$REQUEST_LOG")"
fi

run_write_side() {
    local side="$1" state="$2" out="$3" err="$4"
    set +e
    if [ "$side" = sh ]; then
        BDO_ORCHESTRATOR=sh BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            bash "$HARNESS/cli/run/run-drive.sh" >"$out" 2>"$err"
    else
        BDO_ORCHESTRATOR=php BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$out" 2>"$err"
    fi
    local code=$?
    set -e
    printf '%s\n' "$code"
}

# ПРАВИЛО: normal ready_to_commit write йде тільки в localhost stub; shell/PHP
# мають однаковий GET /me -> POST /translations sequence і verified summary.
# САБОТАЖ: інший channel/body або POST поза localhost має зробити proof red.
: >"$REQUEST_LOG"
make_dry_workspace "$TMP/sh-write"
write_sh_code="$(run_write_side sh "$TMP/sh-write" "$TMP/sh-write.out" "$TMP/sh-write.err")"
cp "$REQUEST_LOG" "$TMP/write.sh.requests"
: >"$REQUEST_LOG"
make_dry_workspace "$TMP/php-write"
write_php_code="$(run_write_side php "$TMP/php-write" "$TMP/php-write.out" "$TMP/php-write.err")"
cp "$REQUEST_LOG" "$TMP/write.php.requests"
test "$write_sh_code" = 0 && test "$write_php_code" = 0 || fail "localhost write codes: $write_sh_code/$write_php_code"
diff -u "$TMP/write.sh.requests" "$TMP/write.php.requests" || fail 'localhost write request sequence differs'
grep -Fq '"method":"POST"' "$TMP/write.php.requests" || fail "normal write did not POST translations: $(cat "$TMP/write.php.requests")"
grep -Fq '"uri":"/translations"' "$TMP/write.php.requests" || fail "normal write POST path differs: $(cat "$TMP/write.php.requests")"
grep -Fq '"content_type":"application/json"' "$TMP/write.php.requests" || fail 'normal write omitted Content-Type'
grep -Fq '"idempotency_present":true' "$TMP/write.php.requests" || fail 'normal write omitted Idempotency-Key'
assert_same_output "$TMP/sh-write.out" "$TMP/php-write.out"

run_goal_unavailable_side() {
    local side="$1" state="$2" out="$3" err="$4"
    set +e
    if [ "$side" = sh ]; then
        BDO_ORCHESTRATOR=sh RUN_DRIVE_GOAL_FAILURE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            bash "$HARNESS/cli/run/run-drive.sh" >"$out" 2>"$err"
    else
        BDO_ORCHESTRATOR=php RUN_DRIVE_GOAL_FAILURE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$out" 2>"$err"
    fi
    local code=$?
    set -e
    printf '%s\n' "$code"
}

# ПРАВИЛО: наявна ціль із невідомим remaining status дає retry, не complete.
# САБОТАЖ: transport/meta failure, зведений до complete, має зробити цей case red.
: >"$TMP/goal-failure"
for side in sh php; do
    make_workspace "$TMP/$side-goal-unavailable" patch verified
    goal_batch_dir="$(find "$TMP/$side-goal-unavailable/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '{"rows":1,"channel":"machine","target_written":1,"target_skipped":0,"target_rejected":0,"moderation_written":0,"moderation_skipped":0,"moderation_rejected":0,"quarantine":0}' >"$goal_batch_dir/batch-summary.json"
    printf '%s\n' '{"query":"patch=active","mode":"patch","patch":"active","domain":""}' >"$TMP/$side-goal-unavailable/run-goal.json"
    printf 'local\n' >"$TMP/$side-goal-unavailable/run-target"
    : >"$REQUEST_LOG"
    goal_code="$(run_goal_unavailable_side "$side" "$TMP/$side-goal-unavailable" "$TMP/$side-goal-unavailable.out" "$TMP/$side-goal-unavailable.err")"
    test "$goal_code" = 1 || fail "goal-unavailable/$side code=$goal_code"
    grep -Fq '"reason":"goal_status_unavailable"' "$TMP/$side-goal-unavailable.out" || fail "goal-unavailable/$side did not name retry reason"
    ! grep -Fq '"kind":"complete"' "$TMP/$side-goal-unavailable.out" || fail "goal-unavailable/$side became complete"
done
assert_same_output "$TMP/sh-goal-unavailable.out" "$TMP/php-goal-unavailable.out"

run_blocker_case() {
    local name="$1" fixture="$2"
    for side in sh php; do
        make_workspace "$TMP/$side-$name" patch "$fixture"
        local batch_dir
        batch_dir="$(find "$TMP/$side-$name/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
        case "$name" in
            retry-corrupt) printf '{broken\n' >"$batch_dir/drive-retries.json" ;;
            goal-corrupt) printf '{broken\n' >"$TMP/$side-$name/run-goal.json" ;;
            summary-failure) mkdir -p "$TMP/$side-$name/run-summary.json" ;;
        esac
        code="$(run_side "$side" "$TMP/$side-$name" "$TMP/$side-$name.out" "$TMP/$side-$name.err")"
        if [ "$code" != 1 ]; then cat "$TMP/$side-$name.err" >&2; fail "$name/$side code=$code"; fi
        grep -Eq 'retry_state_unavailable|run_goal_invalid|run_summary_unavailable' "$TMP/$side-$name.out" || fail "$name/$side missing fail-closed reason"
    done
    assert_same_output "$TMP/sh-$name.out" "$TMP/php-$name.out"
}

# ПРАВИЛО: D136-D138 existing state errors block before child/prune and name path.
# САБОТАЖ: invalid state as empty or unchecked summary persistence must turn red.
run_blocker_case retry-corrupt awaiting_worker
run_blocker_case goal-corrupt verified
run_blocker_case summary-failure verified

# ПРАВИЛО: direct PHP drive no-Unix proof uses the absolute interpreter and a PATH
# whose helper executables all fail; no migrated drive code may invoke them.
# САБОТАЖ: a subprocess call in RunDriveCommand must make this scenario fail.
for helper in bash date grep tail ls head sed awk tr shasum; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"$BIN/$helper"; chmod +x "$BIN/$helper"
done
set +e
BDO_STATE_DIR="$TMP/no-unix" PATH="$BIN:/usr/bin:/bin" "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$TMP/no-unix.out" 2>"$TMP/no-unix.err"
no_unix_code=$?
set -e
test "$no_unix_code" = 1 || fail "no-Unix code=$no_unix_code"
grep -Fq '"reason":"no_current_batch"' "$TMP/no-unix.out" || fail 'no-Unix no_batch proof failed'

# ПРАВИЛО: direct PHP child і verified completion працюють без Unix helpers.
# САБОТАЖ: subprocess у native drive має зробити хоча б один із цих paths red.
make_workspace "$TMP/no-unix-child" patch selected
set +e
BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR="$TMP/no-unix-child" PATH="$BIN:/usr/bin:/bin" "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$TMP/no-unix-child.out" 2>"$TMP/no-unix-child.err"
no_unix_child_code=$?
set -e
test "$no_unix_child_code" = 0 || fail "no-Unix child code=$no_unix_child_code: $(cat "$TMP/no-unix-child.err")"
grep -Fq '"kind":"child"' "$TMP/no-unix-child.out" || fail 'no-Unix child proof did not emit child'
make_workspace "$TMP/no-unix-verified" patch verified
no_unix_verified_batch="$(find "$TMP/no-unix-verified/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
printf '%s\n' '{"rows":1,"channel":"machine","target_written":1,"target_skipped":0,"target_rejected":0,"moderation_written":0,"moderation_skipped":0,"moderation_rejected":0,"quarantine":0}' >"$no_unix_verified_batch/batch-summary.json"
printf 'local\n' >"$TMP/no-unix-verified/run-target"
set +e
BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR="$TMP/no-unix-verified" PATH="$BIN:/usr/bin:/bin" "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$TMP/no-unix-verified.out" 2>"$TMP/no-unix-verified.err"
no_unix_verified_code=$?
set -e
test "$no_unix_verified_code" = 0 || fail "no-Unix verified code=$no_unix_verified_code: $(cat "$TMP/no-unix-verified.err")"
grep -Fq '"kind":"complete"' "$TMP/no-unix-verified.out" || fail 'no-Unix verified proof did not complete'

# ПРАВИЛО: validate seam і timing/role sources живуть у PHP, не у frozen shell text.
# САБОТАЖ: resultPath/timedSteps/roles прибрані з live класів мають зробити check red.
"$REAL_PHP" -r 'require $argv[1]; $r=Bdo\Translate\Cli\Command\Run\RunDriveCommand::roles(); $t=Bdo\Translate\Cli\Command\Run\RunDriveCommand::timedSteps(); if (count($r)!==6 || $t!==["validate.early","validate.final","commit"] || !str_contains(file_get_contents($argv[2]), "resultPath")) exit(1);' \
    "$HARNESS/lib/autoload.php" "$HARNESS/lib/Cli/Command/Api/ValidateCommand.php" || fail 'live roles/timed/validate seam proof failed'

# ПРАВИЛО: validate artifact передається через resultPath(), а не через stdout
# або newest-file пошук.
# САБОТАЖ: stale validate_* sentinel або відсутній structured path має зробити
# локальний validate proof червоним.
VALIDATE_ITEMS="$TMP/validate-items.json"
printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_hash":"0237531195208572bd46f6736d33b2f6de15af3809f50d8d6162c1f506784e06","source_text":"Run drive fixture","text":"Прогін"}]' >"$VALIDATE_ITEMS"
printf '%s\n' '{"sentinel":true}' >"$HARNESS/output/validate_99999999_999999.json"
validate_out="$TMP/validate.out"
set +e
TRANSLATE_ENV_FILE="$ENV_FILE" "$REAL_PHP" -r '
    require $argv[1];
    $command = new Bdo\Translate\Cli\Command\Api\ValidateCommand();
    $code = $command->execute([$argv[2]], new Bdo\Translate\Cli\Output(STDOUT, STDERR));
    echo "RESULT_PATH=".(string) $command->resultPath()."\n";
    exit($code);
' "$HARNESS/lib/autoload.php" "$VALIDATE_ITEMS" >"$validate_out" 2>"$TMP/validate.err"
validate_code=$?
set -e
test "$validate_code" = 0 || fail "structured validate code=$validate_code: $(cat "$TMP/validate.err")"
validate_path="$(sed -n 's/^RESULT_PATH=//p' "$validate_out" | tail -1)"
test -n "$validate_path" && test "$validate_path" != "$HARNESS/output/validate_99999999_999999.json" && test -s "$validate_path" \
    || fail 'validate resultPath() повернув stale або порожній artifact'
grep -Fq '"sentinel":true' "$HARNESS/output/validate_99999999_999999.json" \
    || fail 'stale validate sentinel був перезаписаний'

note 'OK · isolated no-batch, routing, selected child, D136-D138 fail-closed and no-Unix proofs'
