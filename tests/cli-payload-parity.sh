#!/usr/bin/env bash
# Доводить байтову парність чотирьох payload-будівників між shell і PHP.
# Контекст і resolve обслуговує лише локальний stub; живий API сюди не входить.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER=''
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

H1="$(printf '%064d' 1)"
H2="$(printf '%064d' 2)"
cat > "$TMP/rows.json" <<JSON
{"data":{"rows":[
 {"identity_hash":"$H1","source_text":"Cheongsa Island and Iron Sword","classification":{"domain":"item","semantic_type":"name"},"glossary":{"terms":[{"canonical_source":"Iron","ukrainian":"Залізо","ukrainian_layer":"manual"}]}},
 {"identity_hash":"$H2","source_text":"Unknown Shield","classification":{"domain":"item","semantic_type":"name"},"glossary":{"terms":[{"canonical_source":"Shield","ukrainian":null,"severity":"mandatory"},{"evidence_kind":"probable_unresolved","matched_text":"Shield"}]},"layers":{"machine":{"text":"Старий щит"}}}
]}}
JSON
cat > "$TMP/candidate.json" <<JSON
[{"identity_hash":"$H1","text":"Острів Ліхтарів і Залізний меч"},{"identity_hash":"$H2","text":"Невідомий щит"}]
JSON
cat > "$TMP/validate.json" <<JSON
{"success":true,"data":{"results":[{"identity_hash":"$H1","status":"rejected","code":"glossary_violation","details":{"glossary":[{"expected":"Залізний меч","canonical":"Iron"}]}},{"identity_hash":"$H2","status":"rejected","code":"markup"}]}}
JSON

PORT=$((27000 + RANDOM % 1000))
cat > "$TMP/router.php" <<'PHP'
<?php
$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
header('Content-Type: application/json');
if ($path === '/me') { echo json_encode(['success' => true, 'data' => ['batch' => ['max_context_rows' => 1]]]); return; }
if ($path === '/rows/context') {
    $body = json_decode((string) file_get_contents('php://input'), true) ?: [];
    $contexts = [];
    foreach ($body['identity_hashes'] ?? [] as $hash) {
        $contexts[$hash] = ['related_rows' => [['source_text' => 'Cheongsa Island', 'translation' => ['text' => 'Чхонса']]], 'terms' => [
            ['canonical_source' => 'Cheongsa Island', 'ukrainian' => 'Острів Ліхтарів', 'ukrainian_layer' => 'manual', 'policy' => 'mandatory', 'severity' => 'mandatory', 'definition' => 'острів'],
        ]];
    }
    echo json_encode(['success' => true, 'data' => ['contexts' => $contexts]], JSON_UNESCAPED_UNICODE); return;
}
if ($path === '/glossary/terms/resolve') { echo json_encode(['success' => true, 'data' => ['resolution' => ['status' => 'ready', 'candidate' => ['term_id' => 'local']]]]); return; }
http_response_code(404); echo json_encode(['success' => false, 'error' => ['code' => 'not_found']]);
PHP
php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);}exit(1);' "$PORT" && break
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

run_one() {
    local name="$1" orchestrator="$2" script="$3" root="$TMP/$1-$2" state="$TMP/$1-$2/state"
    shift 3
    mkdir -p "$root" "$state/batches/b"
    printf 'b\n' > "$state/current-batch"
    printf '{"id":"b","identity_key":"x","rows":2,"state":"selected"}\n' > "$state/batches/b/manifest.json"
    if [ "$name" = qa ]; then
        cp "$TMP/worker-sh/state/batches/b/context.json" "$state/batches/b/context.json"
        cp "$TMP/worker-sh/state/batches/b/terms.json" "$state/batches/b/terms.json"
    fi
    if [ "$name" = worker ] || [ "$name" = worker-suspect ]; then
        if [ "$name" = worker-suspect ]; then
            printf '{"terms":{"Cheongsa Island":{"withhold":true}}}\n' > "$state/glossary-suspects.json"
        else
            printf '{"terms":{"Iron":{"withhold":false}}}\n' > "$state/glossary-suspects.json"
        fi
    fi
    local -a args=()
    local value
    for value in "$@"; do
        value="${value//__ROOT__/$root}"
        args[${#args[@]}]="$value"
    done
    set +e
    BDO_ORCHESTRATOR="$orchestrator" BDO_STATE_DIR="$state" bash "$ROOT/$script" ${args[@]+"${args[@]}"} >"$root/out" 2>"$root/err"
    printf '%s\n' "$?" > "$root/code"
    set -e
}

pair() {
    local name="$1" script="$2"; shift 2
    run_one "$name" sh "$script" "$@"
    run_one "$name" php "$script" "$@"
    for channel in out err code; do
        sed -e "s|$TMP/$name-sh|RUN|g" -e "s|$TMP/$name-php|RUN|g" "$TMP/$name-sh/$channel" > "$TMP/$name-sh/$channel.normalized"
        sed -e "s|$TMP/$name-sh|RUN|g" -e "s|$TMP/$name-php|RUN|g" "$TMP/$name-php/$channel" > "$TMP/$name-php/$channel.normalized"
        cmp -s "$TMP/$name-sh/$channel.normalized" "$TMP/$name-php/$channel.normalized" || { diff -u "$TMP/$name-sh/$channel.normalized" "$TMP/$name-php/$channel.normalized" >&2 || true; fail "$name: $channel не збігається"; }
    done
}

pair worker cli/prepare/worker-payload.sh "$TMP/rows.json" --with-context
cmp -s "$TMP/worker-sh/state/batches/b/context.json" "$TMP/worker-php/state/batches/b/context.json" || fail 'worker: context.json не збігається'
cmp -s "$TMP/worker-sh/state/batches/b/terms.json" "$TMP/worker-php/state/batches/b/terms.json" || fail 'worker: terms.json не збігається'
grep -Fq 'Приклади: відкинуто 2' "$TMP/worker-php/err" || fail 'worker: не названо відкинуті приклади'
grep -Fq 'ukrainian_layer' "$TMP/worker-php/state/batches/b/terms.json" || fail 'worker: немає походження терміна'
run_one worker-suspect php cli/prepare/worker-payload.sh "$TMP/rows.json" --with-context
test "$(jq -c '.terms // []' "$TMP/worker-suspect-php/out")" = '[]' || fail 'worker: підозрілий термін не пропущено'
grep -Fq 'Терміни під підозрою пропущено' "$TMP/worker-suspect-php/err" || fail 'worker: пропуск підозрілого терміна не названо'

pair qa cli/prepare/qa-payload.sh "$TMP/rows.json" "$TMP/candidate.json" --with-current
grep -Fq '"current":"Старий щит"' "$TMP/qa-php/out" || fail 'qa: поточний переклад не потрапив у payload'

pair terminology cli/prepare/terminology-payload.sh "$TMP/rows.json" --no-resolve
if grep -Fq 'source_identity' "$TMP/terminology-php/out"; then fail 'terminology: payload містить source_identity'; fi

pair names cli/prepare/names-payload.sh "$TMP/rows.json" "$TMP/candidate.json" "$TMP/validate.json"
grep -Fq 'ужий' "$TMP/names-php/out" || fail 'names: наказ не зібрано'

printf '%s\n' 'cli payload parity: 4 команди, stdout/stderr/коди й файли: OK'
