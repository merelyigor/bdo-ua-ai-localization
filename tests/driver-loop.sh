#!/usr/bin/env bash
# Драйвер мусить робити рівно те, що каже конверт, і зупинятися з причиною.
# Цей тест ганяє ОДНАКОВІ envelope fixtures через frozen shell і native PHP.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

setup_side() {
    local side="$1" base="$WORK/$1"
    mkdir -p "$base/cli/run" "$base/cli/model" "$base/cli/system" "$base/state" "$base/lib"
    cp "$ROOT/cli/run/run-loop.sh" "$base/cli/run/run-loop.sh"
    cp "$ROOT/cli/system/timed.sh" "$base/cli/system/timed.sh"
    cp -R "$ROOT/lib/." "$base/lib/"
    cp "$ROOT/cli/command-registry.json" "$base/cli/command-registry.json"
    if [ "$side" = sh ]; then
        cat > "$base/bdo" <<'SH'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$*" >> "$HERE/state/calls.log"
if [ "$1 $2" = "run drive" ]; then
    if [ -n "${FAKE_DRIVE_BOOM:-}" ]; then
        printf 'Fatal error: %s\n' "$FAKE_DRIVE_BOOM" >&2
        exit 1
    fi
    test -z "${FAKE_DRIVE_SIGNAL:-}" || exit "$FAKE_DRIVE_SIGNAL"
    step="$(head -1 "$HERE/state/scenario")"
    sed -i.bak '1d' "$HERE/state/scenario" && rm -f "$HERE/state/scenario.bak"
    test -f "$HERE/state/noise" && cat "$HERE/state/noise"
    printf '%s\n' "$step"
    exit 0
fi
exit 0
SH
        chmod +x "$base/bdo"
        # Звіт кроку · PHP-команда навіть у rollback-гілці (підетап 7.2), тому
        # фальшивий репортер потрібен і тут: bash-двійника більше не існує.
        cat > "$base/cli/bdo.php" <<'PHP'
<?php
declare(strict_types=1);
if (($argv[1] ?? '') === 'step-report') {
    echo "reporter marker\n";
    exit(getenv('FAKE_REPORT_FAILS') === '1' ? 9 : 0);
}
exit(0);
PHP
    else
        cat > "$base/cli/bdo.php" <<'PHP'
<?php
declare(strict_types=1);
$root = dirname(__DIR__);
$state = $root.'/state';
$arguments = array_slice($argv, 1);
file_put_contents($state.'/calls.log', implode(' ', $arguments)."\n", FILE_APPEND);
$name = $arguments[0] ?? '';
if ($name === 'run-drive') {
    if (($boom = getenv('FAKE_DRIVE_BOOM')) !== false && $boom !== '') {
        fwrite(STDERR, "Fatal error: {$boom}\n"); exit(1);
    }
    $signal = getenv('FAKE_DRIVE_SIGNAL');
    if ($signal !== false && $signal !== '') exit((int) $signal);
    $lines = is_file($state.'/scenario') ? file($state.'/scenario', FILE_IGNORE_NEW_LINES) : [];
    $step = (string) array_shift($lines);
    file_put_contents($state.'/scenario', implode("\n", $lines).($lines === [] ? '' : "\n"));
    if (is_file($state.'/noise')) echo (string) file_get_contents($state.'/noise');
    echo $step."\n";
    exit(0);
}
if ($name === 'run-mode') exit(0);
// Підетап 7.2: звіт кроку є PHP-командою, тому фальшивий репортер живе тут, а
// не окремим bash-файлом · інакше пісочниця кликала б справжній звіт і вимагала
// справжніх payload-файлів.
if ($name === 'step-report') {
    echo "reporter marker\n";
    $fails = getenv('FAKE_REPORT_FAILS');
    exit($fails === '1' ? 9 : 0);
}
require $root.'/lib/autoload.php';
exit((new Bdo\Translate\Cli\Kernel())->run($arguments));
PHP
    fi
    cat > "$base/cli/model/client.php" <<'PHP'
<?php
file_put_contents(dirname(__DIR__, 2).'/state/roles.log', ($argv[1] ?? '')."\n", FILE_APPEND);
if (getenv('FAKE_CHILD_FAILS') === '1') {
    fwrite(STDERR, "empty_content: тест\n");
    exit(1);
}
file_put_contents($argv[3], "[]\n");
exit(0);
PHP
}

setup_side sh
setup_side php

scenario() {
    local base="$WORK/$ACTIVE"
    printf '%s\n' "$@" > "$base/state/scenario"
    : > "$base/state/calls.log"
    : > "$base/state/roles.log"
}

scenario_both() {
    for ACTIVE in sh php; do scenario "$@"; done
}

run_side() {
    local side="$1" base="$WORK/$1"; shift
    set +e
    (cd "$base" && BDO_STATE_DIR="$base/state" BDO_ORCHESTRATOR="$side" BDO_STEP_REPORT="${RUN_REPORT:-0}" bash cli/run/run-loop.sh "$@") >"$base/stdout" 2>"$base/stderr"
    local code=$?
    set -e
    printf '%s\n' "$code" > "$base/code"
}

run_both() {
    for side in sh php; do run_side "$side" "$@"; done
}

expect_codes() {
    local expected="$1"
    for side in sh php; do
        test "$(cat "$WORK/$side/code")" = "$expected" \
            || fail "$side code $(cat "$WORK/$side/code"), expected $expected"
    done
}

output() { cat "$WORK/$1/stdout" "$WORK/$1/stderr"; }
expect_each() {
    local pattern="$1"
    for side in sh php; do grep -Fq "$pattern" <(output "$side") \
        || fail "$side output misses: $pattern"; done
}

normalize() { sed -E 's/^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] /[TIME] /' "$1"; }
compare_streams() {
    local stream="$1"
    local a="$WORK/sh/$stream.norm" b="$WORK/php/$stream.norm"
    normalize "$WORK/sh/$stream" > "$a"
    normalize "$WORK/php/$stream" > "$b"
    cmp -s "$a" "$b" || fail "shell/PHP $stream divergence:\n$(diff -u "$a" "$b")"
}

# ПРАВИЛО: frozen shell rollback і native PHP loop мусять виконувати ті самі envelope-рішення; порядок тримає код, next.command ніколи не виконується.
# САБОТАЖ: дозволити human-mode «патч», обійти blocked/spin guard або почати другу пачку попри --batches 1 · цей тест мусить впасти.

# 1. Кожен child мусить бути виконаний в обох orchestrator paths.
scenario_both \
    '{"ok":true,"state":"awaiting_terminology","next":{"kind":"child","role":"translation-terminology","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"awaiting_qa","next":{"kind":"child","role":"translation-qa","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"complete"}}'
run_both
expect_codes 0
for side in sh php; do
    roles="$(tr '\n' ' ' < "$WORK/$side/state/roles.log")"
    test "$roles" = "translation-terminology translation-worker translation-qa " \
        || fail "$side roles out of order: $roles"
done
compare_streams stdout; compare_streams stderr

# 2. continue_run складає fixed argv, не виконує command із envelope.
scenario_both \
    '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":120,"goal":{"mode":"patch","patch":"7","domain":"quest"},"command":"rm -rf /"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"goal_complete","goal":{"mode":"patch","patch":"7","domain":""}}}'
run_both
expect_codes 0
for side in sh php; do
    if [ "$side" = sh ]; then
        grep -Fqx 'mode start patch 50 7 quest' "$WORK/$side/state/calls.log" \
            || fail "$side did not start the next batch"
    else
        grep -Fqx 'run-mode patch 50 7 quest' "$WORK/$side/state/calls.log" \
            || fail "$side did not start the next batch with fixed PHP argv"
    fi
    ! grep -Fq 'rm -rf' "$WORK/$side/state/calls.log" \
        || fail "$side executed envelope command"
done
compare_streams stdout; compare_streams stderr

# 3. Unknown mode and suspicious domain are named failures.
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"чужий-режим","patch":"7","domain":""}}}'
run_both; expect_codes 1; expect_each 'невідомий режим'
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"патч","patch":"7","domain":""}}}'
run_both; expect_codes 1; expect_each 'невідомий режим'
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"patch","patch":"7","domain":"quest;rm"}}}'
run_both; expect_codes 1; expect_each 'підозріла категорія'

# 4. Human stdout before envelope is data, not a second step.
for side in sh php; do printf 'payload QA: 50 рядків | глосарій 26 | без відповідника 0\nще один людський рядок\n' > "$WORK/$side/state/noise"; done
scenario_both \
    '{"ok":true,"state":"awaiting_qa","next":{"kind":"child","role":"translation-qa","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"complete"}}'
run_both; expect_codes 0
for side in sh php; do test "$(tr '\n' ' ' < "$WORK/$side/state/roles.log")" = 'translation-qa ' || fail "$side parsed human stdout incorrectly"; done
rm -f "$WORK"/*/state/noise

# 5. No envelope, blocked, unknown kind and drive error remain named failures.
scenario_both 'самий лише людський текст без JSON'; run_both; expect_codes 1; expect_each 'немає конверта'
scenario_both '{"ok":false,"state":"no_batch","next":{"kind":"blocked","reason":"no_current_batch"}}'; run_both; expect_codes 1; expect_each 'no_current_batch'
scenario_both '{"ok":true,"state":"awaiting_qa","next":{"kind":"нове_щось"}}'; run_both; expect_codes 1; expect_each 'невідомий крок'
scenario_both '{"ok":true,"state":"awaiting_worker","next":{"kind":"stop"}}'; FAKE_DRIVE_BOOM='рушій зламався тут' run_both; unset FAKE_DRIVE_BOOM; expect_codes 1; expect_each 'рушій зламався тут'

# 6. Retry spin budget, signal normalization and child nonzero are equal.
for side in sh php; do { for _ in $(seq 1 20); do printf '%s\n' '{"ok":true,"state":"awaiting_qa","next":{"kind":"retry","reason":"context_unavailable"}}'; done; } > "$WORK/$side/state/scenario"; done
BDO_LOOP_SPIN_LIMIT=3 run_both; expect_codes 1; expect_each 'не рухається'
scenario_both '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}'; FAKE_CHILD_FAILS=1 run_both; unset FAKE_CHILD_FAILS; expect_codes 1; expect_each 'не дала відповіді'
scenario_both 'без конверта'; FAKE_DRIVE_SIGNAL=130 run_both; unset FAKE_DRIVE_SIGNAL; expect_codes 1; expect_each 'перервано ззовні'
scenario_both 'без конверта'; FAKE_DRIVE_SIGNAL=143 run_both; unset FAKE_DRIVE_SIGNAL; expect_codes 1; expect_each 'перервано ззовні'

# 7. once/batch limits, reporter fail-soft and unknown CLI args are both paths.
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"patch","patch":"7","domain":"quest"}}}'
RUN_REPORT=1 run_both --once; unset RUN_REPORT; expect_codes 0
for side in sh php; do
    if [ "$side" = sh ]; then
        grep -Fqx 'mode start patch 50 7 quest' "$WORK/$side/state/calls.log" || fail "$side --once skipped mode start"
    else
        grep -Fqx 'run-mode patch 50 7 quest' "$WORK/$side/state/calls.log" || fail "$side --once skipped mode start"
    fi
done
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"patch","patch":"7","domain":"quest"}}}'
run_both --batches 1; expect_codes 0
scenario_both '{"ok":true,"state":"verified","next":{"kind":"complete"}}'; run_both --what; expect_codes 2
scenario_both \
    '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"complete"}}'
RUN_REPORT=1 FAKE_REPORT_FAILS=1 run_both; unset RUN_REPORT FAKE_REPORT_FAILS; expect_codes 0; expect_each 'reporter marker'

# Повтор already-complete step не маскує підміну artifact.
php -r '
require $argv[1];
use Bdo\Translate\Batch\Workspace;
$tmp = sys_get_temp_dir()."/bdo-step-".getmypid();
@mkdir($tmp."/batches/20260101_000000_abc", 0777, true);
file_put_contents($tmp."/current-batch", "20260101_000000_abc");
file_put_contents($tmp."/batches/20260101_000000_abc/manifest.json", json_encode(["id" => "20260101_000000_abc", "rows" => 5, "state" => "awaiting_terminology"]));
$w = Workspace::requireCurrent($tmp);
$w->completeStep("terminology", "a.json", str_repeat("1", 64));
$w->completeStep("terminology", "a.json", str_repeat("1", 64));
try { $w->completeStep("terminology", "b.json", str_repeat("2", 64)); exit(1); }
catch (RuntimeException $e) { if (! str_contains($e->getMessage(), "вже завершений")) exit(1); }
' "$ROOT/lib/autoload.php" || fail 'completeStep regression зникла'

echo 'OK: shell і native PHP loop виконують однакові envelope-рішення.'
