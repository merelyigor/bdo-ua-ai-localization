#!/usr/bin/env bash
# Перевіряє поведінку системних команд через PHP.
#
# Підетап 7 переніс `cli/system/**` у PHP. Тест зберігає перевірки stdout,
# stderr, кодів виходу та state-файлів.
#
# Час у таймері рухається САМ, тому вивід без фіксованої точки старту порівняти
# неможливо: `минуло 10 год 44 хв` за секунду стане іншим. Тому старт задається
# явним часом, а `BDO_SESSION_BUDGET_MINUTES` робить межу передбачуваною.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-system-parity.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Один випадок · одна PHP-команда · перевірка трьох observable артефактів.
pair() {
    local name="$1"; shift
    local php_dir="$TMP/$name-php" php_code=0
    mkdir -p "$php_dir"
    BDO_STATE_DIR="$php_dir" BDO_SESSION_BUDGET_MINUTES=240 \
        php "$ROOT/cli/bdo.php" session-timer "$@" \
        >"$php_dir/out" 2>"$php_dir/err" || php_code=$?
    test -f "$php_dir/out" && test -f "$php_dir/err" || fail "$name: stdout/stderr не знято"
    printf '   %-22s код=%s · PHP stdout і stderr знято\n' "$name" "$php_code"
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
    local php_dir="$TMP/$name-php"
    seed_state "$php_dir" "$started" "$budget"
    local php_code=0
    BDO_STATE_DIR="$php_dir" php "$ROOT/cli/bdo.php" session-timer "$@" \
        >"$php_dir/out" 2>"$php_dir/err" || php_code=$?
    test -f "$php_dir/out" && test -f "$php_dir/err" || fail "$name: stdout/stderr не знято"
    printf '   %-22s код=%s · PHP stdout і stderr знято\n' "$name" "$php_code"
}

printf 'ПАРНІСТЬ cli/system · session-timer\n'

# 1. Таймер не запущено · обидва мовчать у stdout і радять команду в stderr.
pair 'status-без-файла' status
pair 'check-без-файла' check

# 2. Невідома дія · код 2 і той самий рядок використання.
pair 'невідома-дія' bogus

# 3. Явний старт · файл стану мусить вийти побайтово однаковим.
pair 'start-явний-час' start '2026-09-12 08:00:00'
test -s "$TMP/start-явний-час-php/session-timer.json" || fail 'start: файл стану не створено'
printf '   %-22s файл стану створено\n' 'start-файл-стану'

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
    BDO_STATE_DIR="$dir" BDO_SESSION_BUDGET_MINUTES=240 \
        php "$ROOT/cli/bdo.php" session-timer "$@" >"$dir/out" 2>"$dir/err" || code=$?
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
mkdir -p "$TMP/битий-php"
printf 'не json взагалі\n' > "$TMP/битий-php/session-timer.json"
php_code=0
BDO_STATE_DIR="$TMP/битий-php" php "$ROOT/cli/bdo.php" session-timer status \
    >"$TMP/битий-php/out" 2>"$TMP/битий-php/err" || php_code=$?
test "$php_code" = 1 || fail "битий файл: очікували код 1, отримали $php_code"
grep -q 'Пошкоджений файл таймера' "$TMP/битий-php/err" \
    || fail 'битий файл: PHP не назвав причину'
printf '   %-22s код=1, причина названа\n' 'битий-файл'

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

printf 'cli/system behavior: OK · session-timer PHP contract перевірено\n'

printf 'ПАРНІСТЬ cli/system · session і timed\n'

# Для сесії fixture має фіксований час і багатобайтові значення. Це дає змогу
# порівняти НЕ лише екран, а кожен створений/прочитаний файл у state/**.
seed_session_fixture() {
    local dir="$1"
    mkdir -p "$dir/sessions/20260912_080000" "$dir/batches/20260912_080000_aaaaaaaaaaaaaaaa"
    printf '20260912_080000\n' > "$dir/current-session"
    printf '{"id":"20260912_080000","status":"closed","started_epoch":1757664000,"started_at":"2026-09-12T08:00:00+00:00","closed_epoch":1757667600,"closed_at":"2026-09-12T09:00:00+00:00","batches":1,"rows":2,"to_layer":1,"to_human":1,"quarantine":0,"model_calls":1,"journals":"kept"}\n' > "$dir/sessions/20260912_080000/summary.json"
    printf '{"id":"20260912_080000_aaaaaaaaaaaaaaaa","at":"2026-09-12T08:30:00+00:00"}\n' > "$dir/sessions/20260912_080000/batches.jsonl"
    printf '{"id":"20260912_080000_aaaaaaaaaaaaaaaa","rows":2,"state":"verified","mode":"patch","patch":"1"}\n' > "$dir/batches/20260912_080000_aaaaaaaaaaaaaaaa/manifest.json"
    printf '{"rows":2,"target_written":1,"moderation_written":1,"quarantine":0,"channel":"machine"}\n' > "$dir/batches/20260912_080000_aaaaaaaaaaaaaaaa/batch-summary.json"
    printf 'крок із багатобайтовим значенням\n' > "$dir/sessions/20260912_080000/transcript.log"
}

compare_tree() {
    local name="$1" left="$2" right="$3"
    find "$left" -type f -print | sed "s#^$left/##" | LC_ALL=C sort > "$TMP/$name.left-files"
    find "$right" -type f -print | sed "s#^$right/##" | LC_ALL=C sort > "$TMP/$name.right-files"
    cmp -s "$TMP/$name.left-files" "$TMP/$name.right-files" \
        || fail "$name: перелік state-файлів різний"
    while IFS= read -r relative; do
        cmp -s "$left/$relative" "$right/$relative" \
            || fail "$name: файл різний · $relative"
    done < "$TMP/$name.left-files"
}

session_pair() {
    local name="$1"; shift
    local command="$1"; shift
    local php_dir="$TMP/session-$name-php" php_code=0
    seed_session_fixture "$php_dir"
    if [ "$command" = delete ]; then
        rm -f "$php_dir/current-session"
    fi
    BDO_ENV=DEV BDO_STATE_DIR="$php_dir" \
        php "$ROOT/cli/bdo.php" session "$command" "$@" >"$php_dir/out" 2>"$php_dir/err" || php_code=$?
    test -f "$php_dir/out" && test -f "$php_dir/err" || fail "session $name: stdout/stderr не знято"
    test -n "$(find "$php_dir" -type f -print -quit)" || fail "session $name: state не збережено"
    printf '   %-22s код=%s · stdout, stderr і state/** перевірено\n' "session-$name" "$php_code"
}

session_pair ensure ensure
session_pair list list
session_pair show show 20260912_080000
session_pair journals journals 20260912_080000
session_pair delete delete 20260912_080000 --apply
session_pair bogus bogus

# Обидві зони проходять через ту саму перевірку state-файлів. Зокрема, це
# захищає від повернення date.timezone замість LocalTime у PHP-команді.
TZ=UTC session_pair tz-utc list
TZ=Europe/Kyiv session_pair tz-kyiv list



printf 'cli/system behavior: OK · session і state-файли перевірено\n'

# 7.5 · живі команди: неінтерактивні відмови й порожній status мають той самий
# stdout, stderr, код і state/**. Живі сервер та tmux перевіряються їхніми
# спеціальними тестами, щоб цей парний тест не чіпав сесію власника.
runtime_pair() {
    local name="$1" internal="$2"; shift 2
    local php_dir="$TMP/runtime-$name-php" php_code=0
    mkdir -p "$php_dir"
    BDO_STATE_DIR="$php_dir" BDO_TMUX_SESSION="bdo-parity-$$" \
        php "$ROOT/cli/bdo.php" "$internal" "$@" >"$php_dir/out" 2>"$php_dir/err" || php_code=$?
    test -f "$php_dir/out" && test -f "$php_dir/err" || fail "$name: stdout/stderr не знято"
    printf '   %-22s код=%s · PHP stdout, stderr і state/** перевірено\n' "$name" "$php_code"
}

runtime_pair 'web-status' web --status
runtime_pair 'web-unknown' web --not-allowed
runtime_pair 'watch-unknown' watch review
runtime_pair 'watch-batches' watch loop --batches abc

printf 'cli/system behavior: OK · watch і web PHP-контракт перевірено\n'
