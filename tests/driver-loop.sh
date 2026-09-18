#!/usr/bin/env bash
# Драйвер мусить робити рівно те, що каже конверт, і зупинятися з причиною.
# Цей тест ганяє envelope fixtures через native PHP loop.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

setup_side() {
    local base="$WORK/$1"
    mkdir -p "$base/cli/run" "$base/cli/model" "$base/cli/system" "$base/state" "$base/lib"
    # TimedCommand PHP клас копіюється разом із lib/ (рядок нижче)
    cp -R "$ROOT/lib/." "$base/lib/"
    cp "$ROOT/cli/command-registry.json" "$base/cli/command-registry.json"
    # Пісочниця більше не роздвоюється: гілка bash тут була другим боком
    # відкату, і разом із ним її не стало.
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

# Після зняття шляху відкату «обидва боки» більше не існують: лишився один,
# PHP. Назва функції збережена, щоб не переписувати двадцять викликів нижче.
scenario_both() {
    ACTIVE=php
    scenario "$@"
}

run_side() {
    local base="$WORK/$1"; shift
    # Копіювання `bdo.php` сюди більше не потрібне: воно освіжало ДРУГУ
    # пісочницю (bash-бік), а після зняття відкату бік один · і `cp` став
    # копіюванням файла самого на себе, на чому тест і падав.
    set +e
    (cd "$base" && BDO_STATE_DIR="$base/state" BDO_STEP_REPORT="${RUN_REPORT:-0}" php cli/bdo.php run-loop "$@") >"$base/stdout" 2>"$base/stderr"
    local code=$?
    set -e
    printf '%s\n' "$code" > "$base/code"
}

run_both() {
    run_side php "$@"
}

expect_codes() {
    local expected="$1"
    test "$(cat "$WORK/php/code")" = "$expected" \
        || fail "php code $(cat "$WORK/php/code"), expected $expected"
}

output() { cat "$WORK/$1/stdout" "$WORK/$1/stderr"; }
expect_each() {
    local pattern="$1"
    grep -Fq "$pattern" <(output php) || fail "php output misses: $pattern"
}

# `compare_streams` тут більше немає НАВМИСНО: він звіряв вивід sh із виводом
# php, а після зняття відкату обидва боки були б одним і тим самим прогоном.
# Таке порівняння здатне впасти лише на недетермінованості, тобто нічого не
# доводить. Сценарії нижче тримаються на своїх справжніх твердженнях · порядку
# ролей, вмісті `calls.log` і відсутності виконання команди з конверта.

# ПРАВИЛО: native PHP loop виконує лише envelope-рішення; порядок тримає код,
# next.command ніколи не виконується.
# САБОТАЖ: дозволити human-mode «патч», обійти blocked/spin guard або почати другу пачку попри --batches 1 · цей тест мусить впасти.

# 1. Кожен child мусить бути виконаний в обох orchestrator paths.
scenario_both \
    '{"ok":true,"state":"awaiting_terminology","next":{"kind":"child","role":"translation-terminology","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"awaiting_qa","next":{"kind":"child","role":"translation-qa","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"complete"}}'
run_both
expect_codes 0
roles="$(tr '\n' ' ' < "$WORK/php/state/roles.log")"
test "$roles" = "translation-terminology translation-worker translation-qa " \
    || fail "roles out of order: $roles"

# 2. continue_run складає fixed argv, не виконує command із envelope.
scenario_both \
    '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":120,"goal":{"mode":"patch","patch":"7","domain":"quest"},"command":"rm -rf /"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"goal_complete","goal":{"mode":"patch","patch":"7","domain":""}}}'
run_both
expect_codes 0
grep -Fqx 'run-mode patch 50 7 quest' "$WORK/php/state/calls.log" \
    || fail 'рушій не почав наступну пачку фіксованим argv'
! grep -Fq 'rm -rf' "$WORK/php/state/calls.log" \
    || fail 'рушій виконав команду з конверта'

# 3. Unknown mode and suspicious domain are named failures.
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"чужий-режим","patch":"7","domain":""}}}'
run_both; expect_codes 1; expect_each 'невідомий режим'
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"патч","patch":"7","domain":""}}}'
run_both; expect_codes 1; expect_each 'невідомий режим'
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"patch","patch":"7","domain":"quest;rm"}}}'
run_both; expect_codes 1; expect_each 'підозріла категорія'

# 4. Human stdout before envelope is data, not a second step.
printf 'payload QA: 50 рядків | глосарій 26 | без відповідника 0\nще один людський рядок\n' > "$WORK/php/state/noise"
scenario_both \
    '{"ok":true,"state":"awaiting_qa","next":{"kind":"child","role":"translation-qa","payload_path":"p","response_path":"r"}}' \
    '{"ok":true,"state":"verified","next":{"kind":"complete"}}'
run_both; expect_codes 0
test "$(tr '\n' ' ' < "$WORK/php/state/roles.log")" = 'translation-qa ' || fail 'людський stdout розібрано як крок'
rm -f "$WORK"/*/state/noise

# 5. No envelope, blocked, unknown kind and drive error remain named failures.
scenario_both 'самий лише людський текст без JSON'; run_both; expect_codes 1; expect_each 'немає конверта'
scenario_both '{"ok":false,"state":"no_batch","next":{"kind":"blocked","reason":"no_current_batch"}}'; run_both; expect_codes 1; expect_each 'no_current_batch'
scenario_both '{"ok":true,"state":"awaiting_qa","next":{"kind":"нове_щось"}}'; run_both; expect_codes 1; expect_each 'невідомий крок'
scenario_both '{"ok":true,"state":"awaiting_worker","next":{"kind":"stop"}}'; FAKE_DRIVE_BOOM='рушій зламався тут' run_both; unset FAKE_DRIVE_BOOM; expect_codes 1; expect_each 'рушій зламався тут'

# 6. Retry spin budget, signal normalization and child nonzero are equal.
{ for _ in $(seq 1 20); do printf '%s\n' '{"ok":true,"state":"awaiting_qa","next":{"kind":"retry","reason":"context_unavailable"}}'; done; } > "$WORK/php/state/scenario"
BDO_LOOP_SPIN_LIMIT=3 run_both; expect_codes 1; expect_each 'не рухається'
scenario_both '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}'; FAKE_CHILD_FAILS=1 run_both; unset FAKE_CHILD_FAILS; expect_codes 1; expect_each 'не дала відповіді'
# ПРИЧИНА ЗУПИНКИ МУСИТЬ БУТИ В ЖУРНАЛІ, а не лише в stderr. Цикл працює у
# відчепленому процесі (tmux), його stderr не читає ніхто: сторінка бере
# `run-transcript.log`. Поки причина йшла лише в stderr, зупинений прогін
# виглядав як робочий · пачка стоїть на кроці, нуль викликів, жодного слова
# чому (спіймано 2026-09-19 на пачці 20260919_011019).
grep -Fq 'ЗУПИНКА · роль translation-worker не дала відповіді' "$WORK/php/state/run-transcript.log" \
    || fail 'причини зупинки немає в журналі прогону · сторінка мовчатиме про мертвий прогін'
# ВИРОК І МОДЕЛЬ · у тому самому рядку. Питання після кожного збою одне: це
# модель чи набір. 2026-09-19 відповідь довелось збирати порівнянням журналу
# вручну (одна модель зробила крок 12 разів, друга провалила 3 з 3).
printf '%s\n' '{"at":"2026-01-01T00:00:00+00:00","role":"translation-worker","verdict":"not_json","model":"тест-модель","ms":2000,"out":99}' \
    > "$WORK/php/state/model-calls.jsonl"
scenario_both '{"ok":true,"state":"awaiting_worker","next":{"kind":"child","role":"translation-worker","payload_path":"p","response_path":"r"}}'
FAKE_CHILD_FAILS=1 run_both; unset FAKE_CHILD_FAILS
grep -Fq 'вирок not_json · модель тест-модель' "$WORK/php/state/run-transcript.log" \
    || fail 'зупинка не називає вироку й моделі · «модель чи набір» знову доведеться з'"'"'ясовувати руками'
scenario_both 'без конверта'; FAKE_DRIVE_SIGNAL=130 run_both; unset FAKE_DRIVE_SIGNAL; expect_codes 1; expect_each 'перервано ззовні'
scenario_both 'без конверта'; FAKE_DRIVE_SIGNAL=143 run_both; unset FAKE_DRIVE_SIGNAL; expect_codes 1; expect_each 'перервано ззовні'

# 7. once/batch limits, reporter fail-soft and unknown CLI args are both paths.
scenario_both '{"ok":true,"state":"verified","next":{"kind":"continue_run","remaining":10,"goal":{"mode":"patch","patch":"7","domain":"quest"}}}'
RUN_REPORT=1 run_both --once; unset RUN_REPORT; expect_codes 0
grep -Fqx 'run-mode patch 50 7 quest' "$WORK/php/state/calls.log" \
    || fail '--once пропустив старт наступної пачки'
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

echo 'OK: цикл виконує лише рішення з конверта · порядок тримає код, команда з конверта не виконується.'
