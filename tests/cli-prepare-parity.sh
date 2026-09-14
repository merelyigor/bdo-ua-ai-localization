#!/usr/bin/env bash
# Перевіряє поведінку шести prepare-команд через PHP.
#
# Усі входи локальні; єдиний HTTP-виклик memory-lookup обслуговує локальний
# php -S, бо тест не має права залежати від живого API.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER=''
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

H1="$(printf '%064d' 1)"
H2="$(printf '%064d' 2)"
H3="$(printf '%064d' 3)"
cat > "$TMP/rows.json" <<JSON
{"data":{"rows":[
 {"identity_hash":"$H1","source_hash":"a","source_text":"Iron Sword","glossary":{"terms":[{"canonical_source":"Iron","ukrainian":"Залізо"}]}},
 {"identity_hash":"$H2","source_hash":"b","source_text":"Iron Shield","glossary":{"terms":[{"canonical_source":"Shield","ukrainian":null,"severity":"mandatory"},{"evidence_kind":"probable_unresolved","matched_text":"Shield"}]}},
 {"identity_hash":"$H3","source_hash":"c","source_text":"Iron Sword"}
]}}
JSON
cat > "$TMP/memory.json" <<JSON
{"data":{"memory":{"$H1":{"variants":[{"text":"Залізний меч","layer":"manual"}]}}}}
JSON
cat > "$TMP/judge-candidate.json" <<JSON
[{"identity_hash":"$H1","text":"Iron Sword"},{"identity_hash":"$H2","text":"Залізний щит"},{"identity_hash":"$H3","text":"Залізний меч"}]
JSON
cat > "$TMP/verdicts.json" <<JSON
[{"identity_hash":"$H1","status":"PASS","severity":"none","issue":"","fix":""},{"identity_hash":"$H2","status":"REVIEW","severity":"minor","issue":"перевірити","fix":""},{"identity_hash":"$H3","status":"PASS","severity":"none","issue":"","fix":""}]
JSON
cat > "$TMP/judge-context.json" <<JSON
{"$H1":[{"en":"Iron Ore","ua":"Залізна руда"}],"$H2":[{"en":"Steel Ore","ua":"Сталева руда"}],"$H3":[{"en":"Iron Ore","ua":"Залізна руда"}]}
JSON
cat > "$TMP/expand-candidate.json" <<JSON
[{"identity_hash":"$H2","text":"Залізний щит"}]
JSON
cat > "$TMP/expand-twins.json" <<JSON
{"$H3":"$H2"}
JSON
cat > "$TMP/expand-memory.json" <<JSON
[{"identity_hash":"$H1","text":"Залізний меч"}]
JSON

ROW_KEY="$(php -r 'require $argv[1]; echo Bdo\Translate\Batch\RowSet::fromFile($argv[2])->key();' "$ROOT/lib/autoload.php" "$TMP/rows.json")"

PORT=$((25000 + RANDOM % 1000))
cat > "$TMP/router.php" <<'PHP'
<?php
if ($_SERVER['REQUEST_METHOD'] !== 'POST' || ($_SERVER['REQUEST_URI'] ?? '') !== '/translations/memory') {
    http_response_code(404);
    echo 'not-found';
    return;
}
$body = json_decode((string) file_get_contents('php://input'), true) ?: [];
$hashes = $body['identity_hashes'] ?? [];
$memory = [];
if (isset($hashes[0])) {
    $memory[$hashes[0]] = ['variants' => [['text' => 'Памʼяттю', 'layer' => 'manual']]];
}
header('Content-Type: application/json');
echo json_encode(['data' => ['memory' => $memory], 'meta' => ['requested' => count($hashes)]], JSON_UNESCAPED_UNICODE);
PHP
php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,0.2); if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break
    sleep 0.1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }
cat > "$TMP/env" <<ENV
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:$PORT
BDO_API_KEY_DEV=test
ENV
export TRANSLATE_ENV_FILE="$TMP/env"

run_one() {
    local name="$1" internal="$2" run_root="$TMP/$1-php" state_dir="$TMP/$1-php/state" resolved
    shift 2
    mkdir -p "$run_root"
    if [ "$name" = memory-apply ] || [ "$name" = judge-payload ]; then
        mkdir -p "$state_dir/batches/b"
        printf 'b\n' > "$state_dir/current-batch"
        printf '{"id":"b","identity_key":"%s","rows":3,"state":"selected"}\n' "$ROW_KEY" > "$state_dir/batches/b/manifest.json"
        if [ "$name" = judge-payload ]; then
            cp "$TMP/judge-context.json" "$state_dir/batches/b/context.json"
        fi
    fi
    local -a command_args
    command_args=()
    for argument in "$@"; do
        resolved="${argument//__RUN__/$run_root}"
        resolved="${resolved//__COMMON__/$TMP/common}"
        command_args[${#command_args[@]}]="$resolved"
    done
    set +e
    BDO_STATE_DIR="$state_dir" \
        php "$ROOT/cli/bdo.php" "$internal" ${command_args[@]+"${command_args[@]}"} \
        >"$run_root/out" 2>"$run_root/err"
    printf '%s\n' "$?" > "$run_root/code"
    set -e
}

pair() {
    local name="$1" internal="$2"
    shift 2
    run_one "$name" "$internal" "$@"
    test "$(cat "$TMP/$name-php/code")" -ge 0 || fail "$name: код виходу не записано"
}

same_file() {
    test -s "$TMP/$1-php/$2" || fail "$1: файл $2 не створено"
}

assert_schema_form() {
    php -r '$s=json_decode(file_get_contents($argv[1]),true); if(!in_array("items",$s["required"]??[],true)){fwrite(STDERR,"FAIL: схема не має items у required\n");exit(1);}' "$1"
}

pair build-schema build-schema --out __RUN__/schema.json "$TMP/rows.json"
assert_schema_form "$TMP/build-schema-php/schema.json"
pair build-schema-qa build-schema --qa --out __RUN__/schema.json "$TMP/rows.json"
assert_schema_form "$TMP/build-schema-qa-php/schema.json"
test -s "$TMP/build-schema-php/schema.json" || fail 'build-schema не створив schema.json'
test -s "$TMP/build-schema-qa-php/schema.json" || fail 'build-schema --qa не створив schema.json'

state="$TMP/clear-php/state"
mkdir -p "$state"
printf '{}\n' > "$state/current-response-schema.json"
printf '{}\n' > "$state/current-qa-schema.json"
printf 'зберегти\n' > "$state/sentinel.txt"
BDO_STATE_DIR="$state" php "$ROOT/cli/bdo.php" build-schema --clear >"$TMP/clear-php.out" 2>"$TMP/clear-php.err" || fail 'build-schema --clear впав'
test ! -e "$state/current-response-schema.json" && test ! -e "$state/current-qa-schema.json" || fail '--clear не зняв обидві схеми'
test -f "$state/sentinel.txt" || fail '--clear видалив зайвий файл'

pair memory-apply memory-apply "$TMP/rows.json" "$TMP/memory.json"
same_file memory-apply state/batches/b/memory-candidate.json
same_file memory-apply state/batches/b/to-translate.json
same_file memory-apply state/batches/b/twins.json

pair judge-payload judge-payload "$TMP/rows.json" "$TMP/judge-candidate.json" "$TMP/verdicts.json"
pair glossary-gaps glossary-gaps "$TMP/rows.json"
pair memory-lookup memory-lookup "$TMP/rows.json" __RUN__/memory.json
same_file memory-lookup memory.json
pair memory-expand memory-expand "$TMP/expand-candidate.json" "$TMP/expand-twins.json" "$TMP/expand-memory.json"

test "$(jq -r '.items | length' "$TMP/judge-payload-php/out")" -eq 2 || fail 'judge-payload не зібрав спірні рядки'
test "$(jq -r '.data.memory | length' "$TMP/memory-lookup-php/memory.json")" -eq 1 || fail 'memory-lookup не зберіг відповідь stub'
printf '%s\n' 'cli prepare behavior: 6 PHP-команд, stdout/stderr/коди й файли: OK'
