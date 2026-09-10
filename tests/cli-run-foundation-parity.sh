#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_PHP="$(command -v php)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

unset BDO_API_BASE BDO_API_KEY BDO_API_ENV BDO_ENV BDO_API_TARGET

make_env() {
    local file="$1" env="$2" target="$3"
    if [ "$target" = legacy ]; then
        if [ "$env" = DEV ]; then
            cat >"$file" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=legacy
BDO_API_BASE_DEV=http://127.0.0.1:1/api
BDO_API_KEY_DEV=test-key
EOF
        else
            cat >"$file" <<EOF
BDO_ENV=PROD
BDO_API_TARGET=legacy
BDO_API_BASE_PROD=https://prod.example/api
BDO_API_KEY_PROD=test-key
EOF
        fi
    elif [ "$env" = DEV ]; then
        cat >"$file" <<EOF
BDO_ENV=DEV
BDO_API_TARGET=hub
HUB_API_BASE_DEV=http://127.0.0.1:2/hub
HUB_API_KEY_DEV=test-key
EOF
    else
        cat >"$file" <<EOF
BDO_ENV=PROD
BDO_API_TARGET=hub
HUB_API_BASE_PROD=https://hub.example/api
HUB_API_KEY_PROD=test-key
EOF
    fi
}

run_command() {
    local side="$1" wrapper="$2" internal="$3" out="$4" err="$5" code="$6"
    shift 6
    set +e
    if [ "$side" = sh ]; then
        BDO_ORCHESTRATOR=sh TRANSLATE_ENV_FILE="$CURRENT_ENV" BDO_STATE_DIR="$CURRENT_STATE" \
            bash "$wrapper" "$@" >"$out" 2>"$err"
    else
        BDO_ORCHESTRATOR=php TRANSLATE_ENV_FILE="$CURRENT_ENV" BDO_STATE_DIR="$CURRENT_STATE" \
            "$REAL_PHP" "$ROOT/cli/bdo.php" "$internal" "$@" >"$out" 2>"$err"
    fi
    local status=$?
    set -e
    printf '%s\n' "$status" >"$code"
}

compare_outputs() {
    local label="$1" shell_out="$2" php_out="$3" shell_err="$4" php_err="$5" shell_code="$6" php_code="$7"
    cmp -s "$shell_out" "$php_out" || fail "$label: stdout не збігається"
    cmp -s "$shell_err" "$php_err" || fail "$label: stderr не збігається"
    cmp -s "$shell_code" "$php_code" || fail "$label: code не збігається"
}

compare_failure_codes() {
    local label="$1" shell_err="$2" php_err="$3" shell_code="$4" php_code="$5" reason="${6:-}"
    test "$(cat "$shell_code")" != 0 || fail "$label: failure стала успішною"
    test "$(cat "$php_code")" != 0 || fail "$label: PHP failure стала успішною"
    test -s "$shell_err" || fail "$label: shell не назвав причину"
    test -s "$php_err" || fail "$label: PHP не назвав причину"
    if [ -n "$reason" ]; then
        grep -Fq "$reason" "$shell_err" || fail "$label: shell не назвав '$reason'"
        grep -Fq "$reason" "$php_err" || fail "$label: PHP не назвав '$reason'"
    fi
}

compare_spec() {
    local label="$1" env="$2"; shift 2
    CURRENT_ENV="$env" CURRENT_STATE="$TMP/spec-state-sh"
    run_command sh "$ROOT/cli/run/run-spec.sh" run-spec "$TMP/$label.sh.out" "$TMP/$label.sh.err" "$TMP/$label.sh.code" "$@"
    CURRENT_STATE="$TMP/spec-state-php"
    run_command php "$ROOT/cli/run/run-spec.sh" run-spec "$TMP/$label.php.out" "$TMP/$label.php.err" "$TMP/$label.php.code" "$@"
    case "$label" in
        status-snapshot-invalid-patch) reason='Патч має бути' ;;
        status-invalid-domain) reason='Невідома категорія' ;;
        status-invalid-mode) reason='Невідомий режим' ;;
        plan-invalid-*) reason='Розмір пачки має бути від 20 до 100' ;;
        plan-missing-parent) reason='plan потребує ідентифікатор прогону' ;;
        *) reason='' ;;
    esac
    case "$label" in
        *invalid*|*missing*)
            compare_failure_codes "$label" "$TMP/$label.sh.err" "$TMP/$label.php.err" "$TMP/$label.sh.code" "$TMP/$label.php.code" "$reason"
            ;;
        *)
            compare_outputs "$label" "$TMP/$label.sh.out" "$TMP/$label.php.out" "$TMP/$label.sh.err" "$TMP/$label.php.err" "$TMP/$label.sh.code" "$TMP/$label.php.code"
            ;;
    esac
}

DEV_ENV="$TMP/dev.env"
PROD_ENV="$TMP/prod.env"
HUB_DEV_ENV="$TMP/hub-dev.env"
HUB_PROD_ENV="$TMP/hub-prod.env"
make_env "$DEV_ENV" DEV legacy
make_env "$PROD_ENV" PROD legacy
make_env "$HUB_DEV_ENV" DEV hub
make_env "$HUB_PROD_ENV" PROD hub

# ПРАВИЛО: кожен wrapper у default-PHP режимі має передати exact internal route.
# САБОТАЖ: зміна dispatcher або route мусить впасти до behavior matrix.
ROUTE_BIN="$TMP/route-bin"
mkdir -p "$ROUTE_BIN"
cat >"$ROUTE_BIN/php" <<'ROUTE'
#!/bin/sh
if [ "${1:-}" != "$ROUTE_ROOT/cli/bdo.php" ] || [ "${2:-}" != "$ROUTE_EXPECTED" ]; then
    printf 'unexpected php route: %s %s\n' "${1:-}" "${2:-}" >&2
    exit 99
fi
printf 'ROUTED:%s\n' "$2"
ROUTE
chmod +x "$ROUTE_BIN/php"
for route in run-spec run-start; do
    wrapper="$ROOT/cli/run/$([ "$route" = run-spec ] && printf 'run-spec' || printf 'run-start').sh"
    ROUTE_ROOT="$ROOT" ROUTE_EXPECTED="$route" PATH="$ROUTE_BIN:$PATH" \
        BDO_ORCHESTRATOR=php bash "$wrapper" --probe >"$TMP/$route.route" \
        || fail "$route routing proof"
    grep -Fq "ROUTED:$route" "$TMP/$route.route" || fail "$route marker missing"
done
if ROUTE_ROOT="$ROOT" ROUTE_EXPECTED=run-spec PATH="$ROUTE_BIN:$PATH" \
    "$ROUTE_BIN/php" "$ROOT/cli/bdo.php" wrong >/dev/null 2>&1; then
    fail 'fake php прийняв неправильний internal route'
fi

# ПРАВИЛО: status/plan є одним JSON-контрактом, preset/filter/create живуть у RunSpec.
# САБОТАЖ: втрата concrete patch/domain, режиму або boundary batch size має впасти.
for mode in patch manual proposal improve; do
    compare_spec "status-$mode" "$DEV_ENV" status "$mode"
done
compare_spec status-snapshot-domain "$DEV_ENV" status patch 123 quest
compare_spec status-snapshot-invalid-patch "$DEV_ENV" status patch nope
compare_spec status-invalid-domain "$DEV_ENV" status patch active not-a-domain
compare_spec status-invalid-mode "$DEV_ENV" status unknown
for size in 20 50 100; do
    compare_spec "plan-dev-$size" "$DEV_ENV" plan improve parent-session "$size"
done
compare_spec plan-prod "$PROD_ENV" plan patch parent-session 50
for size in 19 101; do
    compare_spec "plan-invalid-$size" "$DEV_ENV" plan patch parent-session "$size"
done
compare_spec plan-missing-parent "$DEV_ENV" plan patch '' 50
compare_spec unknown-action "$DEV_ENV" nope patch
grep -Fq 'Дозволено status або plan.' "$TMP/unknown-action.sh.err" || fail 'unknown action reason missing'
test "$(cat "$TMP/unknown-action.sh.code")" = 2 || fail 'unknown action code changed'

snapshot_state() {
    local state="$1" destination="$2" before="${3:-}" after="${4:-}" raw
    rm -rf "$destination"
    mkdir -p "$destination"
    find "$state" -print | sed "1d;s|^$state/||" | sort >"$destination/list"
    while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        mkdir -p "$destination/$(dirname "$relative")"
        if [ -d "$state/$relative" ]; then
            mkdir -p "$destination/$relative"
        elif [ "$relative" = run-started-at ] && [ -n "$before" ] && [ -n "$after" ]; then
            raw="$(<"$state/$relative")"
            timestamp_value_valid "$raw" "$before" "$after" \
                || fail "$state: run-started-at не є integer milliseconds у часовому вікні"
            printf 'TIMESTAMP\n' >"$destination/$relative"
        elif [ "$relative" = run-started-at ] && { [ -n "$before" ] || [ -n "$after" ]; }; then
            fail 'timestamp normalizer потребує обидві часові межі'
        elif [ -f "$state/$relative" ]; then
            cp "$state/$relative" "$destination/$relative"
        fi
    done <"$destination/list"
}

real_ms() {
    "$REAL_PHP" -r 'echo (int) floor(microtime(true) * 1000);'
}

timestamp_value_valid() {
    local raw="$1" before="$2" after="$3"
    [[ "$raw" =~ ^[0-9]+$ ]] || return 1
    local value=$((10#$raw))
    (( value >= before - 1500 && value <= after + 1500 ))
}

assert_start_timestamp() {
    local label="$1" state="$2" before="$3" after="$4" raw
    test -f "$state/run-started-at" || fail "$label: run-started-at відсутній"
    raw="$(<"$state/run-started-at")"
    timestamp_value_valid "$raw" "$before" "$after" \
        || fail "$label: run-started-at не є integer milliseconds у часовому вікні"
}

# ПРАВИЛО: timestamp можна нормалізувати лише після механічної перевірки raw value.
# САБОТАЖ: garbage або широкий normalizer мають зробити self-test червоним.
normalizer_self_test() {
    local state_a="$TMP/normalizer-state-a" state_b="$TMP/normalizer-state-b"
    local snapshot_a="$TMP/normalizer-snapshot-a" snapshot_b="$TMP/normalizer-snapshot-b"
    local state_valid="$TMP/normalizer-state-valid" snapshot_valid="$TMP/normalizer-snapshot-valid"
    local before now after
    mkdir -p "$state_a" "$state_b" "$state_valid"
    for state in "$state_a" "$state_b" "$state_valid"; do
        printf 'local\n' >"$state/run-target"
        printf '{"state":"verified","count":7}\n' >"$state/manifest.json"
        printf 'Невідома причина лишається\n' >"$state/error-reason"
    done
    printf '111\n' >"$state_a/run-started-at"
    printf '222\n' >"$state_b/run-started-at"
    snapshot_state "$state_a" "$snapshot_a"
    snapshot_state "$state_b" "$snapshot_b"
    cmp -s "$snapshot_a/run-started-at" "$snapshot_b/run-started-at" && \
        fail 'normalizer: raw timestamps без bounds порівнялись однаково'
    grep -Fxq '111' "$snapshot_a/run-started-at" || fail 'normalizer: raw timestamp 111 змінено'
    grep -Fxq '222' "$snapshot_b/run-started-at" || fail 'normalizer: raw timestamp 222 змінено'

    before="$(real_ms)"
    now="$(real_ms)"
    after="$(real_ms)"
    printf '%s\n' "$now" >"$state_valid/run-started-at"
    snapshot_state "$state_valid" "$snapshot_valid" "$before" "$after"
    grep -Fxq 'TIMESTAMP' "$snapshot_valid/run-started-at" || fail 'normalizer: timestamp не замінено після перевірки'
    cmp -s "$state_valid/run-target" "$snapshot_valid/run-target" || fail 'normalizer: змінив run-target'
    cmp -s "$state_valid/manifest.json" "$snapshot_valid/manifest.json" || fail 'normalizer: змінив manifest/state'
    cmp -s "$state_valid/error-reason" "$snapshot_valid/error-reason" || fail 'normalizer: змінив error reason'
    if timestamp_value_valid garbage "$((now - 1500))" "$((now + 1500))"; then
        fail 'normalizer: прийняв garbage як timestamp'
    fi
}

# ПРАВИЛО: кожен успішний start має raw integer-millisecond timestamp у вікні запуску.
# САБОТАЖ: seconds/garbage не можуть пройти підміною на TIMESTAMP.
normalizer_self_test

compare_start() {
    local label="$1" env="$2"; shift 2
    local sh_before sh_after php_before php_after
    CURRENT_ENV="$env" CURRENT_STATE="$TMP/$label-state-sh"
    rm -rf "$CURRENT_STATE"
    mkdir -p "$CURRENT_STATE"
    sh_before="$(real_ms)"
    run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.sh.out" "$TMP/$label.sh.err" "$TMP/$label.sh.code" "$@"
    sh_after="$(real_ms)"
    CURRENT_STATE="$TMP/$label-state-php"
    rm -rf "$CURRENT_STATE"
    mkdir -p "$CURRENT_STATE"
    php_before="$(real_ms)"
    run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.php.out" "$TMP/$label.php.err" "$TMP/$label.php.code" "$@"
    php_after="$(real_ms)"
    compare_outputs "$label" "$TMP/$label.sh.out" "$TMP/$label.php.out" "$TMP/$label.sh.err" "$TMP/$label.php.err" "$TMP/$label.sh.code" "$TMP/$label.php.code"
    if [ "$(cat "$TMP/$label.sh.code")" = 0 ]; then
        case "${1:-}" in
            --show|--end) ;;
            *)
                assert_start_timestamp "$label shell" "$TMP/$label-state-sh" "$sh_before" "$sh_after"
                assert_start_timestamp "$label php" "$TMP/$label-state-php" "$php_before" "$php_after"
                ;;
        esac
    fi
    if [ "$(cat "$TMP/$label.sh.code")" = 0 ]; then
        case "${1:-}" in
            --show|--end)
                snapshot_state "$TMP/$label-state-sh" "$TMP/$label-snapshot-sh"
                snapshot_state "$TMP/$label-state-php" "$TMP/$label-snapshot-php"
                ;;
            *)
                snapshot_state "$TMP/$label-state-sh" "$TMP/$label-snapshot-sh" "$sh_before" "$sh_after"
                snapshot_state "$TMP/$label-state-php" "$TMP/$label-snapshot-php" "$php_before" "$php_after"
                ;;
        esac
    else
        snapshot_state "$TMP/$label-state-sh" "$TMP/$label-snapshot-sh"
        snapshot_state "$TMP/$label-state-php" "$TMP/$label-snapshot-php"
    fi
    cmp -s "$TMP/$label-snapshot-sh/list" "$TMP/$label-snapshot-php/list" || fail "$label: state files differ"
    diff -ru "$TMP/$label-snapshot-sh" "$TMP/$label-snapshot-php" >/dev/null || fail "$label: state content differs"
}

prepare_reset_state() {
    local state="$1"
    mkdir -p "$state"
    for file in run-target run-started-at run-batches.json run-seen.json; do
        printf '%s\n' marker >"$state/$file"
    done
    printf '%s\n' protected >"$state/protected"
}

# ПРАВИЛО: --show/--end локальні, а end видаляє рівно чотири reset files.
# САБОТАЖ: env read або зайве видалення state має зробити differential red.
compare_start show-empty '' --show
mkdir -p "$TMP/show-state-sh" "$TMP/show-state-php"
printf 'hub-local\n' >"$TMP/show-state-sh/run-target"
printf 'hub-local\n' >"$TMP/show-state-php/run-target"
CURRENT_ENV="$TMP/missing.env" CURRENT_STATE="$TMP/show-state-sh" run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/show.sh.out" "$TMP/show.sh.err" "$TMP/show.sh.code" --show
CURRENT_STATE="$TMP/show-state-php" run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/show.php.out" "$TMP/show.php.err" "$TMP/show.php.code" --show
compare_outputs show-target "$TMP/show.sh.out" "$TMP/show.php.out" "$TMP/show.sh.err" "$TMP/show.php.err" "$TMP/show.sh.code" "$TMP/show.php.code"
prepare_reset_state "$TMP/end-state-sh"
prepare_reset_state "$TMP/end-state-php"
CURRENT_ENV="$TMP/missing.env" CURRENT_STATE="$TMP/end-state-sh" run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/end.sh.out" "$TMP/end.sh.err" "$TMP/end.sh.code" --end
CURRENT_STATE="$TMP/end-state-php" run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/end.php.out" "$TMP/end.php.err" "$TMP/end.php.code" --end
compare_outputs end "$TMP/end.sh.out" "$TMP/end.php.out" "$TMP/end.sh.err" "$TMP/end.php.err" "$TMP/end.sh.code" "$TMP/end.php.code"
test -f "$TMP/end-state-sh/protected" && test ! -e "$TMP/end-state-sh/run-target" || fail '--end removed wrong files'

for target_env in "$DEV_ENV" "$PROD_ENV" "$HUB_DEV_ENV" "$HUB_PROD_ENV"; do
    compare_start "fresh-$(basename "$target_env" .env)" "$target_env"
done

for entry in \
    'DEV local' 'DEV dev' 'DEV localhost' \
    'PROD prod' 'PROD production' \
    'HUBDEV hub-dev' 'HUBDEV hub-local' \
    'HUBPROD hub-prod' 'HUBPROD hub-production'; do
    set -- $entry
    env_name="$1"
    case "$env_name" in
        DEV) env_file="$DEV_ENV" ;;
        PROD) env_file="$PROD_ENV" ;;
        HUBDEV) env_file="$HUB_DEV_ENV" ;;
        HUBPROD) env_file="$HUB_PROD_ENV" ;;
    esac
    compare_start "alias-$env_name-$2" "$env_file" "$2"
done
compare_start invalid-confirm "$DEV_ENV" invalid
grep -Fq 'Дозволено DEV, PROD' "$TMP/invalid-confirm.sh.err" || fail 'invalid confirmation reason missing'
compare_start mismatch "$DEV_ENV" prod
grep -Fq 'не збігається' "$TMP/mismatch.sh.err" || fail 'confirmation mismatch reason missing'

foreign_state() {
    local state="$1" batch_state="$2"
    mkdir -p "$state/batches/foreign"
    printf 'foreign\n' >"$state/run-target"
    printf 'foreign\n' >"$state/run-started-at"
    printf '{}\n' >"$state/run-batches.json"
    printf '{}\n' >"$state/run-seen.json"
    printf 'foreign\n' >"$state/current-batch"
    printf '{"state":"%s"}\n' "$batch_state" >"$state/batches/foreign/manifest.json"
}

# ПРАВИЛО: foreign awaiting_worker не перетинає target; terminal/none дозволяють reset.
# САБОТАЖ: дозвіл active foreign batch має змінити target/state і впасти.
for state_case in none verified failed_terminal awaiting_worker; do
    sh_before=''
    sh_after=''
    php_before=''
    php_after=''
    for side in sh php; do
        state="$TMP/foreign-$state_case-$side"
        if [ "$state_case" = none ]; then
            mkdir -p "$state"
            printf 'foreign\n' >"$state/run-target"
            printf marker >"$state/run-started-at"
            printf marker >"$state/run-batches.json"
            printf marker >"$state/run-seen.json"
        else
            foreign_state "$state" "$state_case"
        fi
    done
    CURRENT_STATE="$TMP/foreign-$state_case-sh"
    CURRENT_ENV="$DEV_ENV"
    sh_before="$(real_ms)"
    run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/foreign-$state_case.sh.out" "$TMP/foreign-$state_case.sh.err" "$TMP/foreign-$state_case.sh.code"
    sh_after="$(real_ms)"
    CURRENT_STATE="$TMP/foreign-$state_case-php"
    php_before="$(real_ms)"
    run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/foreign-$state_case.php.out" "$TMP/foreign-$state_case.php.err" "$TMP/foreign-$state_case.php.code"
    php_after="$(real_ms)"
    compare_outputs "foreign-$state_case" "$TMP/foreign-$state_case.sh.out" "$TMP/foreign-$state_case.php.out" "$TMP/foreign-$state_case.sh.err" "$TMP/foreign-$state_case.php.err" "$TMP/foreign-$state_case.sh.code" "$TMP/foreign-$state_case.php.code"
    if [ "$(cat "$TMP/foreign-$state_case.sh.code")" = 0 ]; then
        assert_start_timestamp "foreign-$state_case shell" "$TMP/foreign-$state_case-sh" "$sh_before" "$sh_after"
        assert_start_timestamp "foreign-$state_case php" "$TMP/foreign-$state_case-php" "$php_before" "$php_after"
    fi
    if [ "$(cat "$TMP/foreign-$state_case.sh.code")" = 0 ]; then
        snapshot_state "$TMP/foreign-$state_case-sh" "$TMP/foreign-$state_case-snapshot-sh" "$sh_before" "$sh_after"
        snapshot_state "$TMP/foreign-$state_case-php" "$TMP/foreign-$state_case-snapshot-php" "$php_before" "$php_after"
    else
        snapshot_state "$TMP/foreign-$state_case-sh" "$TMP/foreign-$state_case-snapshot-sh"
        snapshot_state "$TMP/foreign-$state_case-php" "$TMP/foreign-$state_case-snapshot-php"
    fi
    if [ "$state_case" = awaiting_worker ]; then
        test "$(cat "$TMP/foreign-$state_case.sh.code")" = 1 || fail 'awaiting_worker crossed target'
        grep -Fq 'ЗАБЛОКОВАНО' "$TMP/foreign-$state_case.sh.err" || fail 'active foreign block not named'
        for file in run-target run-started-at run-batches.json run-seen.json current-batch; do
            cmp -s "$TMP/foreign-$state_case-sh/$file" "$TMP/foreign-$state_case-php/$file" || \
                fail "foreign-awaiting_worker: $file state differs"
        done
        cmp -s "$TMP/foreign-$state_case-sh/batches/foreign/manifest.json" "$TMP/foreign-$state_case-php/batches/foreign/manifest.json" || \
            fail 'foreign-awaiting_worker: manifest state differs'
    fi
    diff -ru "$TMP/foreign-$state_case-snapshot-sh" "$TMP/foreign-$state_case-snapshot-php" >/dev/null || fail "foreign-$state_case state differs"
done

# ПРАВИЛО: reset filesystem failures are fail-closed and name the path; both --end
# and stale-target cleanup use the same four-file set without deleting directories.
# САБОТАЖ: unchecked unlink may claim success or produce a different state shape.
prepare_reset_failure_state() {
    local state="$1"
    mkdir -p "$state"
    printf 'foreign\n' >"$state/run-target"
    printf 'marker\n' >"$state/run-started-at"
    mkdir -p "$state/run-batches.json"
    printf 'marker\n' >"$state/run-seen.json"
    printf 'protected\n' >"$state/protected"
}

compare_reset_failure() {
    local label="$1" mode="$2"
    prepare_reset_failure_state "$TMP/$label-state-sh"
    prepare_reset_failure_state "$TMP/$label-state-php"
    if [ "$mode" = end ]; then
        CURRENT_ENV="$TMP/missing.env"
        CURRENT_STATE="$TMP/$label-state-sh"
        run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.sh.out" "$TMP/$label.sh.err" "$TMP/$label.sh.code" --end
        CURRENT_STATE="$TMP/$label-state-php"
        run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.php.out" "$TMP/$label.php.err" "$TMP/$label.php.code" --end
    else
        CURRENT_ENV="$DEV_ENV"
        CURRENT_STATE="$TMP/$label-state-sh"
        run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.sh.out" "$TMP/$label.sh.err" "$TMP/$label.sh.code"
        CURRENT_STATE="$TMP/$label-state-php"
        run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.php.out" "$TMP/$label.php.err" "$TMP/$label.php.code"
    fi
    test "$(cat "$TMP/$label.sh.code")" != 0 || fail "$label: shell reset failure стала успішною"
    test "$(cat "$TMP/$label.php.code")" != 0 || fail "$label: PHP reset failure стала успішною"
    grep -Fq 'run-batches.json' "$TMP/$label.sh.err" || fail "$label: shell не назвав проблемний path"
    grep -Fq 'run-batches.json' "$TMP/$label.php.err" || fail "$label: PHP не назвав проблемний path"
    snapshot_state "$TMP/$label-state-sh" "$TMP/$label-snapshot-sh"
    snapshot_state "$TMP/$label-state-php" "$TMP/$label-snapshot-php"
    diff -ru "$TMP/$label-snapshot-sh" "$TMP/$label-snapshot-php" >/dev/null || fail "$label: state composition differs"
}

compare_reset_failure reset-end end
compare_reset_failure reset-stale start

# ПРАВИЛО: unreadable regular run-target is an I/O failure, never an empty success.
# САБОТАЖ: failed fopen/file_get_contents may otherwise become empty state.
unreadable_state="$TMP/unreadable-state"
mkdir -p "$unreadable_state"
printf 'local\n' >"$unreadable_state/run-target"
chmod 000 "$unreadable_state/run-target"
if [ -r "$unreadable_state/run-target" ]; then
    chmod 644 "$unreadable_state/run-target"
    printf 'unreadable run-target: SKIP (filesystem permissions remain readable)\n'
else
    CURRENT_ENV="$TMP/missing.env" CURRENT_STATE="$unreadable_state"
    run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/unreadable-show.sh.out" "$TMP/unreadable-show.sh.err" "$TMP/unreadable-show.sh.code" --show
    CURRENT_STATE="$unreadable_state"
    run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/unreadable-show.php.out" "$TMP/unreadable-show.php.err" "$TMP/unreadable-show.php.code" --show
    test "$(cat "$TMP/unreadable-show.sh.code")" != 0 || fail 'unreadable --show: shell стала успішною'
    test "$(cat "$TMP/unreadable-show.php.code")" != 0 || fail 'unreadable --show: PHP стала успішною'
    grep -Fq 'run-target' "$TMP/unreadable-show.sh.err" || fail 'unreadable --show: shell не назвала path'
    grep -Fq 'run-target' "$TMP/unreadable-show.php.err" || fail 'unreadable --show: PHP не назвала path'
    CURRENT_ENV="$DEV_ENV" CURRENT_STATE="$unreadable_state"
    run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/unreadable-start.sh.out" "$TMP/unreadable-start.sh.err" "$TMP/unreadable-start.sh.code"
    CURRENT_STATE="$unreadable_state"
    run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/unreadable-start.php.out" "$TMP/unreadable-start.php.err" "$TMP/unreadable-start.php.code"
    test "$(cat "$TMP/unreadable-start.sh.code")" != 0 || fail 'unreadable start: shell стала успішною'
    test "$(cat "$TMP/unreadable-start.php.code")" != 0 || fail 'unreadable start: PHP стала успішною'
    grep -Fq 'run-target' "$TMP/unreadable-start.sh.err" || fail 'unreadable start: shell не назвала path'
    grep -Fq 'run-target' "$TMP/unreadable-start.php.err" || fail 'unreadable start: PHP не назвала path'
fi

# ПРАВИЛО: native Run PHP code не залежить від Unix helpers і не робить network calls.
# САБОТАЖ: повернення subprocess зробило б direct PHP proof червоним.
NO_UNIX="$TMP/no-unix"
mkdir -p "$NO_UNIX"
for command in bash date rm tr head; do
    printf '#!/bin/sh\nexit 99\n' >"$NO_UNIX/$command"
    chmod +x "$NO_UNIX/$command"
done
PATH="$NO_UNIX" TRANSLATE_ENV_FILE="$DEV_ENV" BDO_STATE_DIR="$TMP/no-unix-state" \
    "$REAL_PHP" "$ROOT/cli/bdo.php" run-spec status patch >"$TMP/no-unix-spec.out" 2>"$TMP/no-unix-spec.err" \
    || fail 'direct RunSpec PHP no-Unix proof'
PATH="$NO_UNIX" BDO_STATE_DIR="$TMP/no-unix-show" \
    "$REAL_PHP" "$ROOT/cli/bdo.php" run-start --show >"$TMP/no-unix-start.out" 2>"$TMP/no-unix-start.err" \
    || fail 'direct RunStart PHP no-Unix proof'

printf 'cli run foundation parity: routing, RunSpec matrix, target locking, state side effects і no-Unix proof: OK\n'
