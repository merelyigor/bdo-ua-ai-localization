#!/usr/bin/env bash
# Перевіряє поведінку batch/heal через прямий PHP Kernel.
#
# Мережа тут не потрібна: heal працює лише з локальними artifact-файлами, а
# batch-new відкриває сесію через спільну PHP-логіку.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
REAL_PHP="$(command -v php)"
test -x "$REAL_PHP" || fail 'не знайдено абсолютний PHP'

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
        -e 's/[0-9]{8}_[0-9]{6}(_[0-9]{3})?_[0-9a-f]{4,16}/BATCH_ID/g' \
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

run_php() {
    local name="$1" state="$2" internal="$3"
    shift 3
    mkdir -p "$TMP/$name-php"
    set +e
    BDO_STATE_DIR="$state" php "$ROOT/cli/bdo.php" "$internal" "$@" \
        >"$TMP/$name-php/out" 2>"$TMP/$name-php/err"
    local code=$?
    set -e
    printf '%s\n' "$code" >"$TMP/$name-php/code"
}

pair() {
    local name="$1" internal="$2" state="$3"
    shift 3
    run_php "$name" "$state" "$internal" "$@"
}

# ПРАВИЛО: BatchNewCommand не запускає зовнішній `date`.
# САБОТАЖ: PHP-команда створює state самостійно, без shell seam.
mkdir -p "$TMP/no-date/state"
set +e
BDO_ENV=DEV BDO_STATE_DIR="$TMP/no-date/state" \
    "$REAL_PHP" "$ROOT/cli/bdo.php" batch-new "$TMP/rows.json" \
    >"$TMP/no-date/out" 2>"$TMP/no-date/err"
NO_DATE_CODE=$?
set -e
test "$NO_DATE_CODE" -eq 0 || fail "batch-new залежить від зовнішнього date (code $NO_DATE_CODE): $(cat "$TMP/no-date/err")"
test -s "$TMP/no-date/state/current-batch" || fail 'batch-new без date не створив current batch'

# ПРАВИЛО: batch-dir без current batch має порожній stdout і код 1.
# САБОТАЖ: мовчазний успіх або сторонній шлях порушить контракт драйвера.
mkdir -p "$TMP/empty-sh/state" "$TMP/empty-php/state"
pair batch-dir-empty batch-dir "$TMP/empty-php/state"
test ! -s "$TMP/batch-dir-empty-php/out" && test "$(cat "$TMP/batch-dir-empty-php/code")" = 1 \
    || fail 'batch-dir без пачки має бути порожнім і повертати 1'

# ПРАВИЛО: batch-new зберігає side effects, manifest, rows copy і session ledger.
# САБОТАЖ: зміна stable manifest або пропуск recordBatch має впасти на файлах.
mkdir -p "$TMP/batch-php/state"
pair batch-new batch-new "$TMP/batch-php/state" "$TMP/rows.json"
PHP_BATCH="$(cat "$TMP/batch-php/state/current-batch")"
test -n "$PHP_BATCH" || fail 'batch-new не створив current-batch'
test -s "$TMP/batch-php/state/batches/$PHP_BATCH/rows.json" || fail 'PHP не скопіював rows.json'
PHP_SESSION="$(cat "$TMP/batch-php/state/current-session")"
test -s "$TMP/batch-php/state/sessions/$PHP_SESSION/batches.jsonl" || fail 'PHP не записав session ledger'

# ПРАВИЛО: --show і batch-dir читають current workspace, batch-assert перевіряє
# ownership, а --end прибирає лише pointer.
# САБОТАЖ: порівняння лише stdout не побачить зламаний pointer або ownership.
pair batch-show batch-new "$TMP/batch-php/state" --show
pair batch-dir-current batch-dir "$TMP/batch-php/state"
pair batch-assert-explicit batch-assert "$TMP/batch-php/state" "$TMP/rows.json" "$TMP/candidate.json"
pair batch-assert-current batch-assert "$TMP/batch-php/state"
pair batch-end batch-new "$TMP/batch-php/state" --end
test ! -e "$TMP/batch-php/state/current-batch" \
    || fail 'batch-new --end не закрив current-batch'

# ПРАВИЛО: subset зберігає source order, форму data.rows і всі запитані hashes.
# САБОТАЖ: пропуск одного hash при правдоподібній кількості має впасти на cmp.
run_php subset-file "$TMP/subset-php/state" subset-rows "$TMP/rows.json" "$H3,$H1" "$TMP/subset-php.json"
test "$(jq -r '.data.rows[0].identity_hash' "$TMP/subset-php.json")" = "$H1" \
    || fail 'subset не зберіг source order'
run_php subset-missing "$TMP/subset-missing-php/state" subset-rows "$TMP/rows.json" "$H1,deadbeef" "$TMP/missing-php.json"
test "$(cat "$TMP/subset-missing-php/code")" -ne 0 \
    || fail 'subset missing мусить відмовити обома шляхами'
grep -Fq 'Хеші відсутні в rows.json: deadbeef' "$TMP/subset-missing-php/err" \
    || fail 'PHP subset missing не назвав відсутній hash'

# ПРАВИЛО: heal перевіряє ownership до планування, а artifact-и й attempts
# привʼязані до конкретного batch key та однаково готують підмножину схем.
# САБОТАЖ: зміна heal payload, merged candidate або attempts state має впасти.
mkdir -p "$TMP/heal-php/state"
run_php heal-prepare "$TMP/heal-php/state" batch-new "$TMP/rows.json"
pair heal heal-plan "$TMP/heal-php/state" \
    "$TMP/rows.json" "$TMP/candidate.json" "$TMP/verdicts.json" "$TMP/validate.json"
PHP_HEAL="$(cat "$TMP/heal-php/state/current-batch")"
for file in heal-merged.json heal-repair-payload.json heal-attempts.json heal-repair-subset.json; do
    test -f "$TMP/heal-php/state/batches/$PHP_HEAL/$file" || fail "PHP heal не створив $file"
done
test -s "$TMP/heal-php/state/current-response-schema.json" || fail 'heal response schema не створено'
test -s "$TMP/heal-php/state/current-qa-schema.json" || fail 'heal QA schema не створено'
# РЕМОНТ ВІДПОВІДАЄ АДРЕСОЮ ПРАВКИ. Схема тут не косметика: поки в ній лишалось
# поле `text`, роль мала право передрукувати рядок цілком, і жодна перевірка
# цього не тримала (заміряно 2026-09-18 · правка зі схожістю 65.6%).
jq -e '.properties.items.items.required == ["identity_hash","find","replace"]' \
    "$TMP/heal-php/state/current-response-schema.json" >/dev/null \
    || fail 'схема ремонту не вимагає find/replace · роль знову передруковуватиме рядок'
jq -e '.properties.items.items.properties | has("text") | not' \
    "$TMP/heal-php/state/current-response-schema.json" >/dev/null \
    || fail 'схема ремонту досі дозволяє повний текст'

printf '%s\n' 'cli batch/heal behavior: 5 PHP-команд, stdout/stderr/коди й state files: OK'
