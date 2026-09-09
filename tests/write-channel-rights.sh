#!/usr/bin/env bash
# Перевірити права каналів поведінкою actual write command на DEV stub.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; SERVER=''; REAL_PHP="$(command -v php)"
SOURCE_ROOT="$ROOT"
HARNESS="$TMP/repo"
mkdir -p "$HARNESS"
cp -R "$SOURCE_ROOT/cli" "$HARNESS/cli"
cp -R "$SOURCE_ROOT/lib" "$HARNESS/lib"
cp -R "$SOURCE_ROOT/config" "$HARNESS/config"
cp -R "$SOURCE_ROOT/roles" "$HARNESS/roles"
mkdir -p "$HARNESS/state" "$HARNESS/output"
ROOT="$HARNESS"
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

PORT=$((29000 + RANDOM % 500))
BASE_URL="http://127.0.0.1:$PORT"
cat > "$TMP/router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$mode = explode('/', trim($path, '/'))[0] ?? 'list';
header('Content-Type: application/json');
if (str_ends_with($path, '/me')) {
    if ($mode === 'legacy') {
        echo json_encode(['data'=>['user'=>['role'=>'super_admin'], 'effective_abilities'=>['translations:write-machine'], 'limits'=>['rows_remaining_today'=>20]]]);
    } elseif ($mode === 'deny') {
        echo json_encode(['data'=>['writes'=>['channels'=>[['layer'=>'machine','mode'=>'direct','allowed'=>false]]], 'limits'=>['rows_remaining_today'=>20]]]);
    } else {
        echo json_encode(['data'=>['writes'=>['channels'=>[
            ['layer'=>'machine','mode'=>'direct','allowed'=>true,'result'=>'machine'],
            ['layer'=>'manual','mode'=>'proposal','allowed'=>true,'result'=>'manual'],
        ]], 'limits'=>['rows_remaining_today'=>20]]]);
    }
    return;
}
if (str_ends_with($path, '/translations')) {
    echo json_encode(['data'=>['meta'=>['written'=>1,'skipped'=>0,'rejected'=>0,'rows_remaining_today'=>19], 'results'=>[['index'=>0,'status'=>'ok']]]]);
    return;
}
http_response_code(404); echo json_encode(['success'=>false]);
PHP
"$REAL_PHP" -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 & SERVER=$!
for _ in $(seq 1 30); do "$REAL_PHP" -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2);if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break; sleep .1; done
"$REAL_PHP" -r '$u=parse_url($argv[1]);exit(($u["scheme"]??"")==="http"&&($u["host"]??"")==="127.0.0.1"?0:1);' "$BASE_URL" \
    || fail 'write-channel URL не є localhost DEV'
cat > "$TMP/env" <<ENV
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test-key
ENV
printf '[{"identity_hash":"%064d","source_hash":"%064d","text":"Тест"}]\n' 1 2 > "$TMP/items.json"
run() {
    local mode="$1" state="$2" stub="$3" channel="$4"; mkdir -p "$state"
    printf '%s\n' "BDO_ENV=DEV" "BDO_API_TARGET=legacy" "BDO_API_BASE_DEV=$BASE_URL/$stub" "BDO_API_KEY_DEV=test-key" > "$TMP/env-$stub"
    TRANSLATE_ENV_FILE="$TMP/env-$stub" BDO_STATE_DIR="$state" BDO_ORCHESTRATOR="$mode" \
        bash "$ROOT/cli/write/write-translations.sh" --channel "$channel" --idempotency-key stable "$TMP/items.json"
}

# ПРАВИЛО: права шукаються в LIST за exact layer+mode, mapping не вгадується.
# САБОТАЖ: читання channels як map або вигаданий result має зробити check червоним.
for pair in 'machine machine direct' 'manual manual proposal' 'proposal manual proposal'; do
    set -- $pair
    out="$(run php "$TMP/state-$1" list "$1" 2>"$TMP/$1.err")" || fail "$1 заблоковано"
    case "$1" in
        machine) grep -Fq 'layer=machine, mode=direct, auto_approve=true' <<<"$out" || fail 'machine mapping' ;;
        manual) grep -Fq 'layer=manual, mode=proposal, auto_approve=true' <<<"$out" || fail 'manual mapping' ;;
        proposal) grep -Fq 'layer=manual, mode=proposal, auto_approve=false' <<<"$out" || fail 'proposal mapping' ;;
    esac
done
set +e; run php "$TMP/state-deny" deny machine >/dev/null 2>&1; code=$?; set -e
test "$code" -ne 0 || { fail "allowed=false прийнято: $(run php \"$TMP/state-deny-2\" deny machine 2>&1 || true)"; }

# ПРАВИЛО: legacy fallback перевіряє machine ability, manual/proposal не вигадують ability.
# САБОТАЖ: нова вимога для manual у fallback змінить фактичний exit code.
run php "$TMP/state-legacy-machine" legacy machine >/dev/null 2>&1 || fail 'legacy machine fallback'
run php "$TMP/state-legacy-manual" legacy manual >/dev/null 2>&1 || fail 'legacy manual fallback'

echo 'write channel rights: actual /me LIST, mapping and legacy fallback: OK'
