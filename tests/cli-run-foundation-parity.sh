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
    local label="$1" shell_err="$2" php_err="$3" shell_code="$4" php_code="$5"
    test "$(cat "$shell_code")" != 0 || fail "$label: failure стала успішною"
    test "$(cat "$php_code")" != 0 || fail "$label: PHP failure стала успішною"
    test -s "$shell_err" || fail "$label: shell не назвав причину"
    test -s "$php_err" || fail "$label: PHP не назвав причину"
}

compare_spec() {
    local label="$1" env="$2"; shift 2
    CURRENT_ENV="$env" CURRENT_STATE="$TMP/spec-state-sh"
    run_command sh "$ROOT/cli/run/run-spec.sh" run-spec "$TMP/$label.sh.out" "$TMP/$label.sh.err" "$TMP/$label.sh.code" "$@"
    CURRENT_STATE="$TMP/spec-state-php"
    run_command php "$ROOT/cli/run/run-spec.sh" run-spec "$TMP/$label.php.out" "$TMP/$label.php.err" "$TMP/$label.php.code" "$@"
    case "$label" in
        *invalid*|*missing*)
            compare_failure_codes "$label" "$TMP/$label.sh.err" "$TMP/$label.php.err" "$TMP/$label.sh.code" "$TMP/$label.php.code"
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
    local state="$1" destination="$2"
    rm -rf "$destination"
    mkdir -p "$destination"
    find "$state" -type f -print | sed "s|^$state/||" | sort >"$destination/list"
    while IFS= read -r relative; do
        [ -n "$relative" ] || continue
        mkdir -p "$destination/$(dirname "$relative")"
        if [ "$relative" = run-started-at ]; then
            printf 'TIMESTAMP\n' >"$destination/$relative"
        else
            cp "$state/$relative" "$destination/$relative"
        fi
    done <"$destination/list"
}

compare_start() {
    local label="$1" env="$2"; shift 2
    CURRENT_ENV="$env" CURRENT_STATE="$TMP/$label-state-sh"
    rm -rf "$CURRENT_STATE"
    mkdir -p "$CURRENT_STATE"
    run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.sh.out" "$TMP/$label.sh.err" "$TMP/$label.sh.code" "$@"
    CURRENT_STATE="$TMP/$label-state-php"
    rm -rf "$CURRENT_STATE"
    mkdir -p "$CURRENT_STATE"
    run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/$label.php.out" "$TMP/$label.php.err" "$TMP/$label.php.code" "$@"
    compare_outputs "$label" "$TMP/$label.sh.out" "$TMP/$label.php.out" "$TMP/$label.sh.err" "$TMP/$label.php.err" "$TMP/$label.sh.code" "$TMP/$label.php.code"
    snapshot_state "$TMP/$label-state-sh" "$TMP/$label-snapshot-sh"
    snapshot_state "$TMP/$label-state-php" "$TMP/$label-snapshot-php"
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
    run_command sh "$ROOT/cli/run/run-start.sh" run-start "$TMP/foreign-$state_case.sh.out" "$TMP/foreign-$state_case.sh.err" "$TMP/foreign-$state_case.sh.code"
    CURRENT_STATE="$TMP/foreign-$state_case-php"
    run_command php "$ROOT/cli/run/run-start.sh" run-start "$TMP/foreign-$state_case.php.out" "$TMP/foreign-$state_case.php.err" "$TMP/foreign-$state_case.php.code"
    compare_outputs "foreign-$state_case" "$TMP/foreign-$state_case.sh.out" "$TMP/foreign-$state_case.php.out" "$TMP/foreign-$state_case.sh.err" "$TMP/foreign-$state_case.php.err" "$TMP/foreign-$state_case.sh.code" "$TMP/foreign-$state_case.php.code"
    snapshot_state "$TMP/foreign-$state_case-sh" "$TMP/foreign-$state_case-snapshot-sh"
    snapshot_state "$TMP/foreign-$state_case-php" "$TMP/foreign-$state_case-snapshot-php"
    diff -ru "$TMP/foreign-$state_case-snapshot-sh" "$TMP/foreign-$state_case-snapshot-php" >/dev/null || fail "foreign-$state_case state differs"
    if [ "$state_case" = awaiting_worker ]; then
        test "$(cat "$TMP/foreign-$state_case.sh.code")" = 1 || fail 'awaiting_worker crossed target'
        grep -Fq 'ЗАБЛОКОВАНО' "$TMP/foreign-$state_case.sh.err" || fail 'active foreign block not named'
    fi
done

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
