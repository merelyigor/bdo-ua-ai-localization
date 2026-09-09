#!/usr/bin/env bash
# Довести парність write/commit/moderation між rollback shell і PHP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER=''
REAL_PHP="$(command -v php)"
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; find "$ROOT/output" -maxdepth 1 -type f -name "write_*.json" -delete 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ПРАВИЛО: default/php wrapper мусить передати internal route у Kernel.
# САБОТАЖ: вилучення dispatcher має зробити routing proof червоним.
mkdir -p "$TMP/fake-php"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1:$2" in' '*/cli/bdo.php:commit|*/cli/bdo.php:write|*/cli/bdo.php:moderation) printf "__ROUTE__ %s\n" "$2"; exit 0 ;;' '*) exit 91 ;;' 'esac' > "$TMP/fake-php/php"
chmod +x "$TMP/fake-php/php"
for pair in 'cli/batch/batch-commit.sh commit' 'cli/write/write-translations.sh write' 'cli/write/moderation-queue.sh moderation'; do
    set -- $pair
    route="$(PATH="$TMP/fake-php:/usr/bin:/bin" BDO_ORCHESTRATOR=php bash "$ROOT/$1")" || fail "routing $1"
    grep -Fq "__ROUTE__ $2" <<<"$route" || fail "routing $1 не дала $2"
done

PORT=$((28000 + RANDOM % 1000))
printf 'list\n' > "$TMP/stub-mode"
cat > "$TMP/router.php" <<'PHP'
<?php
$uri = (string) ($_SERVER['REQUEST_URI'] ?? '/');
$path = (string) parse_url($uri, PHP_URL_PATH);
$log = (string) getenv('STUB_LOG');
$body = (string) file_get_contents('php://input');
$stubMode = trim((string) @file_get_contents((string) getenv('STUB_MODE_FILE')));
$remaining = $stubMode === 'quota' ? 0 : 100;
file_put_contents($log, json_encode(['method'=>$_SERVER['REQUEST_METHOD'] ?? '', 'path'=>$uri, 'body'=>$body], JSON_UNESCAPED_UNICODE)."\n", FILE_APPEND);
header('Content-Type: application/json');
if ($path === '/me') {
    echo json_encode(['data'=>['user'=>['role'=>'super_admin'], 'effective_abilities'=>['translations:write-machine'], 'limits'=>['rows_remaining_today'=>$remaining], 'writes'=>['channels'=>[
        ['layer'=>'machine','mode'=>'direct','allowed'=>true,'result'=>'machine'],
        ['layer'=>'manual','mode'=>'proposal','allowed'=>true,'result'=>'manual'],
    ]]]], JSON_UNESCAPED_UNICODE);
    return;
}
if ($path === '/translations') {
    $request = json_decode($body, true) ?: [];
    $items = is_array($request['items'] ?? null) ? $request['items'] : [];
    $results = [];
    foreach ($items as $index => $item) $results[] = ['index'=>$index, 'identity_hash'=>$item['identity_hash'] ?? '', 'status'=>'ok'];
    $rejected = (($items[0]['identity_hash'] ?? '') === 'reject') ? 1 : 0;
    if ($rejected > 0) $results = [['index'=>0, 'identity_hash'=>'reject', 'status'=>'rejected', 'code'=>'invalid', 'message'=>'відхилено']];
    echo json_encode(['data'=>['meta'=>['layer'=>$request['layer'] ?? '', 'mode'=>$request['mode'] ?? '', 'auto_approve'=>$request['auto_approve'] ?? false, 'items'=>count($items), 'written'=>count($items)-$rejected, 'skipped'=>0, 'rejected'=>$rejected, 'rows_remaining_today'=>$remaining-count($items)], 'results'=>$results]], JSON_UNESCAPED_UNICODE);
    return;
}
if ($path === '/translations/proposals') {
    echo json_encode(['data'=>['proposals'=>[['id'=>12,'identity_hash'=>'h12','source_text'=>'Source','text'=>'Переклад'],['id'=>15,'identity_hash'=>'h15','source_text'=>'Other','text'=>'Інше']]], 'meta'=>['total_matching'=>2]], JSON_UNESCAPED_UNICODE);
    return;
}
if (preg_match('~^/translations/proposals/[0-9]+/(approve|reject)$~', $path) === 1) {
    if (str_contains($path, '/15/approve')) { http_response_code(418); echo json_encode(['success'=>false]); return; }
    echo json_encode(['success'=>true, 'data'=>['ok'=>true]]);
    return;
}
http_response_code(404);
echo json_encode(['success'=>false, 'error'=>['code'=>'not_found','message'=>$path]]);
PHP
: > "$TMP/requests.log"
STUB_LOG="$TMP/requests.log" STUB_MODE_FILE="$TMP/stub-mode" "$REAL_PHP" -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    "$REAL_PHP" -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);} exit(1);' "$PORT" && break
    sleep .1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }
cat > "$TMP/env" <<ENV
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test-key
ENV
export TRANSLATE_ENV_FILE="$TMP/env"

H1="$(printf '%064d' 1)"
H2="$(printf '%064d' 2)"
H3="$(printf '%064d' 3)"
printf '[{"identity_hash":"%s","source_hash":"%s","text":"Переклад"}]\n' "$H1" "$H2" > "$TMP/items.json"
cat > "$TMP/rows.json" <<JSON
{"data":{"rows":[{"identity_hash":"$H1","source_hash":"source-1","source_text":"Source 1"},{"identity_hash":"$H2","source_hash":"source-2","source_text":"Source 2"},{"identity_hash":"$H3","source_hash":"source-3","source_text":"Source 3"}]}}
JSON
printf '[{"identity_hash":"%s","text":"Переклад 1"},{"identity_hash":"%s","text":"Переклад 2"},{"identity_hash":"%s","text":"Переклад 3"}]\n' "$H1" "$H2" "$H3" > "$TMP/candidate.json"
printf '[{"identity_hash":"%s","status":"PASS","severity":"none","issue":"","fix":""},{"identity_hash":"%s","status":"PASS","severity":"none","issue":"","fix":""},{"identity_hash":"%s","status":"PASS","severity":"none","issue":"","fix":""}]\n' "$H1" "$H2" "$H3" > "$TMP/verdicts.json"

normalize() {
    sed -E -e "s|$TMP/state-[^ ]+|STATE|g" -e "s|$TMP|TMP|g" -e 's|/tmp/[^ ]+|TMP|g' -e 's|write_[0-9]{8}_[0-9]{6}\.json|write_TIMESTAMP.json|g' -e 's/"at":"[^"]+"/"at":"TIME"/g' -e 's/"at": "[^"]+"/"at": "TIME"/g'
}
run_capture() {
    local label="$1" state="$2" orchestrator="$3" script="$4"; shift 4
    mkdir -p "$state"
    set +e
    STUB_LOG="$TMP/requests.log" BDO_STATE_DIR="$state" BDO_ORCHESTRATOR="$orchestrator" bash "$ROOT/$script" "$@" >"$TMP/$label.out" 2>"$TMP/$label.err"
    printf '%s\n' "$?" > "$TMP/$label.code"
    set -e
}
compare_pair() {
    local name="$1"
    cmp -s <(normalize < "$TMP/$name.sh.out") <(normalize < "$TMP/$name.php.out") || { diff -u <(normalize < "$TMP/$name.sh.out") <(normalize < "$TMP/$name.php.out") >&2 || true; fail "$name stdout"; }
    cmp -s <(normalize < "$TMP/$name.sh.err") <(normalize < "$TMP/$name.php.err") || fail "$name stderr"
    cmp -s "$TMP/$name.sh.code" "$TMP/$name.php.code" || fail "$name code"
}

# ПРАВИЛО: channel mapping і LIST data.writes.channels є source of truth.
# САБОТАЖ: інша форма body/mapping мусить змінити captured request.
for channel in machine manual proposal; do
    printf 'list\n' > "$TMP/stub-mode"
    rm -f "$ROOT/output"/write_*.json; : > "$TMP/requests.log"
    run_capture "write-$channel.sh" "$TMP/state-write-$channel-sh" sh cli/write/write-translations.sh --channel "$channel" --idempotency-key stable "$TMP/items.json"
    receipt="$(find "$ROOT/output" -maxdepth 1 -name 'write_*.json' -print | sort | tail -1)"; test -n "$receipt" || { cat "$TMP/write-$channel.sh.out" "$TMP/write-$channel.sh.err" "$TMP/requests.log" "$TMP/server.log" >&2; fail "write $channel shell receipt"; }
    cp "$receipt" "$TMP/write-$channel.sh.receipt"
    rm -f "$ROOT/output"/write_*.json; : > "$TMP/requests.log"
    run_capture "write-$channel.php" "$TMP/state-write-$channel-php" php cli/write/write-translations.sh --channel "$channel" --idempotency-key stable "$TMP/items.json"
    receipt="$(find "$ROOT/output" -maxdepth 1 -name 'write_*.json' -print | sort | tail -1)"; test -n "$receipt" || fail "write $channel php receipt"
    cp "$receipt" "$TMP/write-$channel.php.receipt"
    compare_pair "write-$channel"
    cmp -s <(normalize < "$TMP/write-$channel.sh.receipt") <(normalize < "$TMP/write-$channel.php.receipt") || fail "write $channel receipt"
    request="$(tail -1 "$TMP/requests.log")"
    grep -Fq '"method":"POST"' <<<"$request" && grep -Fq 'translations' <<<"$request" || { cat "$TMP/requests.log" >&2; fail "write $channel POST"; }
    case "$channel" in
        machine) grep -Fq 'layer' <<<"$request" && grep -Fq 'machine' <<<"$request" && grep -Fq 'mode' <<<"$request" && grep -Fq 'direct' <<<"$request" || fail 'machine mapping' ;;
        manual) grep -Fq 'layer' <<<"$request" && grep -Fq 'manual' <<<"$request" && grep -Fq 'auto_approve' <<<"$request" && grep -Fq 'true' <<<"$request" || fail 'manual mapping' ;;
        proposal) grep -Fq 'layer' <<<"$request" && grep -Fq 'manual' <<<"$request" && grep -Fq 'auto_approve' <<<"$request" && grep -Fq 'false' <<<"$request" || fail 'proposal mapping' ;;
    esac
done

# ПРАВИЛО: без --write commit не робить POST; склад 20 rows лишається незмінним.
# САБОТАЖ: non-write POST або зміна composition валить dry-run assertion.
"$REAL_PHP" -r '$a=[];for($i=1;$i<=20;$i++){$h=str_pad((string)$i,64,"0",STR_PAD_LEFT);$a[]=["identity_hash"=>$h,"source_hash"=>"s$i","source_text"=>"Source $i"];}echo json_encode(["data"=>["rows"=>$a]],JSON_UNESCAPED_UNICODE);' > "$TMP/rows20.json"
"$REAL_PHP" -r '$a=[];for($i=1;$i<=20;$i++){$h=str_pad((string)$i,64,"0",STR_PAD_LEFT);$a[]=["identity_hash"=>$h,"text"=>"Text $i"];}echo json_encode($a,JSON_UNESCAPED_UNICODE);' > "$TMP/candidate20.json"
"$REAL_PHP" -r '$a=[];for($i=1;$i<=20;$i++){$h=str_pad((string)$i,64,"0",STR_PAD_LEFT);$a[]=["identity_hash"=>$h,"status"=>"PASS","severity"=>"none","issue"=>"","fix"=>""];}echo json_encode($a,JSON_UNESCAPED_UNICODE);' > "$TMP/verdicts20.json"
: > "$TMP/requests.log"
run_capture commit-dry.sh "$TMP/state-commit-sh" sh cli/batch/batch-commit.sh "$TMP/rows20.json" "$TMP/candidate20.json" "$TMP/verdicts20.json"
: > "$TMP/requests.log"
run_capture commit-dry.php "$TMP/state-commit-php" php cli/batch/batch-commit.sh "$TMP/rows20.json" "$TMP/candidate20.json" "$TMP/verdicts20.json"
compare_pair commit-dry
grep -Fq 'Пачка: 20 рядків' "$TMP/commit-dry.php.out" || fail 'dry-run 20 rows'
    test "$(grep -c '"method":"POST"' "$TMP/requests.log" || true)" -eq 0 || fail 'dry-run POST'

# ПРАВИЛО: no_run/env_mismatch/quota guard забороняє POST.
# САБОТАЖ: ослаблення guard дає captured POST.
for blocker in no-run env-mismatch quota; do
    printf '%s\n' "$blocker" > "$TMP/stub-mode"
    state="$TMP/state-$blocker"; mkdir -p "$state"
    [ "$blocker" = no-run ] || printf '%s\n' "$([ "$blocker" = quota ] && echo DEV || echo PROD)" > "$state/run-target"
    : > "$TMP/requests.log"
    run_capture "block-$blocker" "$state" php cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" --write
    test "$(grep -c '"method":"POST"' "$TMP/requests.log" || true)" -eq 0 || fail "$blocker POST"
done
printf 'list\n' > "$TMP/stub-mode"

# ПРАВИЛО: moderation --dry ніколи не робить POST.
# САБОТАЖ: POST у dry mode має з'явитися в request log.
: > "$TMP/requests.log"
run_capture moderation-dry "$TMP/state-moderation-dry" php cli/write/moderation-queue.sh --approve 12,15 --dry
test "$(grep -c '"method":"POST"' "$TMP/requests.log" || true)" -eq 0 || fail 'moderation dry POST'
grep -Fq '[суха]' "$TMP/moderation-dry.out" || fail 'moderation dry output'

# ПРАВИЛО: rejected API item називається фактичним count і FAIL_ON_REJECTED=1 повертає 2.
# САБОТАЖ: проковтнута відмова або неправильна межа side effects має зробити check червоним.
printf '[{"identity_hash":"reject","source_hash":"source","text":"Відхилений"}]\n' > "$TMP/rejected-items.json"
set +e
FAIL_ON_REJECTED=1 STUB_LOG="$TMP/requests.log" BDO_STATE_DIR="$TMP/state-rejected" BDO_ORCHESTRATOR=php \
    TRANSLATE_ENV_FILE="$TMP/env" bash "$ROOT/cli/write/write-translations.sh" --idempotency-key rejected "$TMP/rejected-items.json" >"$TMP/rejected.out" 2>"$TMP/rejected.err"
code=$?
set -e
test "$code" -eq 2 || fail "FAIL_ON_REJECTED code=$code"
grep -Fq 'Відкинуто: 1' "$TMP/rejected.out" || fail 'rejected count не названо'

unset FAIL_ON_REJECTED
: > "$TMP/requests.log"
run_capture rejected.sh "$TMP/state-rejected-sh" sh cli/write/write-translations.sh --idempotency-key rejected "$TMP/rejected-items.json"
: > "$TMP/requests.log"
run_capture rejected.php "$TMP/state-rejected-php" php cli/write/write-translations.sh --idempotency-key rejected "$TMP/rejected-items.json"
compare_pair rejected
for state_file in write-log.jsonl quarantine.jsonl row-attempts.jsonl; do
    test -f "$TMP/state-rejected-sh/$state_file" || fail "rejected shell $state_file"
    test -f "$TMP/state-rejected-php/$state_file" || fail "rejected php $state_file"
    cmp -s <(normalize < "$TMP/state-rejected-sh/$state_file") <(normalize < "$TMP/state-rejected-php/$state_file") || fail "rejected $state_file"
done

# ПРАВИЛО: individual moderation failure не зупиняє наступне рішення.
# САБОТАЖ: fail-fast або прихована помилка змінює stdout/stderr цього сценарію.
: > "$TMP/requests.log"
run_capture moderation-fail "$TMP/state-moderation-fail" php cli/write/moderation-queue.sh --approve 12,15
test "$(grep -c '"method":"POST"' "$TMP/requests.log" || true)" -eq 2 || fail 'moderation individual POST count'
grep -Fq '#12' "$TMP/moderation-fail.out" || fail 'успішне рішення втрачено'
grep -Fq '#15' "$TMP/moderation-fail.err" || fail 'individual failure не названо'

# ПРАВИЛО: PHP orchestration не викликає Unix helpers на жодному з трьох маршрутів.
# САБОТАЖ: fake bash/php/date/curl/grep/sed/tr/head/tail повертають 99.
mkdir -p "$TMP/no-unix"
for helper in bash php date curl grep sed tr head tail; do printf '#!/usr/bin/env bash\nexit 99\n' > "$TMP/no-unix/$helper"; chmod +x "$TMP/no-unix/$helper"; done
set +e
PATH="$TMP/no-unix" BDO_STATE_DIR="$TMP/state-no-unix" TRANSLATE_ENV_FILE="$TMP/env" "$REAL_PHP" "$ROOT/cli/bdo.php" moderation --approve 12 --dry >"$TMP/no-unix.out" 2>"$TMP/no-unix.err"
code=$?
set -e
test "$code" -eq 0 || fail "no-Unix code=$code"
PATH="$TMP/no-unix" BDO_STATE_DIR="$TMP/state-no-unix-write" TRANSLATE_ENV_FILE="$TMP/env" \
    "$REAL_PHP" "$ROOT/cli/bdo.php" write --channel machine --idempotency-key stable "$TMP/items.json" >"$TMP/no-unix-write.out" 2>"$TMP/no-unix-write.err" || fail 'no-Unix write'
PATH="$TMP/no-unix" BDO_STATE_DIR="$TMP/state-no-unix-commit" TRANSLATE_ENV_FILE="$TMP/env" \
    "$REAL_PHP" "$ROOT/cli/bdo.php" commit "$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" >"$TMP/no-unix-commit.out" 2>"$TMP/no-unix-commit.err" || fail 'no-Unix commit'

echo 'cli write parity: routing, localhost writes, 20-row dry-run, blockers, moderation dry: OK'
