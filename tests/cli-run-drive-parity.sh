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
if ($method === 'POST' && $uri === '/translations/memory') { echo json_encode(['data' => ['memory' => []], 'meta' => ['requested' => 1, 'with_memory' => 0]]); return; }
if ($method === 'POST' && $uri === '/rows/context') { echo json_encode(['data' => ['contexts' => []], 'meta' => ['complete' => true]]); return; }
if ($method === 'POST' && $uri === '/translations') { echo json_encode(['data' => ['meta' => ['layer' => 'machine', 'mode' => 'direct', 'auto_approve' => true, 'items' => 1, 'written' => 1, 'skipped' => 0, 'rejected' => 0], 'results' => [['index' => 0, 'identity_hash' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'status' => 'ok']]]]); return; }
if ($method === 'POST' && $uri === '/glossary/proposals') { echo json_encode(['ok' => true]); return; }
if ($method !== 'GET') { http_response_code(405); echo json_encode(['error' => 'GET only']); return; }
if ($uri === '/me') { echo json_encode(['data' => ['user' => ['role' => 'super_admin'], 'effective_abilities' => ['translations:write-machine'], 'limits' => ['rows_remaining_today' => 100], 'writes' => ['channels' => [['layer' => 'machine', 'mode' => 'direct', 'allowed' => true], ['layer' => 'manual', 'mode' => 'proposal', 'allowed' => true]]]]]); return; }
if (str_starts_with($uri, '/glossary/concepts')) { echo json_encode(['data' => ['concepts' => [['term' => 'Run', 'ua' => 'Прогін', 'gist' => 'fixture']]], 'meta' => ['complete' => true]]); return; }
if (str_starts_with($uri, '/glossary/terms')) { echo json_encode(['data' => ['terms' => ['Run' => ['term_id' => 1, 'ukrainian' => 'Прогін', 'definition' => null]]]]); return; }
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

ROW_GAP_FILE="$TMP/gap-rows.json"
cat >"$ROW_GAP_FILE" <<'ROWS'
{"data":{"rows":[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_hash":"0237531195208572bd46f6736d33b2f6de15af3809f50d8d6162c1f506784e06","source_text":"Run drive fixture","classification":{"domain":"item","semantic_type":"name"},"tokens":[],"constraints":[],"glossary":{"terms":[{"canonical_source":"Run","ukrainian":null,"severity":"mandatory"}]},"reference":null,"patch":"active"}]}}
ROWS

TWENTY_ROW_FILE="$TMP/rows-20.json"
"$REAL_PHP" -r '
    $rows = [];
    for ($i = 1; $i <= 20; $i++) {
        $sourceText = "Run drive 20-row fixture ".$i;
        $rows[] = [
            "identity_hash" => sprintf("%064x", $i),
            "source_hash" => hash("sha256", $sourceText),
            "source_text" => $sourceText,
            "classification" => ["domain" => "item", "semantic_type" => "name"],
            "tokens" => [], "constraints" => [], "glossary" => ["terms" => []],
            "reference" => null, "patch" => "active",
        ];
    }
    file_put_contents($argv[1], json_encode(["data" => ["rows" => $rows]], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");
' "$TWENTY_ROW_FILE"
"$REAL_PHP" -r '
    $value = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
    $rows = $value["data"]["rows"] ?? [];
    $ids = array_map(static fn (array $row): string => (string) ($row["identity_hash"] ?? ""), $rows);
    if (count($rows) !== 20 || count(array_unique($ids)) !== 20) exit(1);
    foreach ($ids as $id) if (! preg_match("/\A[0-9a-f]{64}\z/", $id)) exit(1);
' "$TWENTY_ROW_FILE" || fail 'D151 fixture is not exactly 20 unique 64-hex rows'

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

make_custom_workspace() {
    local state="$1" rows_file="$2" mode="$3" batch_state="$4"
    mkdir -p "$state"
    "$REAL_PHP" -r '
        require $argv[3];
        $w=Bdo\Translate\Batch\Workspace::create($argv[1], Bdo\Translate\Batch\RowSet::fromFile($argv[2]), "20260910_120000");
        copy($argv[2], $w->path("rows.json"));
        $w->updateManifest(function(array $m) use ($argv): array {
            $m["mode"]=$argv[4]; $m["channel"]="machine"; $m["query"]="patch=active";
            $m["memory_layers"]="all"; $m["patch"]="active"; $m["domain"]=""; $m["state"]=$argv[5]; return $m;
        }, "fixture");
    ' "$state" "$rows_file" "$HARNESS/lib/autoload.php" "$mode" "$batch_state"
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

make_d151_workspace() {
    local state="$1"
    make_custom_workspace "$state" "$TWENTY_ROW_FILE" patch ready_to_commit
    local batch
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    "$REAL_PHP" -r '
        $batch = $argv[1];
        $rows = json_decode((string) file_get_contents($batch."/rows.json"), true, 512, JSON_THROW_ON_ERROR)["data"]["rows"] ?? [];
        if (count($rows) !== 20) exit(1);
        $candidates = [];
        $verdicts = [];
        foreach ($rows as $index => $row) {
            $candidates[] = ["identity_hash" => $row["identity_hash"], "text" => "Прогін ".$index];
            $verdicts[] = ["identity_hash" => $row["identity_hash"], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""];
        }
        if (count($candidates) !== 20 || count($verdicts) !== 20) exit(1);
        file_put_contents($batch."/final-candidate.json", json_encode($candidates, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");
        file_put_contents($batch."/final-verdicts.json", json_encode($verdicts, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)."\n");
    ' "$batch" || fail 'D151 workspace is not exactly 20 rows/candidates/verdicts'
    "$REAL_PHP" -r '
        $batch = $argv[1];
        foreach (["rows.json", "final-candidate.json", "final-verdicts.json"] as $name) {
            $value = json_decode((string) file_get_contents($batch."/".$name), true, 512, JSON_THROW_ON_ERROR);
            if (count($value["data"]["rows"] ?? $value) !== 20) exit(1);
        }
    ' "$batch" || fail 'D151 workspace count proof failed before drive'
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

# ПРАВИЛО: Stage5 dry-run identity доводиться RAW artifact, створеним двома реальними orchestrator paths на тому самому 20-row input і тому самому absolute state path.
# САБОТАЖ: будь-яка додаткова/втрачена строка лише в native PHP commit-report.txt мусить зробити raw cmp червоним.
D151_STATE="$TMP/d151-state"
D151_SNAPSHOT="$TMP/d151-snapshot"
make_d151_workspace "$D151_STATE"
D151_BATCH="$(find "$D151_STATE/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
D151_EXTERNAL_REPORT="$TMP/d151-raw-report.txt"
: >"$D151_EXTERNAL_REPORT"
ln -s "$D151_EXTERNAL_REPORT" "$D151_BATCH/commit-report.txt"
cp -a "$D151_STATE" "$D151_SNAPSHOT"
D151_SH_REPORT="$TMP/d151.shell.commit-report.txt"
D151_PHP_REPORT="$TMP/d151.php.commit-report.txt"
D151_SH_REQUESTS="$TMP/d151.shell.requests"
D151_PHP_REQUESTS="$TMP/d151.php.requests"

: >"$REQUEST_LOG"
D151_SH_CODE="$(run_dry_side sh "$D151_STATE" "$TMP/d151.sh.out" "$TMP/d151.sh.err")"
test "$D151_SH_CODE" = 0 || fail "D151 shell code=$D151_SH_CODE: $(cat "$TMP/d151.sh.err")"
test -s "$D151_EXTERNAL_REPORT" || fail 'D151 shell commit-report.txt is empty'
cp "$D151_EXTERNAL_REPORT" "$D151_SH_REPORT"
cp "$REQUEST_LOG" "$D151_SH_REQUESTS"
grep -Fq 'Пачка: 20 рядків | PASS 20, REVIEW 0, REJECT 0' "$D151_SH_REPORT" || fail 'D151 shell report count mismatch'
if grep -Fq '"method":"POST"' "$D151_SH_REQUESTS"; then fail 'D151 shell dry-run made POST'; fi

rm -rf "$D151_STATE"
cp -a "$D151_SNAPSHOT" "$D151_STATE"
diff -qr "$D151_SNAPSHOT" "$D151_STATE" >/dev/null || fail 'D151 snapshot restore differs before PHP'

: >"$REQUEST_LOG"
D151_PHP_CODE="$(run_dry_side php "$D151_STATE" "$TMP/d151.php.out" "$TMP/d151.php.err")"
test "$D151_PHP_CODE" = 0 || fail "D151 PHP code=$D151_PHP_CODE: $(cat "$TMP/d151.php.err")"
test -s "$D151_EXTERNAL_REPORT" || fail 'D151 PHP commit-report.txt is empty'
cp "$D151_EXTERNAL_REPORT" "$D151_PHP_REPORT"
cp "$REQUEST_LOG" "$D151_PHP_REQUESTS"
grep -Fq 'Пачка: 20 рядків | PASS 20, REVIEW 0, REJECT 0' "$D151_PHP_REPORT" || fail 'D151 PHP report count mismatch'
if grep -Fq '"method":"POST"' "$D151_PHP_REQUESTS"; then fail 'D151 PHP dry-run made POST'; fi

if ! cmp -s "$D151_SH_REPORT" "$D151_PHP_REPORT"; then
    diff -u "$D151_SH_REPORT" "$D151_PHP_REPORT" >&2 || true
    fail 'D151 raw commit-report.txt byte identity mismatch'
fi
D151_FACTS="$("$REAL_PHP" -r '$p=$argv[1]; $size=filesize($p); $hash=hash_file("sha256",$p); if ($size === false || $hash === false) exit(1); echo $size." ".$hash."\n";' "$D151_SH_REPORT")"
read -r D151_SH_BYTES D151_SH_SHA <<<"$D151_FACTS"
D151_FACTS="$("$REAL_PHP" -r '$p=$argv[1]; $size=filesize($p); $hash=hash_file("sha256",$p); if ($size === false || $hash === false) exit(1); echo $size." ".$hash."\n";' "$D151_PHP_REPORT")"
read -r D151_PHP_BYTES D151_PHP_SHA <<<"$D151_FACTS"
test "$D151_SH_BYTES" = "$D151_PHP_BYTES" && test "$D151_SH_SHA" = "$D151_PHP_SHA" || fail 'D151 report facts differ after raw cmp'
printf 'D151: 20 rows; same state path; snapshot restore diff=0; shell=%s bytes/%s; php=%s bytes/%s; raw cmp=0; POST shell=0 PHP=0\n' "$D151_SH_BYTES" "$D151_SH_SHA" "$D151_PHP_BYTES" "$D151_PHP_SHA"

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

run_custom_side() {
    local side="$1" state="$2" out="$3" err="$4" offline="$5"
    set +e
    if [ "$side" = sh ]; then
        BDO_ORCHESTRATOR=sh BDO_PIPELINE_OFFLINE="$offline" BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            bash "$HARNESS/cli/run/run-drive.sh" >"$out" 2>"$err"
    else
        BDO_ORCHESTRATOR=php BDO_PIPELINE_OFFLINE="$offline" BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" \
            "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$out" 2>"$err"
    fi
    local code=$?
    set -e
    printf '%s\n' "$code"
}

make_terminology_fixture() {
    local state="$1" exhausted="$2"
    make_workspace "$state" patch awaiting_terminology
    local batch
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '0\n' >"$batch/terminology-chunk"
    printf '%s\n' '[{"canonical_source":"Run"}]' >"$batch/terminology-payload.full.json"
    printf '%s\n' '[]' >"$batch/terminology-answers.json"
    printf '%s\n' '{broken' >"$batch/term-proposals.json"
    if [ "$exhausted" = 1 ]; then
        printf '%s\n' '{"awaiting_terminology:0":{"count":1,"first_at":1,"overall_first_at":1,"window_rollovers":0,"last_at":1,"delay":2}}' >"$batch/drive-retries.json"
    fi
}

# ПРАВИЛО: malformed nonempty term response quarantines and retries the same chunk.
# САБОТАЖ: advance/delete the invalid response, and this differential must fail.
for side in sh php; do
    make_terminology_fixture "$TMP/$side-term-invalid" 0
    code="$(BDO_CHILD_RETRY_WINDOW_SECONDS=600 BDO_CHILD_RETRY_TOTAL_SECONDS=86400 run_custom_side "$side" "$TMP/$side-term-invalid" "$TMP/$side-term-invalid.out" "$TMP/$side-term-invalid.err" 1)"
    test "$code" = 0 || fail "term-invalid/$side code=$code"
    batch="$(find "$TMP/$side-term-invalid/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    test "$(cat "$batch/terminology-chunk")" = 0 || fail "term-invalid/$side advanced chunk"
    test ! -e "$batch/term-proposals.json" || fail "term-invalid/$side kept malformed response"
    compgen -G "$batch/term-proposals.invalid.*.json" >/dev/null || fail "term-invalid/$side did not quarantine response"
    grep -Fq 'translation-terminology' "$TMP/$side-term-invalid.out" || fail "term-invalid/$side did not retry same child"
done
assert_same_output "$TMP/sh-term-invalid.out" "$TMP/php-term-invalid.out"

# ПРАВИЛО: terminology advances only after per-chunk retry exhaustion.
# САБОТАЖ: skip the retry budget or move to the next chunk early, and exhaustion proof fails.
for side in sh php; do
    make_terminology_fixture "$TMP/$side-term-exhausted" 1
    code="$(BDO_CHILD_RETRY_WINDOW_SECONDS=1 BDO_CHILD_RETRY_TOTAL_SECONDS=1 run_custom_side "$side" "$TMP/$side-term-exhausted" "$TMP/$side-term-exhausted.out" "$TMP/$side-term-exhausted.err" 1)"
    test "$code" = 0 || fail "term-exhausted/$side code=$code"
    batch="$(find "$TMP/$side-term-exhausted/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    test "$(cat "$batch/terminology-chunk")" = 1 || fail "term-exhausted/$side did not advance after exhaustion"
    test -s "$batch/worker-payload.json" || fail "term-exhausted/$side did not continue to worker preparation"
done
assert_same_output "$TMP/sh-term-exhausted.out" "$TMP/php-term-exhausted.out"

make_term_notes_fixture() {
    local state="$1"
    make_workspace "$state" patch selected
    printf '%s\n' '{"terms":[{"canonical_source":"Run","ukrainian":"Прогін","identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","snapshot_id":1}]}' >"$state/term-notes-queue.json"
    printf '%s\n' '{"items":[{"canonical_source":"Run","gist":"test","confidence":90}]}' >"$state/term-notes-response.json"
    printf '%s\n' '[]' >"$state/term-proposals.json"
}

# ПРАВИЛО: ready term-notes response submits before a new describe and threshold uses eligible terms.
# САБОТАЖ: describe/delete the ready response or count raw queue entries, and the request/artifact proof fails.
: >"$REQUEST_LOG"
for side in sh php; do
    make_term_notes_fixture "$TMP/$side-term-notes"
    code="$(BDO_TERM_NOTES_MIN_QUEUE=1 run_custom_side "$side" "$TMP/$side-term-notes" "$TMP/$side-term-notes.out" "$TMP/$side-term-notes.err" 0)"
    test "$code" = 0 || fail "term-notes/$side code=$code: $(cat "$TMP/$side-term-notes.err")"
    test ! -e "$TMP/$side-term-notes/term-notes-response.json" || fail "term-notes/$side did not submit response"
    test ! -e "$TMP/$side-term-notes/term-notes-payload.json" || fail "term-notes/$side left ready payload"
    cp "$REQUEST_LOG" "$TMP/term-notes.$side.requests"
    : >"$REQUEST_LOG"
done
diff -u "$TMP/term-notes.sh.requests" "$TMP/term-notes.php.requests" || fail 'term-notes request differential differs'
grep -Fq '"uri":"/glossary/terms' "$TMP/term-notes.sh.requests" || fail 'term-notes shell did not refresh term state'
grep -Fq '"uri":"/glossary/proposals"' "$TMP/term-notes.php.requests" || fail 'term-notes PHP did not submit proposal'

# ПРАВИЛО: online worker preparation refreshes stale concepts; offline preparation never requests concepts.
# САБОТАЖ: omit refresh or make offline use HTTP, and the request/cache differential fails.
for side in sh php; do
    make_workspace "$TMP/$side-concepts-online" patch selected
    printf '%s\n' '{"fetched_at":"old","concepts":[{"term":"Old"}]}' >"$TMP/$side-concepts-online/game-concepts.json"
    touch -t 200001010000 "$TMP/$side-concepts-online/game-concepts.json"
    code="$(run_custom_side "$side" "$TMP/$side-concepts-online" "$TMP/$side-concepts-online.out" "$TMP/$side-concepts-online.err" 0)"
    test "$code" = 0 || fail "concepts-online/$side code=$code"
    cp "$REQUEST_LOG" "$TMP/concepts.$side.requests"
    : >"$REQUEST_LOG"
    grep -Fq '"uri":"/glossary/concepts"' "$TMP/concepts.$side.requests" || fail "concepts-online/$side did not refresh"
    grep -Fq '"term":"Run"' "$TMP/$side-concepts-online/game-concepts.json" || fail "concepts-online/$side kept stale cache"
    make_workspace "$TMP/$side-concepts-offline" patch selected
    printf '%s\n' '{"fetched_at":"old","concepts":[{"term":"Old"}]}' >"$TMP/$side-concepts-offline/game-concepts.json"
    touch -t 200001010000 "$TMP/$side-concepts-offline/game-concepts.json"
    code="$(run_custom_side "$side" "$TMP/$side-concepts-offline" "$TMP/$side-concepts-offline.out" "$TMP/$side-concepts-offline.err" 1)"
    test "$code" = 0 || fail "concepts-offline/$side code=$code"
    test ! -s "$REQUEST_LOG" || fail "concepts-offline/$side made HTTP request"
    grep -Fq '"term":"Old"' "$TMP/$side-concepts-offline/game-concepts.json" || fail "concepts-offline/$side changed cache"
done
diff -u "$TMP/concepts.sh.requests" "$TMP/concepts.php.requests" || fail 'concepts request differential differs'

# ПРАВИЛО: recovery states retain legacy guards and never reinterpret missing artifacts as success.
# САБОТАЖ: remove a candidate/clean guard or skip schema rebuild, and the named state proof fails.
for state_name in candidate-valid deterministic-valid; do
    for side in sh php; do
        state="$TMP/$side-$state_name"
        if [ "$state_name" = candidate-valid ]; then wanted_state=candidate_valid; else wanted_state=deterministic_valid; fi
        make_workspace "$state" patch "$wanted_state"
        code="$(run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
        test "$code" = 1 || fail "$state_name/$side code=$code"
        if [ "$state_name" = candidate-valid ]; then grep -Fq 'candidate_missing' "$state.out" || fail "$state_name/$side reason"; else grep -Fq 'clean_candidate_missing' "$state.out" || fail "$state_name/$side reason"; fi
    done
    assert_same_output "$TMP/sh-$state_name.out" "$TMP/php-$state_name.out"
done

# ПРАВИЛО: memory-covered awaiting_worker resumes without a worker child.
# САБОТАЖ: ignore the memory-covered guard and dispatch translation-worker, and this case fails.
for side in sh php; do
    state="$TMP/$side-memory-covered"
    make_workspace "$state" patch awaiting_worker
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '{"data":{"rows":[]}}' >"$batch/to-translate.json"
    printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Прогін"}]' >"$batch/memory-candidate.json"
    code="$(run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
    test "$code" = 0 || fail "memory-covered/$side code=$code"
    ! grep -Fq '"role":"translation-worker"' "$state.out" || fail "memory-covered/$side dispatched worker"
done

# ПРАВИЛО: optional term-notes queue enrichment is non-gating.
# САБОТАЖ: make queue helper failure fatal, and selected online must turn red instead of emitting worker child.
for side in sh php; do
    state="$TMP/$side-optional-queue"
    make_workspace "$state" patch selected
    printf '%s\n' '{broken' >"$state/term-notes-queue.json"
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '"broken"' >"$batch/terms.json"
    : >"$REQUEST_LOG"
    code="$(run_custom_side "$side" "$state" "$state.out" "$state.err" 0)"
    test "$code" = 0 || fail "optional-queue/$side code=$code"
    grep -Fq '"role":"translation-worker"' "$state.out" || fail "optional-queue/$side became gating"
done

# ПРАВИЛО: invalid nonempty names-fixes повторно будує schema саме з names-subset.
# САБОТАЖ: пропущений rebuild має залишити stale identity enum і зробити case red.
for side in sh php; do
    state="$TMP/$side-names-invalid"
    make_workspace "$state" patch names_pass
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Прогін"}]' >"$batch/final-candidate.json"
    printf '%s\n' '{"items":[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' >"$batch/names-payload.json"
    cp "$batch/rows.json" "$batch/names-subset.json"
    printf '%s\n' '{"properties":{"items":{"items":{"properties":{"identity_hash":{"enum":["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}}}}}}' >"$state/current-response-schema.json"
    printf '%s\n' '{broken' >"$batch/names-fixes.json"
    code="$(BDO_CHILD_RETRY_WINDOW_SECONDS=600 run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
    test "$code" = 0 || fail "names-invalid/$side code=$code"
    grep -Fq '"role":"translation-names"' "$state.out" || fail "names-invalid/$side missing retry child"
    compgen -G "$batch/names-fixes.invalid.*.json" >/dev/null || fail "names-invalid/$side did not quarantine response"
    grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$state/current-response-schema.json" || fail "names-invalid/$side schema was not rebuilt"
    ! grep -Fq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$state/current-response-schema.json" || fail "names-invalid/$side kept stale schema"
done
assert_same_output "$TMP/sh-names-invalid.out" "$TMP/php-names-invalid.out"

# ПРАВИЛО: zero-byte QA payload має бути перебудований перед redispatch child.
# САБОТАЖ: трактувати порожній файл як готовий payload, і nonempty proof впаде.
for side in sh php; do
    state="$TMP/$side-qa-zero-payload"
    make_workspace "$state" patch awaiting_qa
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Прогін"}]' >"$batch/clean.json"
    : >"$batch/qa-payload.json"
    rm -f "$batch/verdicts.json"
    code="$(BDO_CHILD_RETRY_WINDOW_SECONDS=600 run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
    test "$code" = 0 || fail "qa-zero-payload/$side code=$code"
    grep -Fq '"role":"translation-qa"' "$state.out" || fail "qa-zero-payload/$side missing QA child"
    test -s "$batch/qa-payload.json" || fail "qa-zero-payload/$side payload stayed empty"
    grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$batch/qa-payload.json" || fail "qa-zero-payload/$side payload missing row"
done
assert_same_output "$TMP/sh-qa-zero-payload.out" "$TMP/php-qa-zero-payload.out"

# ПРАВИЛО: zero-byte term-proposals не приглушує реальний terminology gap.
# САБОТАЖ: перевіряти лише is_file замість nonempty semantics, і child зникне.
for side in sh php; do
    state="$TMP/$side-term-proposals-zero"
    make_custom_workspace "$state" "$ROW_GAP_FILE" patch selected
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    : >"$batch/term-proposals.json"
    : >"$REQUEST_LOG"
    code="$(run_custom_side "$side" "$state" "$state.out" "$state.err" 0)"
    test "$code" = 0 || fail "term-proposals-zero/$side code=$code"
    grep -Fq '"role":"translation-terminology"' "$state.out" || fail "term-proposals-zero/$side skipped terminology"
    test -s "$batch/terminology-payload.full.json" || fail "term-proposals-zero/$side missing terminology payload"
done
assert_same_output "$TMP/sh-term-proposals-zero.out" "$TMP/php-term-proposals-zero.out"

make_memory_fixture() {
    local state="$1"
    make_workspace "$state" improve selected
    local batch
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    "$REAL_PHP" -r '$p=$argv[1];$m=json_decode(file_get_contents($p),true,512,JSON_THROW_ON_ERROR);unset($m["memory_layers"]);file_put_contents($p,json_encode($m,JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT));' "$batch/manifest.json"
    printf '%s\n' '{"data":{"memory":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"variants":[{"text":"Машинний","layer":"machine"},{"text":"Ручний","layer":"manual"}]}}}}' >"$batch/memory.json"
}

run_layer_side() {
    local layer="$1" side="$2" state="$3" out="$4" err="$5"
    set +e
    if [ "$side" = sh ]; then
        if [ "$layer" = unset ]; then
            env -u BDO_MEMORY_LAYERS BDO_ORCHESTRATOR=sh BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" bash "$HARNESS/cli/run/run-drive.sh" >"$out" 2>"$err"
        else
            BDO_MEMORY_LAYERS="$layer" BDO_ORCHESTRATOR=sh BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" bash "$HARNESS/cli/run/run-drive.sh" >"$out" 2>"$err"
        fi
    else
        if [ "$layer" = unset ]; then
            env -u BDO_MEMORY_LAYERS BDO_ORCHESTRATOR=php BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$out" 2>"$err"
        else
            BDO_MEMORY_LAYERS="$layer" BDO_ORCHESTRATOR=php BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 TRANSLATE_ENV_FILE="$ENV_FILE" BDO_STATE_DIR="$state" "$REAL_PHP" "$HARNESS/cli/bdo.php" run-drive >"$out" 2>"$err"
        fi
    fi
    local code=$?
    set -e
    printf '%s\n' "$code"
}

# ПРАВИЛО: legacy improve без manifest memory_layers використовує manual downstream.
# САБОТАЖ: прибрати fallback manual, і memory-candidate покаже machine layer.
for side in sh php; do
    state="$TMP/$side-improve-memory-fallback"
    make_memory_fixture "$state"
    code="$(run_layer_side unset "$side" "$state" "$state.out" "$state.err")"
    test "$code" = 0 || fail "improve-memory-fallback/$side code=$code"
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    grep -Fq 'Ручний' "$batch/memory-candidate.json" || fail "improve-memory-fallback/$side did not use manual memory"
    ! grep -Fq 'Машинний' "$batch/memory-candidate.json" || fail "improve-memory-fallback/$side used machine memory"
done
assert_same_output "$TMP/sh-improve-memory-fallback.out" "$TMP/php-improve-memory-fallback.out"

# ПРАВИЛО: зовнішній BDO_MEMORY_LAYERS є immutable override для downstream selection.
# САБОТАЖ: overwrite the exported layer, і external machine selection стане manual.
for side in sh php; do
    state="$TMP/$side-memory-layer-preserved"
    make_memory_fixture "$state"
    code="$(run_layer_side all "$side" "$state" "$state.out" "$state.err")"
    test "$code" = 0 || fail "memory-layer-preserved/$side code=$code"
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    grep -Fq 'Машинний' "$batch/memory-candidate.json" || fail "memory-layer-preserved/$side overwrote external layer"
done
assert_same_output "$TMP/sh-memory-layer-preserved.out" "$TMP/php-memory-layer-preserved.out"

# ПРАВИЛО: term-note threshold рахує eligible identity/snapshot, не raw queue length.
# САБОТАЖ: raw-count замість eligible count має запустити glossary на negative fixture.
for side in sh php; do
    state="$TMP/$side-term-threshold-negative"
    make_workspace "$state" patch selected
    printf '%s\n' '{"terms":[{"canonical_source":"Already","identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","snapshot_id":1},{"canonical_source":"Missing","snapshot_id":1},{"canonical_source":"Done","identity_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","snapshot_id":1}]}' >"$state/term-notes-queue.json"
    printf '%s\n' '{"terms":["Already","Done"]}' >"$state/proposed-term-notes.json"
    : >"$REQUEST_LOG"
    code="$(BDO_TERM_NOTES_MIN_QUEUE=2 run_custom_side "$side" "$state" "$state.out" "$state.err" 0)"
    test "$code" = 0 || fail "term-threshold-negative/$side code=$code"
    ! grep -Fq '"role":"translation-glossary"' "$state.out" || fail "term-threshold-negative/$side used raw queue"
    ! grep -Fq '"/glossary/terms' "$REQUEST_LOG" || fail "term-threshold-negative/$side requested glossary child"
    test ! -e "$state/term-notes-payload.json" || fail "term-threshold-negative/$side evaluated raw queue threshold"
done
assert_same_output "$TMP/sh-term-threshold-negative.out" "$TMP/php-term-threshold-negative.out"

# ПРАВИЛО: eligible count рівно MIN запускає translation-glossary.
# САБОТАЖ: raw/eligible boundary або strict inequality має прибрати exact child.
for side in sh php; do
    state="$TMP/$side-term-threshold-positive"
    make_workspace "$state" patch selected
    printf '%s\n' '{"terms":[{"canonical_source":"One","ukrainian":"Один","identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","snapshot_id":1},{"canonical_source":"Two","ukrainian":"Два","identity_hash":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","snapshot_id":1}]}' >"$state/term-notes-queue.json"
    printf '%s\n' '{"terms":[]}' >"$state/proposed-term-notes.json"
    : >"$REQUEST_LOG"
    code="$(BDO_TERM_NOTES_MIN_QUEUE=2 run_custom_side "$side" "$state" "$state.out" "$state.err" 0)"
    test "$code" = 0 || fail "term-threshold-positive/$side code=$code"
    grep -Fq '"role":"translation-glossary"' "$state.out" || fail "term-threshold-positive/$side missed exact threshold"
    test -s "$state/term-notes-payload.json" || fail "term-threshold-positive/$side missing glossary payload"
done
assert_same_output "$TMP/sh-term-threshold-positive.out" "$TMP/php-term-threshold-positive.out"

helper_shell_path() {
    case "$1" in
        term-notes-describe) printf '%s\n' 'cli/api/term-notes-describe.sh' ;;
        concepts) printf '%s\n' 'cli/api/glossary-concepts.sh' ;;
        memory-apply) printf '%s\n' 'cli/prepare/memory-apply.sh' ;;
        term-notes-queue) printf '%s\n' 'cli/api/term-notes-queue.sh' ;;
        terminology-payload) printf '%s\n' 'cli/prepare/terminology-payload.sh' ;;
        check-russianisms) printf '%s\n' 'cli/quality/check-russianisms.sh' ;;
        judge-payload) printf '%s\n' 'cli/prepare/judge-payload.sh' ;;
        names-payload) printf '%s\n' 'cli/prepare/names-payload.sh' ;;
        *) fail "unknown helper shell path: $1" ;;
    esac
}

helper_php_path() {
    case "$1" in
        term-notes-describe) printf '%s\n' 'lib/Cli/Command/Api/TermNotesDescribeCommand.php' ;;
        concepts) printf '%s\n' 'lib/Cli/Command/Api/GlossaryConceptsCommand.php' ;;
        memory-apply) printf '%s\n' 'lib/Cli/Command/Prepare/MemoryApplyCommand.php' ;;
        term-notes-queue) printf '%s\n' 'lib/Cli/Command/Api/TermNotesQueueCommand.php' ;;
        terminology-payload) printf '%s\n' 'lib/Cli/Command/Prepare/TerminologyPayloadCommand.php' ;;
        check-russianisms) printf '%s\n' 'lib/Cli/Command/Quality/CheckRussianismsCommand.php' ;;
        judge-payload) printf '%s\n' 'lib/Cli/Command/Prepare/JudgePayloadCommand.php' ;;
        names-payload) printf '%s\n' 'lib/Cli/Command/Prepare/NamesPayloadCommand.php' ;;
        *) fail "unknown helper PHP path: $1" ;;
    esac
}

inject_helper_failure() {
    local helper="$1" side="$2" tag="$3"
    if [ "$side" = sh ]; then
        local relative
        relative="$(helper_shell_path "$helper")"
        cp "$ROOT/$relative" "$HARNESS/$relative"
        "$REAL_PHP" -r '
            $path=$argv[1]; $tag=$argv[2]; $source=(string) file_get_contents($path);
            $needle="#!/usr/bin/env bash\n";
            $line="if [ -n \"\$D150_MARKER\" ]; then printf \"%s\\n\" \"D150-".$tag."\" > \"\$D150_MARKER\"; exit 7; fi\n";
            if (substr_count($source, $needle) !== 1) exit(1);
            $count=0;
            file_put_contents($path, str_replace($needle, $needle.$line, $source, $count));
        ' "$HARNESS/$relative" "$tag"
    else
        local relative
        relative="$(helper_php_path "$helper")"
        cp "$ROOT/$relative" "$HARNESS/$relative"
        "$REAL_PHP" -r '
            $path=$argv[1]; $tag=$argv[2]; $source=(string) file_get_contents($path);
            $needle="    public function execute(array \$arguments, Output \$output): int\n    {\n";
            $line="        file_put_contents((string) getenv(\"D150_MARKER\"), \"D150-".$tag."\\n\"); throw new \\RuntimeException(\"D150 injected\");\n";
            if (substr_count($source, $needle) !== 1) exit(1);
            $count=0;
            file_put_contents($path, str_replace($needle, $needle.$line, $source, $count));
        ' "$HARNESS/$relative" "$tag"
    fi
}

restore_helper_failure() {
    local helper="$1"
    cp "$ROOT/$(helper_shell_path "$helper")" "$HARNESS/$(helper_shell_path "$helper")"
    cp "$ROOT/$(helper_php_path "$helper")" "$HARNESS/$(helper_php_path "$helper")"
}

prepare_optional_helper_fixture() {
    local helper="$1" state="$2"
    case "$helper" in
        concepts)
            make_workspace "$state" patch selected
            printf '%s\n' '{"fetched_at":"old","concepts":[{"term":"Old"}]}' >"$state/game-concepts.json"
            touch -t 200001010000 "$state/game-concepts.json"
            ;;
        memory-apply)
            make_workspace "$state" patch selected
            local batch
            batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
            printf '%s\n' '{"data":{"memory":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"variants":[{"text":"Ручний","layer":"manual"}]}}}}' >"$batch/memory.json"
            ;;
        term-notes-describe)
            make_workspace "$state" patch selected
            printf '%s\n' '{"terms":[{"canonical_source":"Run","ukrainian":"Прогін","identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","snapshot_id":1}]}' >"$state/term-notes-queue.json"
            printf '%s\n' '{"terms":[]}' >"$state/proposed-term-notes.json"
            ;;
        term-notes-queue)
            make_workspace "$state" patch selected
            local batch
            batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
            printf '%s\n' '[]' >"$batch/terms.json"
            ;;
        terminology-payload)
            make_custom_workspace "$state" "$ROW_GAP_FILE" patch selected
            ;;
        check-russianisms)
            make_workspace "$state" patch candidate_valid
            local batch
            batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
            printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Прогін"}]' >"$batch/candidate.json"
            ;;
        judge-payload)
            make_workspace "$state" patch awaiting_qa
            local batch
            batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
            printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","text":"Прогін"}]' >"$batch/clean.json"
            cp "$batch/rows.json" "$batch/qa-subset.json"
            printf '%s\n' '[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"PASS","severity":"none","issue":"","fix":""}]' >"$batch/verdicts.json"
            ;;
        names-payload)
            make_dry_workspace "$state"
            printf '%s\n' '{"success":true,"data":{"results":[{"identity_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","status":"rejected","code":"glossary_violation","details":{"glossary":[{"canonical":"Run","expected":"Прогін"}]}}]}}' >"$TMP/d150-validate.json"
            ;;
        *) fail "unknown helper fixture: $helper" ;;
    esac
}

# ПРАВИЛО: усі rollback-optional helpers nonzero/Throwable є non-gating, але виклик має бути доведений marker-ом.
# САБОТАЖ: прибрати відповідний catch і injected exception мусить зробити саме helper case red.
for helper in concepts memory-apply term-notes-describe term-notes-queue terminology-payload check-russianisms judge-payload names-payload; do
    for side in sh php; do
        state="$TMP/$side-d150-$helper"
        marker="$TMP/$side-d150-$helper.marker"
        restore_helper_failure "$helper"
        inject_helper_failure "$helper" "$side" "$helper"
        prepare_optional_helper_fixture "$helper" "$state"
        : >"$REQUEST_LOG"
        if [ "$helper" = term-notes-describe ]; then
            code="$(D150_MARKER="$marker" BDO_TERM_NOTES_MIN_QUEUE=1 run_custom_side "$side" "$state" "$state.out" "$state.err" 0)"
        elif [ "$helper" = terminology-payload ] || [ "$helper" = concepts ]; then
            code="$(D150_MARKER="$marker" run_custom_side "$side" "$state" "$state.out" "$state.err" 0)"
        elif [ "$helper" = names-payload ]; then
            code="$(D150_MARKER="$marker" BDO_FINAL_VALIDATE_STUB="$TMP/d150-validate.json" run_dry_side "$side" "$state" "$state.out" "$state.err")"
        else
            code="$(D150_MARKER="$marker" run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
        fi
        test "$code" = 0 || fail "d150-$helper/$side code=$code"
        test -s "$marker" || fail "d150-$helper/$side marker missing"
        grep -Fq "D150-$helper" "$marker" || fail "d150-$helper/$side wrong marker"
        if [ "$helper" = names-payload ]; then
            grep -Fq '"kind":"complete"' "$state.out" || fail "d150-$helper/$side did not continue to dry commit"
        elif [ "$helper" = judge-payload ]; then
            grep -Eq '"kind":"(child|continue|complete)"' "$state.out" || fail "d150-$helper/$side did not continue"
        else
            grep -Fq '"kind":"child"' "$state.out" || fail "d150-$helper/$side did not continue"
        fi
        if [ "$side" = php ]; then
            assert_same_output "$TMP/sh-d150-$helper.out" "$TMP/php-d150-$helper.out"
        fi
    done
    restore_helper_failure "$helper"
done

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

# ПРАВИЛО: successful local write followed by completion failure is nonzero and preserves evidence.
# САБОТАЖ: prune or emit success after blocked completion, and the post-write case fails.
for side in sh php; do
    state="$TMP/$side-post-write-summary"
    make_dry_workspace "$state"
    mkdir -p "$state/run-summary.json"
    : >"$REQUEST_LOG"
    code="$(run_write_side "$side" "$state" "$state.out" "$state.err")"
    test "$code" = 1 || fail "post-write-summary/$side code=$code"
    grep -Fq 'run_summary_unavailable' "$state.out" || fail "post-write-summary/$side missing completion failure"
    grep -Fq '"method":"POST"' "$REQUEST_LOG" || fail "post-write-summary/$side did not reach local translation write"
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    test -e "$batch/final-candidate.json" || fail "post-write-summary/$side pruned evidence"
done

# ПРАВИЛО: prune removes only old rows/validate dumps at or before the batch manifest.
# САБОТАЖ: omit output cleanup or delete newer dumps, and the old/new boundary fails.
for side in sh php; do
    state="$TMP/$side-output-prune"
    make_dry_workspace "$state"
    mkdir -p "$TMP/output"
    printf 'old\n' >"$TMP/output/rows_old.json"
    printf 'old\n' >"$TMP/output/validate_old.json"
    printf 'new\n' >"$TMP/output/rows_new.json"
    printf 'new\n' >"$TMP/output/validate_new.json"
    touch -t 200001010000 "$TMP/output/rows_old.json" "$TMP/output/validate_old.json"
    touch -t 299912312359 "$TMP/output/rows_new.json" "$TMP/output/validate_new.json"
    code="$(run_dry_side "$side" "$state" "$state.out" "$state.err")"
    test "$code" = 0 || fail "output-prune/$side code=$code"
    test ! -e "$TMP/output/rows_old.json" && test ! -e "$TMP/output/validate_old.json" || fail "output-prune/$side kept old dump"
    test -e "$TMP/output/rows_new.json" && test -e "$TMP/output/validate_new.json" || fail "output-prune/$side removed new dump"
done

# ПРАВИЛО: exhausted invalid QA quarantines the canonical verdict artifact before give-up.
# САБОТАЖ: give up with canonical verdicts.json in place, and the exhaustion proof fails.
for side in sh php; do
    state="$TMP/$side-invalid-qa-exhausted"
    make_workspace "$state" patch awaiting_qa
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    cp "$batch/rows.json" "$batch/qa-subset.json"
    printf '%s\n' '{broken' >"$batch/verdicts.json"
    printf '%s\n' '{"awaiting_qa":{"count":1,"first_at":1,"overall_first_at":1,"window_rollovers":0,"last_at":1,"delay":2}}' >"$batch/drive-retries.json"
    code="$(BDO_CHILD_RETRY_WINDOW_SECONDS=1 BDO_CHILD_RETRY_TOTAL_SECONDS=1 run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
    test "$code" = 1 || fail "invalid-qa-exhausted/$side code=$code"
    test ! -e "$batch/verdicts.json" || fail "invalid-qa-exhausted/$side kept canonical verdicts"
    compgen -G "$batch/verdicts.invalid.*.json" >/dev/null || fail "invalid-qa-exhausted/$side did not archive verdicts"
done

# ПРАВИЛО: unknown offline remaining stays complete; only a proven zero emits goal_complete.
# САБОТАЖ: convert offline unknown to numeric zero, and the three-case goal differential fails.
for side in sh php; do
    state="$TMP/$side-offline-goal"
    make_workspace "$state" patch verified
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '{"rows":1,"channel":"machine","target_written":1,"target_skipped":0,"target_rejected":0,"moderation_written":0,"moderation_skipped":0,"moderation_rejected":0,"quarantine":0}' >"$batch/batch-summary.json"
    printf '%s\n' '{"query":"patch=active","mode":"patch","patch":"active","domain":""}' >"$state/run-goal.json"
    printf 'local\n' >"$state/run-target"
    code="$(run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
    test "$code" = 0 || fail "offline-goal/$side code=$code"
    grep -Fq '"kind":"complete"' "$state.out" || fail "offline-goal/$side did not preserve complete"
    ! grep -Fq '"kind":"goal_complete"' "$state.out" || fail "offline-goal/$side hid unknown as goal_complete"
    state="$TMP/$side-explicit-zero-goal"
    make_workspace "$state" patch verified
    batch="$(find "$state/batches" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    printf '%s\n' '{"rows":1,"channel":"machine","target_written":1,"target_skipped":0,"target_rejected":0,"moderation_written":0,"moderation_skipped":0,"moderation_rejected":0,"quarantine":0}' >"$batch/batch-summary.json"
    printf '%s\n' '{"query":"patch=active","mode":"patch","patch":"active","domain":""}' >"$state/run-goal.json"
    printf 'local\n' >"$state/run-target"
    code="$(BDO_GOAL_REMAINING_STUB=0 run_custom_side "$side" "$state" "$state.out" "$state.err" 1)"
    test "$code" = 0 || fail "explicit-zero/$side code=$code"
    grep -Fq '"kind":"goal_complete"' "$state.out" || fail "explicit-zero/$side did not emit goal_complete"
done

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

note 'OK · isolated state-machine differential, D136-D147 branches, local write, and no-Unix proofs'
