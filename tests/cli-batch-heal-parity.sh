#!/usr/bin/env bash
# Доводить байтову парність batch/heal між rollback shell і прямим PHP Kernel.
#
# Мережа тут не потрібна: heal працює лише з локальними artifact-файлами, а
# batch-new викликає session.sh ensure як тимчасовий seam підетапу 7.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

H1='1111111111111111111111111111111111111111111111111111111111111111'
H2='2222222222222222222222222222222222222222222222222222222222222222'
H3='3333333333333333333333333333333333333333333333333333333333333333'

cat >"$TMP/rows.json" <<JSON
{"data":{"rows":[
 {"identity_hash":"$H1","source_hash":"a","source_text":"Iron Sword","record_id":1},
 {"identity_hash":"$H2","source_hash":"b","source_text":"Iron Shield","record_id":2},
 {"identity_hash":"$H3","source_hash":"c","source_text":"Iron Helm","record_id":3}
]}}
JSON
cat >"$TMP/candidate.json" <<JSON
[
 {"identity_hash":"$H1","text":"Залізний меч"},
 {"identity_hash":"$H2","text":"Залізний щит"},
 {"identity_hash":"$H3","text":"Залізний шолом"}
]
JSON
cat >"$TMP/verdicts.json" <<JSON
[
 {"identity_hash":"$H1","status":"PASS","severity":"none","issue":"","fix":""},
 {"identity_hash":"$H2","status":"REVIEW","severity":"minor","issue":"потрібна перевірка","fix":""},
 {"identity_hash":"$H3","status":"PASS","severity":"none","issue":"","fix":""}
]
JSON
cat >"$TMP/validate.json" <<JSON
{"data":{"results":[]}}
JSON

# ПРАВИЛО: часові мітки можна нормалізувати лише в імені пачки й у тимчасовій
# теці прогону; identity_hash, текст і числа мають залишатися порівнюваними.
# САБОТАЖ: широка заміна цифр або всього рядка приховає зміну payload.
normalize_stream() {
    sed -E \
        -e "s|$TMP/batch-sh|RUN|g" \
        -e "s|$TMP/batch-php|RUN|g" \
        -e "s|$TMP/heal-sh|RUN|g" \
        -e "s|$TMP/heal-php|RUN|g" \
        -e "s|$TMP|TMP|g" \
        -e 's/[0-9]{8}_[0-9]{6}(_[0-9]{3})?_[0-9a-f]{16}/BATCH_ID/g' \
        -e 's/[0-9]{8}_[0-9]{6}/TIMESTAMP/g' \
        "$1" >"$2"
}

# ПРАВИЛО: normalizer має прибирати тільки динамічну мітку й не маскувати
# stable fields, від яких залежить ownership та форма artifact.
# САБОТАЖ: широкий normalizer має зробити цю перевірку червоною.
cat >"$TMP/normalizer-input" <<EOF
id=20260908_010203_abcdef0123456789 hash=$H1 count=3 text=Iron Sword
EOF
normalize_stream "$TMP/normalizer-input" "$TMP/normalizer-output"
grep -Fq 'id=BATCH_ID hash='"$H1"' count=3 text=Iron Sword' "$TMP/normalizer-output" \
    || fail 'normalizer приховав або змінив stable field'
grep -Fq '20260908_010203' "$TMP/normalizer-output" && fail 'normalizer не прибрав timestamp'

run_shell() {
    local name="$1" state="$2" wrapper="$3"
    shift 3
    mkdir -p "$TMP/$name-sh"
    set +e
    BDO_ORCHESTRATOR=sh BDO_STATE_DIR="$state" bash "$ROOT/$wrapper" "$@" \
        >"$TMP/$name-sh/out" 2>"$TMP/$name-sh/err"
    local code=$?
    set -e
    printf '%s\n' "$code" >"$TMP/$name-sh/code"
}

run_php() {
    local name="$1" state="$2" internal="$3"
    shift 3
    mkdir -p "$TMP/$name-php"
    set +e
    BDO_ORCHESTRATOR=php BDO_STATE_DIR="$state" php "$ROOT/cli/bdo.php" "$internal" "$@" \
        >"$TMP/$name-php/out" 2>"$TMP/$name-php/err"
    local code=$?
    set -e
    printf '%s\n' "$code" >"$TMP/$name-php/code"
}

# ПРАВИЛО: rollback і PHP side мають збігатися в stdout, stderr і exit code.
# САБОТАЖ: зміна будь-якого каналу повинна зупинити parity з назвою команди.
pair() {
    local name="$1" wrapper="$2" internal="$3" state_sh="$4" state_php="$5"
    shift 5
    run_shell "$name" "$state_sh" "$wrapper" "$@"
    run_php "$name" "$state_php" "$internal" "$@"
    normalize_stream "$TMP/$name-sh/out" "$TMP/$name-sh/out.normalized"
    normalize_stream "$TMP/$name-php/out" "$TMP/$name-php/out.normalized"
    cmp -s "$TMP/$name-sh/out.normalized" "$TMP/$name-php/out.normalized" \
        || { diff -u "$TMP/$name-sh/out.normalized" "$TMP/$name-php/out.normalized" >&2 || true; fail "$name: stdout не збігається"; }
    normalize_stream "$TMP/$name-sh/err" "$TMP/$name-sh/err.normalized"
    normalize_stream "$TMP/$name-php/err" "$TMP/$name-php/err.normalized"
    cmp -s "$TMP/$name-sh/err.normalized" "$TMP/$name-php/err.normalized" \
        || { diff -u "$TMP/$name-sh/err.normalized" "$TMP/$name-php/err.normalized" >&2 || true; fail "$name: stderr не збігається"; }
    cmp -s "$TMP/$name-sh/code" "$TMP/$name-php/code" \
        || fail "$name: код виходу не збігається"
}

# ПРАВИЛО: default wrapper маршрутизує в точну internal Kernel command.
# САБОТАЖ: fake php приймає лише cli/bdo.php <command>, тому старий shell або
# php -r одразу зробить routing check червоним.
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
for route in batch-dir batch-assert batch-new subset-rows heal-plan; do
    case "$route" in
        batch-dir) wrapper=cli/batch/batch-dir.sh ;;
        batch-assert) wrapper=cli/batch/batch-assert.sh ;;
        batch-new) wrapper=cli/batch/batch-new.sh ;;
        subset-rows) wrapper=cli/batch/subset-rows.sh ;;
        heal-plan) wrapper=cli/heal/heal-plan.sh ;;
    esac
    cat >"$FAKE_BIN/php" <<FAKE
#!/usr/bin/env bash
if [ "\${1:-}" != "$ROOT/cli/bdo.php" ] || [ "\${2:-}" != "$route" ]; then
    echo 'FAIL: неправильна форма PHP delegate' >&2
    exit 1
fi
echo "__ROUTE__$route"
FAKE
    chmod +x "$FAKE_BIN/php"
    set +e
    PATH="$FAKE_BIN:$PATH" BDO_ORCHESTRATOR=php bash "$ROOT/$wrapper" >"$TMP/route-$route.out" 2>"$TMP/route-$route.err"
    code=$?
    set -e
    test "$code" -eq 0 || fail "routing $route: fake php відмовив ($code): $(cat "$TMP/route-$route.err")"
    grep -Fq "__ROUTE__$route" "$TMP/route-$route.out" || fail "routing $route: marker відсутній"
done

# ПРАВИЛО: batch-dir без current batch має порожній stdout і код 1.
# САБОТАЖ: мовчазний успіх або сторонній шлях порушить контракт драйвера.
mkdir -p "$TMP/empty-sh/state" "$TMP/empty-php/state"
pair batch-dir-empty cli/batch/batch-dir.sh batch-dir "$TMP/empty-sh/state" "$TMP/empty-php/state"
test ! -s "$TMP/batch-dir-empty-sh/out" && test "$(cat "$TMP/batch-dir-empty-sh/code")" = 1 \
    || fail 'batch-dir без пачки має бути порожнім і повертати 1'

# ПРАВИЛО: batch-new зберігає side effects, manifest, rows copy і session ledger.
# САБОТАЖ: зміна stable manifest або пропуск recordBatch має впасти на файлах.
mkdir -p "$TMP/batch-sh/state" "$TMP/batch-php/state"
pair batch-new cli/batch/batch-new.sh batch-new "$TMP/batch-sh/state" "$TMP/batch-php/state" "$TMP/rows.json"
SH_BATCH="$(cat "$TMP/batch-sh/state/current-batch")"
PHP_BATCH="$(cat "$TMP/batch-php/state/current-batch")"
test -n "$SH_BATCH" && test -n "$PHP_BATCH" || fail 'batch-new не створив current-batch'
test -s "$TMP/batch-sh/state/batches/$SH_BATCH/rows.json" || fail 'shell не скопіював rows.json'
test -s "$TMP/batch-php/state/batches/$PHP_BATCH/rows.json" || fail 'PHP не скопіював rows.json'
jq 'del(.created_at,.updated_at) | .id = "BATCH_ID"' "$TMP/batch-sh/state/batches/$SH_BATCH/manifest.json" >"$TMP/manifest-sh"
jq 'del(.created_at,.updated_at) | .id = "BATCH_ID"' "$TMP/batch-php/state/batches/$PHP_BATCH/manifest.json" >"$TMP/manifest-php"
cmp -s "$TMP/manifest-sh" "$TMP/manifest-php" || fail 'batch-new manifest не збігається'
cmp -s "$TMP/batch-sh/state/batches/$SH_BATCH/rows.json" "$TMP/batch-php/state/batches/$PHP_BATCH/rows.json" \
    || fail 'batch-new rows.json не збігається'
SH_SESSION="$(cat "$TMP/batch-sh/state/current-session")"
PHP_SESSION="$(cat "$TMP/batch-php/state/current-session")"
test -s "$TMP/batch-sh/state/sessions/$SH_SESSION/batches.jsonl" || fail 'shell не записав session ledger'
test -s "$TMP/batch-php/state/sessions/$PHP_SESSION/batches.jsonl" || fail 'PHP не записав session ledger'
jq -c 'del(.at) | .id = "BATCH_ID"' "$TMP/batch-sh/state/sessions/$SH_SESSION/batches.jsonl" >"$TMP/ledger-sh"
jq -c 'del(.at) | .id = "BATCH_ID"' "$TMP/batch-php/state/sessions/$PHP_SESSION/batches.jsonl" >"$TMP/ledger-php"
cmp -s "$TMP/ledger-sh" "$TMP/ledger-php" || fail 'session ledger entry не збігається'

# ПРАВИЛО: --show і batch-dir читають current workspace, batch-assert перевіряє
# ownership, а --end прибирає лише pointer.
# САБОТАЖ: порівняння лише stdout не побачить зламаний pointer або ownership.
pair batch-show cli/batch/batch-new.sh batch-new "$TMP/batch-sh/state" "$TMP/batch-php/state" --show
pair batch-dir-current cli/batch/batch-dir.sh batch-dir "$TMP/batch-sh/state" "$TMP/batch-php/state"
pair batch-assert-explicit cli/batch/batch-assert.sh batch-assert "$TMP/batch-sh/state" "$TMP/batch-php/state" "$TMP/rows.json" "$TMP/candidate.json"
pair batch-assert-current cli/batch/batch-assert.sh batch-assert "$TMP/batch-sh/state" "$TMP/batch-php/state"
pair batch-end cli/batch/batch-new.sh batch-new "$TMP/batch-sh/state" "$TMP/batch-php/state" --end
test ! -e "$TMP/batch-sh/state/current-batch" && test ! -e "$TMP/batch-php/state/current-batch" \
    || fail 'batch-new --end не закрив current-batch'

# ПРАВИЛО: subset зберігає source order, форму data.rows і всі запитані hashes.
# САБОТАЖ: пропуск одного hash при правдоподібній кількості має впасти на cmp.
run_shell subset-file "$TMP/subset-sh/state" cli/batch/subset-rows.sh "$TMP/rows.json" "$H3,$H1" "$TMP/subset-sh.json"
run_php subset-file "$TMP/subset-php/state" subset-rows "$TMP/rows.json" "$H3,$H1" "$TMP/subset-php.json"
cmp -s "$TMP/subset-sh.json" "$TMP/subset-php.json" || fail 'subset JSON не збігається'
test "$(jq -r '.data.rows[0].identity_hash' "$TMP/subset-php.json")" = "$H1" \
    || fail 'subset не зберіг source order'
run_shell subset-missing "$TMP/subset-missing-sh/state" cli/batch/subset-rows.sh "$TMP/rows.json" "$H1,deadbeef" "$TMP/missing-sh.json"
run_php subset-missing "$TMP/subset-missing-php/state" subset-rows "$TMP/rows.json" "$H1,deadbeef" "$TMP/missing-php.json"
test "$(cat "$TMP/subset-missing-sh/code")" -ne 0 && test "$(cat "$TMP/subset-missing-php/code")" -ne 0 \
    || fail 'subset missing мусить відмовити обома шляхами'
grep -Fq 'Хеші відсутні в rows.json: deadbeef' "$TMP/subset-missing-sh/err" \
    || fail 'shell subset missing не назвав відсутній hash'
grep -Fq 'Хеші відсутні в rows.json: deadbeef' "$TMP/subset-missing-php/err" \
    || fail 'PHP subset missing не назвав відсутній hash'

# ПРАВИЛО: heal перевіряє ownership до планування, а artifact-и й attempts
# привʼязані до конкретного batch key та однаково готують підмножину схем.
# САБОТАЖ: зміна heal payload, merged candidate або attempts state має впасти.
mkdir -p "$TMP/heal-sh/state" "$TMP/heal-php/state"
run_shell heal-prepare "$TMP/heal-sh/state" cli/batch/batch-new.sh "$TMP/rows.json"
run_php heal-prepare "$TMP/heal-php/state" batch-new "$TMP/rows.json"
pair heal cli/heal/heal-plan.sh heal-plan "$TMP/heal-sh/state" "$TMP/heal-php/state" \
    "$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" "$TMP/validate.json"
SH_HEAL="$(cat "$TMP/heal-sh/state/current-batch")"
PHP_HEAL="$(cat "$TMP/heal-php/state/current-batch")"
for file in heal-merged.json heal-repair-payload.json heal-attempts.json heal-repair-subset.json; do
    test -f "$TMP/heal-sh/state/batches/$SH_HEAL/$file" || fail "shell heal не створив $file"
    test -f "$TMP/heal-php/state/batches/$PHP_HEAL/$file" || fail "PHP heal не створив $file"
    cmp -s "$TMP/heal-sh/state/batches/$SH_HEAL/$file" "$TMP/heal-php/state/batches/$PHP_HEAL/$file" \
        || fail "heal artifact $file не збігається"
done
cmp -s "$TMP/heal-sh/state/current-response-schema.json" "$TMP/heal-php/state/current-response-schema.json" \
    || fail 'heal response schema не збігається'
cmp -s "$TMP/heal-sh/state/current-qa-schema.json" "$TMP/heal-php/state/current-qa-schema.json" \
    || fail 'heal QA schema не збігається'

printf '%s\n' 'cli batch/heal parity: 5 команд, routing, stdout/stderr/коди й state files: OK'
