#!/usr/bin/env bash
# Байтова парність команд `cli/system/**` між rollback shell і PHP.
#
# Підетап 7 переносить `cli/system/**` у PHP. Парність доводиться тим самим
# способом, що й для решти категорій: ОБИДВА шляхи ганяються на однакових
# входах, і stdout, stderr та код виходу мусять збігтися побайтово.
#
# Час у таймері рухається САМ, тому вивід без фіксованої точки старту порівняти
# неможливо: `минуло 10 год 44 хв` за секунду стане іншим. Тому старт задається
# явним часом, а `BDO_SESSION_BUDGET_MINUTES` робить межу передбачуваною.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-system-parity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Один випадок · обидва оркестратори · порівняння трьох артефактів.
pair() {
    local name="$1"; shift
    local sh_dir="$TMP/$name-sh" php_dir="$TMP/$name-php"
    mkdir -p "$sh_dir" "$php_dir"

    local sh_code=0 php_code=0
    BDO_ORCHESTRATOR=sh BDO_STATE_DIR="$sh_dir" BDO_SESSION_BUDGET_MINUTES=240 \
        bash "$ROOT/cli/system/session-timer.sh" "$@" \
        >"$sh_dir/out" 2>"$sh_dir/err" || sh_code=$?
    BDO_ORCHESTRATOR=php BDO_STATE_DIR="$php_dir" BDO_SESSION_BUDGET_MINUTES=240 \
        bash "$ROOT/cli/system/session-timer.sh" "$@" \
        >"$php_dir/out" 2>"$php_dir/err" || php_code=$?

    test "$sh_code" = "$php_code" \
        || fail "$name: код виходу різний · sh=$sh_code php=$php_code"
    cmp -s "$sh_dir/out" "$php_dir/out" \
        || fail "$name: stdout різний · $(diff "$sh_dir/out" "$php_dir/out" | head -4 | tr '\n' ' ')"
    cmp -s "$sh_dir/err" "$php_dir/err" \
        || fail "$name: stderr різний · $(diff "$sh_dir/err" "$php_dir/err" | head -4 | tr '\n' ' ')"
    printf '   %-22s код=%s · stdout і stderr збігаються\n' "$name" "$sh_code"
}

# Стан, спільний для обох шляхів: старт задано явно, тому «минуло» однакове.
seed_state() {
    local dir="$1" started="$2" budget="${3:-240}"
    mkdir -p "$dir"
    printf '{\n  "started_epoch": %s,\n  "budget_minutes": %s\n}\n' "$started" "$budget" \
        > "$dir/session-timer.json"
}

pair_seeded() {
    local name="$1" started="$2" budget="$3"; shift 3
    local sh_dir="$TMP/$name-sh" php_dir="$TMP/$name-php"
    seed_state "$sh_dir" "$started" "$budget"
    seed_state "$php_dir" "$started" "$budget"

    local sh_code=0 php_code=0
    BDO_ORCHESTRATOR=sh BDO_STATE_DIR="$sh_dir" bash "$ROOT/cli/system/session-timer.sh" "$@" \
        >"$sh_dir/out" 2>"$sh_dir/err" || sh_code=$?
    BDO_ORCHESTRATOR=php BDO_STATE_DIR="$php_dir" bash "$ROOT/cli/system/session-timer.sh" "$@" \
        >"$php_dir/out" 2>"$php_dir/err" || php_code=$?

    test "$sh_code" = "$php_code" || fail "$name: код виходу різний · sh=$sh_code php=$php_code"
    cmp -s "$sh_dir/out" "$php_dir/out" || fail "$name: stdout різний"
    cmp -s "$sh_dir/err" "$php_dir/err" || fail "$name: stderr різний"
    printf '   %-22s код=%s · stdout і stderr збігаються\n' "$name" "$sh_code"
}

printf 'ПАРНІСТЬ cli/system · session-timer\n'

# 1. Таймер не запущено · обидва мовчать у stdout і радять команду в stderr.
pair 'status-без-файла' status
pair 'check-без-файла' check

# 2. Невідома дія · код 2 і той самий рядок використання.
pair 'невідома-дія' bogus

# 3. Явний старт · файл стану мусить вийти побайтово однаковим.
pair 'start-явний-час' start '2026-09-12 08:00:00'
cmp -s "$TMP/start-явний-час-sh/session-timer.json" "$TMP/start-явний-час-php/session-timer.json" \
    || fail 'start: файл стану різний між sh і php'
printf '   %-22s файл стану побайтово однаковий\n' 'start-файл-стану'

# 4. Неповний час · КОНТРАКТ PHP, а не парність. І це не послаблення тесту.
#
# Bash-еталон тут РІЗНИЙ на різних ОС: BSD `date -j -f` вимагає повний формат і
# рядок без часу відхиляє, а GNU `date -d 2026-09-12` мовчки дає опівніч.
# Спіймано CI на ubuntu 2026-09-12 (`sh=0 php=1`). Вимагати парності з еталоном,
# який сам залежить від платформи, означало б закріпити в PHP саме ту
# різницю, заради усунення якої йде весь етап.
#
# Тому перевіряється КОНТРАКТ: PHP приймає рівно документований формат
# `Y-m-d H:i:s` і на всьому іншому дає код 1 з названою причиною · однаково на
# macOS, Linux і Windows.
php_contract() {
    local name="$1" want_code="$2"; shift 2
    local dir="$TMP/$name" code=0
    mkdir -p "$dir"
    BDO_ORCHESTRATOR=php BDO_STATE_DIR="$dir" BDO_SESSION_BUDGET_MINUTES=240 \
        bash "$ROOT/cli/system/session-timer.sh" "$@" >"$dir/out" 2>"$dir/err" || code=$?
    test "$code" = "$want_code" \
        || fail "$name: PHP дав код $code замість $want_code"
    printf '   %-22s PHP код=%s (контракт, не парність)\n' "$name" "$code"
}

php_contract 'start-без-часу' 1 start '2026-09-12'
php_contract 'start-сміття' 1 start 'учора ввечері'
php_contract 'start-повний-формат' 0 start '2026-09-12 08:00:00'
grep -q 'Незрозумілий час старту' "$TMP/start-без-часу/err" \
    || fail 'PHP не назвав причину відмови на неповному часі'

# 5. Межу вичерпано · `check` дає 1, `status` дає 0 на тому самому стані.
past="$(( $(date +%s) - 300 * 60 ))"
pair_seeded 'вичерпано-check' "$past" 240 check
pair_seeded 'вичерпано-status' "$past" 240 status

# 6. Межа ще не вичерпана.
recent="$(( $(date +%s) - 30 * 60 ))"
pair_seeded 'у-межах-status' "$recent" 240 status
pair_seeded 'у-межах-check' "$recent" 240 check

# 7. Пошкоджений файл · код 1 і той самий текст.
mkdir -p "$TMP/битий-sh" "$TMP/битий-php"
printf 'не json взагалі\n' > "$TMP/битий-sh/session-timer.json"
printf 'не json взагалі\n' > "$TMP/битий-php/session-timer.json"
sh_code=0; php_code=0
BDO_ORCHESTRATOR=sh BDO_STATE_DIR="$TMP/битий-sh" bash "$ROOT/cli/system/session-timer.sh" status \
    >"$TMP/битий-sh/out" 2>"$TMP/битий-sh/err" || sh_code=$?
BDO_ORCHESTRATOR=php BDO_STATE_DIR="$TMP/битий-php" bash "$ROOT/cli/system/session-timer.sh" status \
    >"$TMP/битий-php/out" 2>"$TMP/битий-php/err" || php_code=$?
test "$sh_code" = "$php_code" || fail "битий файл: код різний · sh=$sh_code php=$php_code"
test "$sh_code" = 1 || fail "битий файл: очікували код 1, отримали $sh_code"
grep -q 'Пошкоджений файл таймера' "$TMP/битий-sh/err" \
    || fail 'битий файл: bash не назвав причину'
grep -q 'Пошкоджений файл таймера' "$TMP/битий-php/err" \
    || fail 'битий файл: PHP не назвав причину'
printf '   %-22s код=1 в обох, причина названа\n' 'битий-файл'

# 8. Команда справді зареєстрована в ядрі · інакше делегування з `.sh`
#    мовчки падало б на «невідома команда», а парність цього не побачила б,
#    бо обидва шляхи давали б однакову помилку.
# Вивід знімається У ФАЙЛ, а не подається в `grep` конвеєром. Під
# `set -o pipefail` статус конвеєра бере ПЕРШУ ненульову ланку, тобто код 2 від
# самої команди, і перевірка падала б навіть тоді, коли grep усе знайшов.
kernel_code=0
php "$ROOT/cli/bdo.php" session-timer bogus >"$TMP/kernel.out" 2>&1 || kernel_code=$?
test "$kernel_code" = 2 \
    || fail "ядро на невідомій дії дало код $kernel_code замість 2"
grep -q 'Використання: session-timer.sh' "$TMP/kernel.out" \
    || fail 'ядро не знає команду session-timer'
printf '   %-22s ядро відповідає напряму\n' 'реєстрація-в-ядрі'

printf 'cli/system parity: OK · session-timer байтово однаковий на обох шляхах\n'
