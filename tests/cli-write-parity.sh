#!/usr/bin/env bash
# Довести парність write/commit/moderation між rollback shell і PHP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
TMP_REAL="$(cd "$TMP" && pwd -P)"
SERVER=''
REAL_PHP="$(command -v php)"
SOURCE_ROOT="$ROOT"
HARNESS="$TMP/repo"
mkdir -p "$HARNESS"
cp -R "$SOURCE_ROOT/cli" "$HARNESS/cli"
cp -R "$SOURCE_ROOT/lib" "$HARNESS/lib"
cp -R "$SOURCE_ROOT/config" "$HARNESS/config"
cp -R "$SOURCE_ROOT/roles" "$HARNESS/roles"
mkdir -p "$HARNESS/state" "$HARNESS/output"
ROOT="$HARNESS"
HARNESS_OUTPUT="$ROOT/${HARNESS_OUTPUT_DIR:-output}"
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true; rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ПРАВИЛО: routing proof працює на synthetic DEV env, а не читає production `.env`.
# САБОТАЖ: відсутній dispatcher не має дістатися до реального target або ключа.
PORT=$((28000 + RANDOM % 1000))
BASE_URL="http://127.0.0.1:$PORT"
cat > "$TMP/env" <<ENV
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=$BASE_URL
BDO_API_KEY_DEV=test-key
ENV
export TRANSLATE_ENV_FILE="$TMP/env"
# ПРАВИЛО: кожен можливий POST у тесті дозволений лише до http://127.0.0.1.
# САБОТАЖ: зміна scheme або host мусить зупинити тест до першого write.
"$REAL_PHP" -r '$u=parse_url($argv[1]);exit(($u["scheme"]??"")==="http"&&($u["host"]??"")==="127.0.0.1"?0:1);' "$BASE_URL" \
    || fail 'write-test URL не є localhost DEV'

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

printf 'list\n' > "$TMP/stub-mode"
cat > "$TMP/router.php" <<'PHP'
<?php
$uri = (string) ($_SERVER['REQUEST_URI'] ?? '/');
$path = (string) parse_url($uri, PHP_URL_PATH);
$log = (string) getenv('STUB_LOG');
$body = (string) file_get_contents('php://input');
$stubMode = trim((string) @file_get_contents((string) getenv('STUB_MODE_FILE')));
$remaining = $stubMode === 'quota' ? 0 : 100;
$headers = [];
foreach (getallheaders() ?: [] as $name => $value) {
    $lower = strtolower($name);
    if (in_array($lower, ['content-type', 'idempotency-key'], true)) $headers[$lower] = $value;
}
ksort($headers);
file_put_contents($log, json_encode(['method'=>$_SERVER['REQUEST_METHOD'] ?? '', 'path'=>$uri, 'headers'=>$headers, 'body'=>$body], JSON_UNESCAPED_UNICODE)."\n", FILE_APPEND);
header('Content-Type: application/json');
if ($path === '/me') {
    $data = ['user'=>['role'=>'super_admin'], 'effective_abilities'=>['translations:write-machine'], 'limits'=>['rows_remaining_today'=>$remaining]];
    if ($stubMode === 'legacy') {
        echo json_encode(['data'=>$data], JSON_UNESCAPED_UNICODE);
    } else {
        $data['writes'] = ['channels'=>[
            ['layer'=>'machine','mode'=>'direct','allowed'=>true,'result'=>'machine'],
            ['layer'=>'manual','mode'=>'proposal','allowed'=>true,'result'=>'manual'],
        ]];
        echo json_encode(['data'=>$data], JSON_UNESCAPED_UNICODE);
    }
    return;
}
if ($path === '/translations') {
    $request = json_decode($body, true) ?: [];
    $items = is_array($request['items'] ?? null) ? $request['items'] : [];
    $results = [];
    foreach ($items as $index => $item) $results[] = ['index'=>$index, 'identity_hash'=>$item['identity_hash'] ?? '', 'status'=>'ok'];
    $rejected = (($items[0]['identity_hash'] ?? '') === 'reject') ? 1 : 0;
    if ($rejected > 0) $results = [['index'=>0, 'identity_hash'=>'reject', 'status'=>'rejected', 'code'=>'invalid', 'message'=>'відхилено']];
    $meta = ['layer'=>$request['layer'] ?? '', 'mode'=>$request['mode'] ?? '', 'auto_approve'=>$request['auto_approve'] ?? false, 'items'=>count($items), 'written'=>count($items)-$rejected, 'skipped'=>0, 'rejected'=>$rejected, 'rows_remaining_today'=>$remaining-count($items)];
    if ($stubMode === 'no-meta') unset($meta['layer'], $meta['mode'], $meta['auto_approve']);
    echo json_encode(['data'=>['meta'=>$meta, 'results'=>$results]], JSON_UNESCAPED_UNICODE);
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
STUB_LOG="$TMP/requests.log" STUB_MODE_FILE="$TMP/stub-mode" "$REAL_PHP" -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    "$REAL_PHP" -r '$s=@fsockopen("127.0.0.1",(int)$argv[1],$e,$m,.2); if(is_resource($s)){fclose($s);exit(0);} exit(1);' "$PORT" && break
    sleep .1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }
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
    sed -E -e "s|$TMP_REAL/state-[^ ]+|STATE|g" -e "s|$TMP/state-[^ ]+|STATE|g" -e "s|$TMP_REAL|TMP|g" -e "s|$TMP|TMP|g" -e 's|write_[0-9]{8}_[0-9]{6}\.json|write_TIMESTAMP.json|g' -e 's/"at":"[^"]+"/"at":"TIME"/g' -e 's/"at": "[^"]+"/"at": "TIME"/g' -e 's|(Карантин:[^()]*)\([[:space:]]+([0-9]+ рядків усього\))|\1(\2|g'
}

# ПРАВИЛО: normalizer прибирає лише власні шляхи, timestamps і legacy padding.
# САБОТАЖ: зміна identity, channel, reason або numeric count мусить залишитись видимою.
normalizer_self_test() {
    local padded='Карантин: STATE (       0 рядків усього)'
    local plain='Карантин: STATE (0 рядків усього)'
    cmp -s <(normalize <<<"$padded") <(normalize <<<"$plain") || fail 'normalizer не прибирає лише legacy padding'
    test "$(normalize <<<"Карантин: A (0 рядків усього) reason=x")" != "$(normalize <<<"Карантин: B (0 рядків усього) reason=x")" || fail 'normalizer сховав identity'
    test "$(normalize <<<"Карантин: A (0 рядків усього) channel=x")" != "$(normalize <<<"Карантин: A (0 рядків усього) channel=y")" || fail 'normalizer сховав channel'
    test "$(normalize <<<"Карантин: A (0 рядків усього) reason=x")" != "$(normalize <<<"Карантин: A (0 рядків усього) reason=y")" || fail 'normalizer сховав reason'
    test "$(normalize <<<"Карантин: A (0 рядків усього)")" != "$(normalize <<<"Карантин: A (1 рядків усього)")" || fail 'normalizer сховав count'
}
normalizer_self_test
run_capture() {
    local label="$1" state="$2" orchestrator="$3" script="$4"; shift 4
    mkdir -p "$state"
    : > "$TMP/requests.log"
    set +e
    STUB_LOG="$TMP/requests.log" BDO_STATE_DIR="$state" BDO_ORCHESTRATOR="$orchestrator" bash "$ROOT/$script" "$@" >"$TMP/$label.out" 2>"$TMP/$label.err"
    printf '%s\n' "$?" > "$TMP/$label.code"
    cp "$TMP/requests.log" "$TMP/$label.log"
    set -e
}
compare_pair() {
    local name="$1"
    cmp -s <(normalize < "$TMP/$name.sh.out") <(normalize < "$TMP/$name.php.out") || { diff -u <(normalize < "$TMP/$name.sh.out") <(normalize < "$TMP/$name.php.out") >&2 || true; fail "$name stdout"; }
    cmp -s <(normalize < "$TMP/$name.sh.err") <(normalize < "$TMP/$name.php.err") || { diff -u <(normalize < "$TMP/$name.sh.err") <(normalize < "$TMP/$name.php.err") >&2 || true; fail "$name stderr"; }
    cmp -s "$TMP/$name.sh.code" "$TMP/$name.php.code" || fail "$name code"
    cmp -s "$TMP/$name.sh.log" "$TMP/$name.php.log" || { diff -u "$TMP/$name.sh.log" "$TMP/$name.php.log" >&2 || true; fail "$name request log"; }
}

# ПРАВИЛО: channel mapping і LIST data.writes.channels є source of truth.
# САБОТАЖ: інша форма body/mapping мусить змінити captured request.
for channel in machine manual proposal; do
    printf 'list\n' > "$TMP/stub-mode"
    find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete; : > "$TMP/requests.log"
    run_capture "write-$channel.sh" "$TMP/state-write-$channel-sh" sh cli/write/write-translations.sh --channel "$channel" --idempotency-key stable "$TMP/items.json"
    receipt="$(find "$HARNESS_OUTPUT" -maxdepth 1 -name 'write_*.json' -print | sort | tail -1)"; test -n "$receipt" || { cat "$TMP/write-$channel.sh.out" "$TMP/write-$channel.sh.err" "$TMP/requests.log" "$TMP/server.log" >&2; fail "write $channel shell receipt"; }
    cp "$receipt" "$TMP/write-$channel.sh.receipt"
    find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete; : > "$TMP/requests.log"
    run_capture "write-$channel.php" "$TMP/state-write-$channel-php" php cli/write/write-translations.sh --channel "$channel" --idempotency-key stable "$TMP/items.json"
    receipt="$(find "$HARNESS_OUTPUT" -maxdepth 1 -name 'write_*.json' -print | sort | tail -1)"; test -n "$receipt" || fail "write $channel php receipt"
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
    test -f "$TMP/state-write-$channel-sh/write-log.jsonl" || fail "write $channel shell write-log"
    test -f "$TMP/state-write-$channel-php/write-log.jsonl" || fail "write $channel php write-log"
    cmp -s <(normalize < "$TMP/state-write-$channel-sh/write-log.jsonl") <(normalize < "$TMP/state-write-$channel-php/write-log.jsonl") || fail "write $channel write-log"
done

# ПРАВИЛО: legacy /me fallback має бути паритетним для кожного channel.
# САБОТАЖ: PHP вимагатиме data.writes або змінить fallback mapping — shell/PHP red.
for channel in machine manual proposal; do
    printf 'legacy\n' > "$TMP/stub-mode"
    find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
    run_capture "legacy-$channel.sh" "$TMP/state-legacy-$channel-sh" sh cli/write/write-translations.sh --channel "$channel" --idempotency-key stable "$TMP/items.json"
    find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
    run_capture "legacy-$channel.php" "$TMP/state-legacy-$channel-php" php cli/write/write-translations.sh --channel "$channel" --idempotency-key stable "$TMP/items.json"
    compare_pair "legacy-$channel"
done
printf 'list\n' > "$TMP/stub-mode"

# ПРАВИЛО: candidate безпосередньо в output/benchmark не є перекладом і
# відхиляється до ApiEnvironment та будь-якого HTTP-запиту.
# САБОТАЖ: вилучення benchmark preflight має дати code 1 і captured POST 0.
mkdir -p "$HARNESS_OUTPUT/benchmark"
cp "$TMP/candidate.json" "$HARNESS_OUTPUT/benchmark/candidate.json"
run_capture benchmark "$TMP/state-benchmark" php cli/batch/batch-commit.sh \
    "$TMP/rows.json" "$HARNESS_OUTPUT/benchmark/candidate.json" "$TMP/verdicts.json" --write
test "$(cat "$TMP/benchmark.code")" -eq 1 || fail 'benchmark candidate прийнято'
grep -Fq 'Це файл виміру (output/benchmark/), а не переклад. Записувати його не можна.' "$TMP/benchmark.err" \
    || fail 'benchmark guard не назвав причину'
test ! -s "$TMP/benchmark.log" || fail 'benchmark guard зробив HTTP-запит'
rm -f "$HARNESS_OUTPUT/benchmark/candidate.json"

# ПРАВИЛО: required option values відхиляються так само до API, як shell ${2:?}.
# САБОТАЖ: прийняте missing/empty значення дає safety-sensitive шлях без парності.
for spec in \
    'write-channel cli/write/write-translations.sh --channel' \
    'write-key cli/write/write-translations.sh --idempotency-key' \
    'commit-channel cli/batch/batch-commit.sh --channel' \
    'commit-prefix cli/batch/batch-commit.sh --idempotency-key-prefix' \
    'commit-judge cli/batch/batch-commit.sh --judge' \
    'commit-api-rejected cli/batch/batch-commit.sh --api-rejected' \
    'moderation-limit cli/write/moderation-queue.sh --limit' \
    'moderation-row cli/write/moderation-queue.sh --row' \
    'moderation-approve cli/write/moderation-queue.sh --approve' \
    'moderation-reject cli/write/moderation-queue.sh --reject' \
    'moderation-reason cli/write/moderation-queue.sh --reason' \
    'moderation-batch cli/write/moderation-queue.sh --approve-batch'; do
    read -r name script option <<<"$spec"
    case "$name" in
        write-*) args=("$option") ;;
        commit-*) args=("$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" "$option") ;;
        moderation-*) args=("$option") ;;
    esac
    for form in missing empty; do
        if test "$form" = empty; then args+=(""); fi
        run_capture "required-$name-$form.sh" "$TMP/state-required-$name-$form-sh" sh "$script" "${args[@]+"${args[@]}"}"
        run_capture "required-$name-$form.php" "$TMP/state-required-$name-$form-php" php "$script" "${args[@]+"${args[@]}"}"
        test "$(cat "$TMP/required-$name-$form.sh.code")" -ne 0 || fail "required $name $form shell прийнято"
        test "$(cat "$TMP/required-$name-$form.php.code")" -eq "$(cat "$TMP/required-$name-$form.sh.code")" || fail "required $name $form code"
        test -s "$TMP/required-$name-$form.sh.err" || fail "required $name $form shell без причини"
        test -s "$TMP/required-$name-$form.php.err" || fail "required $name $form PHP без причини"
        if test "$name" = write-key; then
            grep -Fq 'idempotency-key' "$TMP/required-$name-$form.sh.err" || fail "required $name $form shell без назви option"
            grep -Fq 'idempotency-key' "$TMP/required-$name-$form.php.err" || fail "required $name $form PHP без назви option"
        fi
        test ! -s "$TMP/required-$name-$form.php.log" || fail "required $name $form зробив POST/HTTP"
        if test "$form" = empty; then args=("${args[@]:0:${#args[@]}-1}"); fi
    done
done

# ПРАВИЛО: response meta є єдиним джерелом audit facts; відсутні layer/mode/
# auto_approve лишаються null, а не підміняються request intent.
# САБОТАЖ: fallback у TranslationWriter має розійтися на missing-meta fixture.
printf 'no-meta\n' > "$TMP/stub-mode"
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture no-meta.sh "$TMP/state-no-meta-sh" sh cli/write/write-translations.sh --channel machine --idempotency-key stable "$TMP/items.json"
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture no-meta.php "$TMP/state-no-meta-php" php cli/write/write-translations.sh --channel machine --idempotency-key stable "$TMP/items.json"
compare_pair no-meta
grep -Fq '"layer":null' "$TMP/state-no-meta-php/write-log.jsonl" || fail 'missing layer не став null'
grep -Fq '"mode":null' "$TMP/state-no-meta-php/write-log.jsonl" || fail 'missing mode не став null'
grep -Fq '"auto_approve":null' "$TMP/state-no-meta-php/write-log.jsonl" || fail 'missing auto_approve не став null'
printf 'list\n' > "$TMP/stub-mode"

# ПРАВИЛО: current workspace визначає receipt provenance і summary location;
# route без slash має provider=model=route.
# САБОТАЖ: candidate-directory receipt або provider-only split мають змінити
# captured payload і місце batch-summary.
make_current_workspace() {
    local state="$1" route="$2" id="$3"
    mkdir -p "$state/batches/$id"
    printf '%s\n' "$id" > "$state/current-batch"
    printf '{"route":"%s"}\n' "$route" > "$state/batches/$id/candidate.json.session.json"
    printf '{"id":"%s","identity_key":"fixture","rows":1}\n' "$id" > "$state/batches/$id/manifest.json"
    printf 'local\n' > "$state/run-target"
}
mkdir -p "$TMP/candidate-dir"
cp "$TMP/candidate.json" "$TMP/candidate-dir/candidate.json"
printf '{"route":"wrong-provider/wrong-model"}\n' > "$TMP/candidate-dir/candidate.json.session.json"
make_current_workspace "$TMP/state-current-sh" 'fixture-provider/fixture-model' current-sh
make_current_workspace "$TMP/state-current-php" 'fixture-provider/fixture-model' current-php
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture current-write.sh "$TMP/state-current-sh" sh cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate-dir/candidate.json" "$TMP/verdicts.json" --write --idempotency-key-prefix current
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture current-write.php "$TMP/state-current-php" php cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate-dir/candidate.json" "$TMP/verdicts.json" --write --idempotency-key-prefix current
compare_pair current-write
test -f "$TMP/state-current-sh/batches/current-sh/batch-summary.json" || fail 'shell summary не в current workspace'
test -f "$TMP/state-current-php/batches/current-php/batch-summary.json" || fail 'PHP summary не в current workspace'
cmp -s "$TMP/state-current-sh/batches/current-sh/batch-summary.json" "$TMP/state-current-php/batches/current-php/batch-summary.json" || fail 'current summary розійшовся'
grep -Fq 'fixture-provider' "$TMP/current-write.php.log" || { cat "$TMP/current-write.php.out" "$TMP/current-write.php.err" "$TMP/current-write.php.log" >&2; fail 'current receipt route не використано'; }
grep -Fq 'fixture-model' "$TMP/current-write.php.log" || { cat "$TMP/current-write.php.out" "$TMP/current-write.php.err" "$TMP/current-write.php.log" >&2; fail 'current model provenance не використано'; }
make_current_workspace "$TMP/state-bare-sh" 'bare-route' bare-sh
make_current_workspace "$TMP/state-bare-php" 'bare-route' bare-php
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture bare-route.sh "$TMP/state-bare-sh" sh cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate-dir/candidate.json" "$TMP/verdicts.json" --write --idempotency-key-prefix bare
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture bare-route.php "$TMP/state-bare-php" php cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate-dir/candidate.json" "$TMP/verdicts.json" --write --idempotency-key-prefix bare
compare_pair bare-route
grep -Fq '\"provider\":\"bare-route\"' "$TMP/bare-route.php.log" || fail 'bare route provider'
grep -Fq '\"model\":\"bare-route\"' "$TMP/bare-route.php.log" || fail 'bare route model'

# ПРАВИЛО: config fallback формує legacy route ollama/<model>; summary і receipt
# походять із current workspace, навіть якщо candidate directory має чужий receipt.
# САБОТАЖ: bare config model або candidate-directory provenance змінює write request.
CONFIG_MODEL="$($REAL_PHP -r '$c=json_decode(file_get_contents($argv[1]),true);echo $c["roles"]["translation-worker"]["model"]??$c["default_model"]??"";' "$HARNESS/config/roles.json")"
make_current_workspace "$TMP/state-config-sh" '' config-sh
make_current_workspace "$TMP/state-config-php" '' config-php
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture config-fallback.sh "$TMP/state-config-sh" sh cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate-dir/candidate.json" "$TMP/verdicts.json" --write --idempotency-key-prefix config
find "$HARNESS_OUTPUT" -maxdepth 1 -type f -name 'write_*.json' -delete
run_capture config-fallback.php "$TMP/state-config-php" php cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate-dir/candidate.json" "$TMP/verdicts.json" --write --idempotency-key-prefix config
compare_pair config-fallback
grep -Fq '\"provider\":\"ollama\"' "$TMP/config-fallback.php.log" || fail 'config fallback provider'
grep -Fq "\\\"model\\\":\\\"$CONFIG_MODEL\\\"" "$TMP/config-fallback.php.log" || fail 'config fallback model'
test -f "$TMP/state-config-sh/batches/config-sh/batch-summary.json" || fail 'config shell summary location'
test -f "$TMP/state-config-php/batches/config-php/batch-summary.json" || fail 'config PHP summary location'

# ПРАВИЛО: moderation list/json/dry/approve/reject/batch мають однакові HTTP,
# output і individual-failure semantics на shell та PHP.
# САБОТАЖ: fail-fast або змінений method/path/body має зробити differential red.
for spec in \
    'list --limit 2' \
    'json --limit 2 --json' \
    'approve-dry --approve 12,15 --dry' \
    'reject-dry --reject 12,15 --reason причина --dry' \
    'approve --approve 12' \
    'reject --reject 12 --reason причина' \
    'batch --approve-batch 2'; do
    read -r name rest <<<"$spec"
    # shell word splitting тут навмисне відтворює argv тестової матриці, не JSON/body.
    read -r -a args <<<"$rest"
    : > "$TMP/requests.log"
    run_capture "moderation-$name.sh" "$TMP/state-moderation-$name-sh" sh cli/write/moderation-queue.sh "${args[@]+"${args[@]}"}"
    : > "$TMP/requests.log"
    run_capture "moderation-$name.php" "$TMP/state-moderation-$name-php" php cli/write/moderation-queue.sh "${args[@]+"${args[@]}"}"
    compare_pair "moderation-$name"
done
printf 'list\n' > "$TMP/stub-mode"

# ПРАВИЛО: без --write commit не робить POST; склад 20 rows лишається незмінним.
# САБОТАЖ: non-write POST або зміна composition валить dry-run assertion.
"$REAL_PHP" -r '$a=[];for($i=1;$i<=20;$i++){$h=str_pad((string)$i,64,"0",STR_PAD_LEFT);$a[]=["identity_hash"=>$h,"source_hash"=>"s$i","source_text"=>"Source $i"];}echo json_encode(["data"=>["rows"=>$a]],JSON_UNESCAPED_UNICODE);' > "$TMP/rows20.json"
"$REAL_PHP" -r '$a=[];for($i=1;$i<=20;$i++){$h=str_pad((string)$i,64,"0",STR_PAD_LEFT);$a[]=["identity_hash"=>$h,"text"=>"Text $i"];}echo json_encode($a,JSON_UNESCAPED_UNICODE);' > "$TMP/candidate20.json"
"$REAL_PHP" -r '$a=[];for($i=1;$i<=20;$i++){$h=str_pad((string)$i,64,"0",STR_PAD_LEFT);$status=$i<=10?"PASS":($i<=15?"REVIEW":($i<=18?"REVIEW":"REJECT"));$severity=($i>=11&&$i<=15)?"major":(($i>=16&&$i<=18)?"minor":"none");$a[]=["identity_hash"=>$h,"status"=>$status,"severity"=>$severity,"issue"=>"","fix"=>""];}echo json_encode($a,JSON_UNESCAPED_UNICODE);' > "$TMP/verdicts20.json"
: > "$TMP/requests.log"
run_capture commit-dry.sh "$TMP/state-commit-sh" sh cli/batch/batch-commit.sh "$TMP/rows20.json" "$TMP/candidate20.json" "$TMP/verdicts20.json" --channel manual
: > "$TMP/requests.log"
run_capture commit-dry.php "$TMP/state-commit-php" php cli/batch/batch-commit.sh "$TMP/rows20.json" "$TMP/candidate20.json" "$TMP/verdicts20.json" --channel manual
compare_pair commit-dry
grep -Fq 'Пачка: 20 рядків' "$TMP/commit-dry.php.out" || fail 'dry-run 20 rows'
grep -Fq 'До запису: 13 | у модерацію: 7 (з них нерозпізнані назви: 0) | у карантин (збої): 0' "$TMP/commit-dry.php.out" || fail 'dry-run mixed composition'
if grep -Eq 'Карантин:[^()]*\([[:space:]]+[0-9]+ рядків усього\)' "$TMP/commit-dry.php.out"; then
    fail 'PHP quarantine count має бути без legacy padding'
fi
test "$(grep -c '"method":"POST"' "$TMP/commit-dry.php.log" || true)" -eq 0 || fail 'dry-run POST'

# ПРАВИЛО: no_run/env_mismatch/quota guard забороняє POST.
# САБОТАЖ: ослаблення guard дає captured POST.
for blocker in no-run env-mismatch quota; do
    printf '%s\n' "$blocker" > "$TMP/stub-mode"
    state="$TMP/state-$blocker"; mkdir -p "$state"
    [ "$blocker" = no-run ] || printf '%s\n' "$([ "$blocker" = quota ] && echo local || echo PROD)" > "$state/run-target"
    : > "$TMP/requests.log"
    run_capture "block-$blocker" "$state" php cli/batch/batch-commit.sh "$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" --write
    test "$(grep -c '"method":"POST"' "$TMP/requests.log" || true)" -eq 0 || fail "$blocker POST"
    if test "$blocker" = quota; then
        grep -Fq 'quota:' "$TMP/block-quota.out" || fail 'quota branch не названа'
    fi
done
printf 'list\n' > "$TMP/stub-mode"

# ПРАВИЛО: operational blocker переносить у held і PASS, і proposal; жоден рядок
# не доходить до writer і не отримує RowAttempts.
# САБОТАЖ: fixture лише з PASS фальсифікує safety proof і пропускає proposal POST.
BLOCK_H1="$(printf '%064d' 41)"
BLOCK_H2="$(printf '%064d' 42)"
cat > "$TMP/blocker-rows.json" <<JSON
{"data":{"rows":[{"identity_hash":"$BLOCK_H1","source_hash":"block-source-1","source_text":"Block source 1"},{"identity_hash":"$BLOCK_H2","source_hash":"block-source-2","source_text":"Block source 2"}]}}
JSON
printf '[{"identity_hash":"%s","text":"Block translation 1"},{"identity_hash":"%s","text":"Block translation 2"}]\n' "$BLOCK_H1" "$BLOCK_H2" > "$TMP/blocker-candidate.json"
printf '[{"identity_hash":"%s","status":"PASS","severity":"none","issue":"","fix":""},{"identity_hash":"%s","status":"REVIEW","severity":"major","issue":"blocker review","fix":""}]\n' "$BLOCK_H1" "$BLOCK_H2" > "$TMP/blocker-verdicts.json"
for blocker in no-run env-mismatch quota; do
    printf '%s\n' "$blocker" > "$TMP/stub-mode"
    state_sh="$TMP/state-mixed-$blocker-sh"; state_php="$TMP/state-mixed-$blocker-php"
    mkdir -p "$state_sh" "$state_php"
    if test "$blocker" = env-mismatch; then
        printf 'PROD\n' > "$state_sh/run-target"
        printf 'PROD\n' > "$state_php/run-target"
    elif test "$blocker" = quota; then
        printf 'local\n' > "$state_sh/run-target"
        printf 'local\n' > "$state_php/run-target"
    fi
    for side in sh php; do
        state_side="$TMP/state-mixed-$blocker-$side"
        mkdir -p "$state_side/batches/mixed-$blocker-$side"
        printf 'mixed-%s-%s\n' "$blocker" "$side" > "$state_side/current-batch"
        printf '{"id":"mixed-%s-%s","identity_key":"mixed","rows":2}\n' "$blocker" "$side" > "$state_side/batches/mixed-$blocker-$side/manifest.json"
    done
    : > "$TMP/requests.log"
    run_capture "mixed-$blocker.sh" "$state_sh" sh cli/batch/batch-commit.sh "$TMP/blocker-rows.json" "$TMP/blocker-candidate.json" "$TMP/blocker-verdicts.json" --write --channel manual
    : > "$TMP/requests.log"
    run_capture "mixed-$blocker.php" "$state_php" php cli/batch/batch-commit.sh "$TMP/blocker-rows.json" "$TMP/blocker-candidate.json" "$TMP/blocker-verdicts.json" --write --channel manual
    compare_pair "mixed-$blocker"
    test "$(grep -c '"method":"POST"' "$TMP/mixed-$blocker.sh.log" || true)" -eq 0 || fail "mixed $blocker shell POST"
    test "$(grep -c '"method":"POST"' "$TMP/mixed-$blocker.php.log" || true)" -eq 0 || fail "mixed $blocker PHP POST"
    case "$blocker" in
        no-run) expected_reason='no_run:запусти cli/run/run-start.sh' ;;
        quota) expected_reason='quota:0_left' ;;
        *) expected_reason='env_mismatch:прогін=PROD,команда=local' ;;
    esac
    grep -Fq "ЗАПИС ЗАБЛОКОВАНО: $expected_reason" "$TMP/mixed-$blocker.php.out" || fail "mixed $blocker blocker output"
    for side in sh php; do
        quarantine="$TMP/state-mixed-$blocker-$side/quarantine.jsonl"
        attempts="$TMP/state-mixed-$blocker-$side/row-attempts.jsonl"
        test -f "$quarantine" || fail "mixed $blocker $side quarantine"
        grep -Fq "\"identity_hash\":\"$BLOCK_H1\"" "$quarantine" || fail "mixed $blocker $side PASS held"
        grep -Fq "\"identity_hash\":\"$BLOCK_H2\"" "$quarantine" || fail "mixed $blocker $side proposal held"
        "$REAL_PHP" -r '$want=$argv[2];foreach(file($argv[1],FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){$row=json_decode($line,true);if(($row["reason"]??null)!==$want)exit(1);}exit(0);' "$quarantine" "$expected_reason" \
            || fail "mixed $blocker $side reason"
        test ! -s "$attempts" || fail "mixed $blocker $side RowAttempts"
    done
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
