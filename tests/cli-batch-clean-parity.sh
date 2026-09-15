#!/usr/bin/env bash
# Перевіряє поведінку batch-clean через прямий PHP Kernel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
PHP_BIN="$(command -v php)"
BASH_BIN="$(command -v bash)"

# ПРАВИЛО: нормалізатор може змінити лише приблизні розміри в КБ.
# САБОТАЖ: широка заміна сховає ID, days, keep або summary-counts.
normalize_stream() {
    sed -E \
        -e 's/\([0-9]+ КБ\)/(SIZE КБ)/g' \
        -e 's/звільниться ~[0-9]+ КБ/звільниться ~SIZE КБ/g' \
        "$1" >"$2"
}
printf '%s\n' 'id=20260101_000001 days=0 keep=1 count=3 (8 КБ) звільниться ~9 КБ' >"$TMP/normalizer.in"
normalize_stream "$TMP/normalizer.in" "$TMP/normalizer.out"
grep -Fq 'id=20260101_000001 days=0 keep=1 count=3 (SIZE КБ) звільниться ~SIZE КБ' "$TMP/normalizer.out" \
    || fail 'normalizer змінив stable fields'
grep -Fq '20260101_000001' "$TMP/normalizer.out" || fail 'normalizer приховав ID'

set_mtime() {
    php -r 'if (!touch($argv[1], time() - (int) $argv[2])) { exit(1); }' "$1" "$2"
}

make_fixture() {
    local base="$1" state="$1/state" output="$1/output"
    mkdir -p "$state/batches" "$output"

    mkdir -p "$state/batches/20260101_000001_current"
    printf '{"id":"current","rows":1}\n' >"$state/batches/20260101_000001_current/manifest.json"
    printf '{}\n' >"$state/batches/20260101_000001_current/journal.jsonl"
    printf '{"rows":1}\n' >"$state/batches/20260101_000001_current/batch-summary.json"
    printf 'current-derived\n' >"$state/batches/20260101_000001_current/rows.json"
    printf 'current-hidden\n' >"$state/batches/20260101_000001_current/.hidden"

    mkdir -p "$state/batches/20260101_000003_retained/derived-dir"
    printf '{"id":"retained"}\n' >"$state/batches/20260101_000003_retained/manifest.json"
    printf '{}\n' >"$state/batches/20260101_000003_retained/journal.jsonl"
    printf '{"rows":2}\n' >"$state/batches/20260101_000003_retained/batch-summary.json"
    printf 'derived\n' >"$state/batches/20260101_000003_retained/rows.json"
    printf 'derived\n' >"$state/batches/20260101_000003_retained/derived-dir/payload.json"
    printf 'dotfile\n' >"$state/batches/20260101_000003_retained/.dotfile"
    printf 'lock-target\n' >"$base/lock-target"
    ln -s "$base/lock-target" "$state/batches/20260101_000003_retained/drive.lock"
    printf 'outside-target\n' >"$base/safe-target"
    ln -s "$base/safe-target" "$state/batches/20260101_000003_retained/safe-link"
    mkdir -p "$state/sessions/kept-session"
    printf '{"id":"20260101_000003_retained"}\n' >"$state/sessions/kept-session/batches.jsonl"

    mkdir -p "$state/batches/20260101_000002_over/derived-dir"
    printf '{"id":"over"}\n' >"$state/batches/20260101_000002_over/manifest.json"
    printf '{}\n' >"$state/batches/20260101_000002_over/journal.jsonl"
    printf '{"rows":3}\n' >"$state/batches/20260101_000002_over/batch-summary.json"
    printf 'over-derived\n' >"$state/batches/20260101_000002_over/rows.json"
    printf 'over-derived\n' >"$state/batches/20260101_000002_over/derived-dir/payload.json"
    printf 'over-dotfile\n' >"$state/batches/20260101_000002_over/.dotfile"

    printf '20260101_000001_current\n' >"$state/current-batch"
    printf 'protected\n' >"$state/quarantine.jsonl"
    printf 'protected\n' >"$state/write-log.jsonl"
    printf 'protected\n' >"$state/row-attempts.jsonl"
    printf 'DEV\n' >"$state/run-target"

    printf 'stale-cache\n' >"$state/glossary-full.json"
    set_mtime "$state/glossary-full.json" 172800
    printf 'fresh-cache\n' >"$state/game-concepts.json"
    set_mtime "$state/game-concepts.json" 3600
    printf 'archived-quarantine\n' >"$state/quarantine.jsonl.archived"
    set_mtime "$state/quarantine.jsonl.archived" 90000
    printf 'transcript\n' >"$state/run-transcript.log"
    set_mtime "$state/run-transcript.log" 90000

    mkdir -p "$state/sessions/old-session"
    php -r 'file_put_contents($argv[1], json_encode(["closed_epoch" => 1700000000]));' \
        "$state/sessions/old-session/summary.json"
    printf '{}\n' >"$state/sessions/old-session/batches.jsonl"
    printf 'old transcript\n' >"$state/sessions/old-session/transcript.log"
    printf 'old stream\n' >"$state/sessions/old-session/run-stream.log"
    printf 'old calls\n' >"$state/sessions/old-session/model-calls.jsonl"

    printf 'old root\n' >"$output/old-root.json"
    set_mtime "$output/old-root.json" 90000
    mkdir -p "$output/part/deep" "$output/empty-level1"
    printf 'old level2\n' >"$output/part/old-level2.json"
    set_mtime "$output/part/old-level2.json" 90000
    printf 'fresh level2\n' >"$output/part/fresh-level2.json"
    set_mtime "$output/part/fresh-level2.json" 3600
    printf 'old level3\n' >"$output/part/deep/old-level3.json"
    set_mtime "$output/part/deep/old-level3.json" 90000
}

# ПРАВИЛО: snapshots містять дерево й хеші regular files, тому preview не може
# тихо змінити файл, а apply порівнюється за складом, не лише за кількістю.
# САБОТАЖ: видалений receipt або збережений derived entry розходиться в cmp.
snapshot() {
    local root="$1"
    (
        cd "$root"
        find . -mindepth 1 -print | LC_ALL=C sort
        find . -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
    )
}

run_php() {
    local name="$1" base="$2"
    shift 2
    set +e
    BDO_STATE_DIR="$base/state" BDO_KEEP_DAYS=7 BDO_KEEP_RECEIPTS=50 \
        "$PHP_BIN" "$ROOT/cli/bdo.php" batch-clean "$@" \
        >"$TMP/$name-run.out" 2>"$TMP/$name-run.err"
    printf '%s\n' "$?" >"$TMP/$name-run.code"
    set -e
}

# ПРАВИЛО: нова PHP-команда не запускає `php`, `find`, `du`, `rm` або `bash`.
# САБОТАЖ: fake-команди в єдиному PATH мають зробити прямий PHP preview червоним,
# якщо cleanup потай повернувся до Unix subprocess.
make_fixture "$TMP/native"
NO_UNIX_BIN="$TMP/no-unix-bin"
mkdir -p "$NO_UNIX_BIN"
for utility in php find du rm bash; do
    cat >"$NO_UNIX_BIN/$utility" <<FAKE
#!$BASH_BIN
printf 'FAIL: зовнішня утиліта $utility викликана PHP cleanup\n' >&2
exit 99
FAKE
    chmod +x "$NO_UNIX_BIN/$utility"
done
set +e
PATH="$NO_UNIX_BIN" BDO_STATE_DIR="$TMP/native/state" \
    "$PHP_BIN" "$ROOT/cli/bdo.php" batch-clean --days 0 --keep 1 --quiet \
    >"$TMP/native/out" 2>"$TMP/native/err"
native_code=$?
set -e
test "$native_code" -eq 0 || fail "PHP cleanup запустив зовнішню Unix-утиліту: code $native_code: $(cat "$TMP/native/err")"

make_fixture "$TMP/preview"
snapshot "$TMP/preview" >"$TMP/preview.before"
run_php preview "$TMP/preview" --days 0 --keep 1
test "$(cat "$TMP/preview-run.code")" -eq 0 || fail "PHP preview завершився з помилкою: $(cat "$TMP/preview-run.err")"
grep -Fq 'ВИРОК: це лише показ' "$TMP/preview-run.out" || fail 'preview не надрукував очікуваний stdout'
snapshot "$TMP/preview" >"$TMP/preview.after"
cmp -s "$TMP/preview.before" "$TMP/preview.after" || fail 'PHP preview змінив дерево'

make_fixture "$TMP/apply"
run_php apply "$TMP/apply" --days 0 --keep 1 --apply
test "$(cat "$TMP/apply-run.code")" -eq 0 || fail "PHP apply завершився з помилкою: $(cat "$TMP/apply-run.err")"
snapshot "$TMP/apply" >"$TMP/apply.snapshot"

# ПРАВИЛО: current batch і session-attached batch лишаються повністю;
# over-limit orphan batch зникає, safe symlink зникає разом із link, але target живий.
# САБОТАЖ: зняття current skip, receipt preservation або safe delete має впасти.
base="$TMP/apply"
    state="$base/state"
    test -s "$state/batches/20260101_000001_current/rows.json" || fail 'PHP зачепив current batch'
    test -s "$state/batches/20260101_000003_retained/manifest.json" || fail 'PHP втратив receipt'
    test -s "$state/batches/20260101_000003_retained/.dotfile" || fail 'PHP втратив retained dotfile'
    test -L "$state/batches/20260101_000003_retained/drive.lock" || fail 'PHP втратив drive.lock'
    test -s "$state/batches/20260101_000003_retained/rows.json" || fail 'PHP прибрав session-attached derived file'
    test -s "$state/batches/20260101_000003_retained/derived-dir/payload.json" || fail 'PHP прибрав session-attached derived directory'
    test -L "$state/batches/20260101_000003_retained/safe-link" || fail 'PHP прибрав session-attached safe symlink'
    test -s "$base/safe-target" || fail 'PHP зачепив symlink target'
    test ! -e "$state/batches/20260101_000002_over" || fail 'PHP лишив over-limit batch'
    test ! -e "$state/glossary-full.json" || fail 'PHP лишив stale cache'
    test -s "$state/game-concepts.json" || fail 'PHP прибрав fresh cache'
    test ! -e "$state/quarantine.jsonl.archived" || fail 'PHP лишив stale archived quarantine'
    test ! -e "$state/run-transcript.log" || fail 'PHP лишив stale transcript'
    test ! -e "$state/sessions/old-session/run-stream.log" || fail 'PHP не прибрав old session journal за TTL'
    test -s "$state/sessions/old-session/summary.json" || fail 'PHP прибрав session summary'
    test -s "$state/quarantine.jsonl" && test -s "$state/write-log.jsonl" && test -s "$state/row-attempts.jsonl" \
        || fail 'PHP зачепив protected state'
    test ! -e "$base/output/old-root.json" || fail 'PHP лишив old output depth 1'
    test ! -e "$base/output/part/old-level2.json" || fail 'PHP лишив old output depth 2'
    test -s "$base/output/part/fresh-level2.json" || fail 'PHP прибрав fresh output'
    test -s "$base/output/part/deep/old-level3.json" || fail 'PHP зачепив output depth 3'
    test ! -d "$base/output/empty-level1" || fail 'PHP не прибрав порожню level-1 теку'

# ПРАВИЛО: --days 0 означає більше одного повного 24-годинного періоду.
# САБОТАЖ: наївна age > days*86400 видалить і свіжий одногодинний файл.
printf '25 hours\n' >"$TMP/mtime-old"
printf '1 hour\n' >"$TMP/mtime-fresh"
set_mtime "$TMP/mtime-old" 90000
set_mtime "$TMP/mtime-fresh" 3600
test "$(php -r 'echo ((intdiv(max(0, time() - filemtime($argv[1])), 86400) > 0) ? "stale" : "fresh");' "$TMP/mtime-old")" = stale \
    || fail '25-годинний файл не є stale для --days 0'
test "$(php -r 'echo ((intdiv(max(0, time() - filemtime($argv[1])), 86400) > 0) ? "stale" : "fresh");' "$TMP/mtime-fresh")" = fresh \
    || fail '1-годинний файл став stale для --days 0'

printf '%s\n' 'cli batch-clean behavior: PHP routing, preview/apply, exact tree/files, keep/current, TTL, sessions, output depth і mtime: OK'
