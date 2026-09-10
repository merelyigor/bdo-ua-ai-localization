#!/usr/bin/env bash
# Мітки часу мусять бути ЧЕСНИМИ й НЕШКІДЛИВИМИ.
#
# 2026-09-05 я заявив, що третина часу пачки йде повз модель, спираючись на
# розриви між пачками (173 і 259 с). Мітки цю заяву спростували: розриви були
# паузами між окремими запусками `--batches 1`, а в неперервному прогоні решта
# кроків важить 11%. Саме тому вимірювання мусить існувати в коді, а не в
# памʼяті · але воно НЕ має права змінювати те, що міряє.
#
# Перевіряється: обгортка не ковтає вивід і код виходу; мітка пишеться і на
# відмові; частка моделі рахується по ТИХ САМИХ пачках, що й мітки; драйвер
# каже причину, коли обгортки немає.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"
TIMED="$ROOT/cli/system/timed.sh"

# --- 1. Обгортка прозора: stdout, stderr і код виходу проходять як були -----
out="$(BDO_STATE_DIR="$STATE" bash "$TIMED" probe.ok sh -c 'echo рядок-у-stdout; echo рядок-у-stderr >&2' 2>"$TMP/err.txt")"
test "$out" = 'рядок-у-stdout' || fail "обгортка зіпсувала stdout: «${out}»"
grep -q 'рядок-у-stderr' "$TMP/err.txt" || fail 'обгортка проковтнула stderr'

set +e
BDO_STATE_DIR="$STATE" bash "$TIMED" probe.fail sh -c 'exit 7' >/dev/null 2>&1
code=$?
set -e
test "$code" = 7 || fail "обгортка змінила код виходу: очікувалось 7, отримано $code"

# --- 2. Мітка пишеться ЗАВЖДИ, і на відмові теж -----------------------------
# Крок, що впав через 90 секунд, коштує стільки ж часу, як успішний; мовчати
# про нього означало б показувати неповну картину (§12).
test -s "$STATE/step-times.jsonl" || fail 'мітки не зʼявились узагалі'
grep -q '"step":"probe.ok"' "$STATE/step-times.jsonl" || fail 'немає мітки успішного кроку'
grep -q '"step":"probe.fail","ms":[0-9]*,"code":7' "$STATE/step-times.jsonl" \
    || fail "мітка невдалого кроку не несе коду виходу: $(cat "$STATE/step-times.jsonl")"

# --- 3. Довільне імʼя кроку в журнал не потрапляє ---------------------------
# Журнал читає екран власника, тому туди йде лише те, що ми самі назвали.
set +e
BDO_STATE_DIR="$STATE" bash "$TIMED" 'зле; rm -rf /' true >/dev/null 2>&1
bad=$?
set -e
test "$bad" = 2 || fail "обгортка прийняла довільне імʼя кроку (код $bad)"

# --- 4. Частка моделі рахується по ТИХ САМИХ пачках, що й мітки -------------
# Перша редакція звіту брала ВЕСЬ `model-calls.jsonl` і на `--all` показала
# «модель 674%»: сьогоднішні мітки проти всіх викликів за тиждень.
rm -f "$STATE/step-times.jsonl"
printf '%s\n' \
    '{"at":"2026-09-05T10:00:00+00:00","batch":"B1","step":"drive","ms":4000,"code":0}' \
    '{"at":"2026-09-05T10:01:00+00:00","batch":"B1","step":"model.translation-worker","ms":6000,"code":0}' \
    > "$STATE/step-times.jsonl"
printf '%s\n' \
    '{"at":"2026-09-04T10:00:00+00:00","role":"translation-worker","batch":"СТАРА","ms":900000}' \
    '{"at":"2026-09-05T10:01:00+00:00","role":"translation-worker","batch":"B1","ms":6000}' \
    > "$STATE/model-calls.jsonl"
php -r '
require $argv[1];
$r = (new Bdo\Translate\Run\StepTimes($argv[2]))->report(0);
if ($r["model_ms"] !== 6000) {
    fwrite(STDERR, "час моделі {$r["model_ms"]} замість 6000 · у підрахунок потрапила чужа пачка\n"); exit(1);
}
if ($r["other_ms"] !== 4000) { fwrite(STDERR, "решта {$r["other_ms"]} замість 4000\n"); exit(1); }
if ($r["total_ms"] !== 10000) { fwrite(STDERR, "сума {$r["total_ms"]} замість 10000\n"); exit(1); }
' "$ROOT/lib/autoload.php" "$STATE" || fail 'звіт змішує пачки різних прогонів'

# --- 4в. «Решта» рахується сумою, а не відніманням --------------------------
# Віднімання брехало, щойно одна мітка губилась: на прогоні 2026-09-05 зникла
# мітка судді (D81), і 66 секунд механіки показались як 15.
printf '%s\n' \
    '{"at":"2026-09-05T10:02:00+00:00","batch":"B1","role":"translation-judge","ms":50000}' \
    >> "$STATE/model-calls.jsonl"
php -r '
require $argv[1];
$r = (new Bdo\Translate\Run\StepTimes($argv[2]))->report(0);
// Мітки судді немає взагалі · це і є випадок D81.
if ($r["other_ms"] !== 4000) {
    fwrite(STDERR, "втрачена мітка спотворила «решту»: {$r["other_ms"]} замість 4000\n"); exit(1);
}
' "$ROOT/lib/autoload.php" "$STATE" || fail 'звіт рахує «решту» відніманням і бреше при втраченій мітці'

# --- 4б. Вимірювання не має права ВБИТИ те, що міряє (D81) ------------------
# Перша редакція питала час у php двічі на крок. На живому прогоні, коли в
# памʼяті лежала модель на 23 ГБ, другий виклик не піднявся, `set -e` убив
# обгортку до запису мітки, і драйвер зупинив пачку словами «роль
# translation-judge не дала відповіді» · хоча роль ВІДПОВІЛА.
grep -Fq 'EPOCHREALTIME' "$TIMED" \
    || fail 'обгортка знову міряє час окремим процесом · він може не піднятись і вбити крок (D81)'
grep -Eq 'php -r .*record|record\(' "$TIMED" || fail 'обгортка не пише мітки взагалі'
grep -Fq '|| true' "$TIMED" \
    || fail 'запис мітки не захищений · його відмова змінить долю кроку (D81)'
# Найпряміша перевірка: коли php не піднімається, крок однаково живий.
# Саме це сталось на прогоні · памʼять була зайнята моделлю на 23 ГБ.
mkdir -p "$TMP/shim"
printf '#!/bin/sh\nexit 1\n' > "$TMP/shim/php"
chmod +x "$TMP/shim/php"
set +e
out="$(PATH="$TMP/shim:$PATH" BDO_STATE_DIR="$STATE" bash "$TIMED" probe.nophp echo працює 2>/dev/null)"
code=$?
set -e
test "$code" = 0 || fail "зі зламаним php обгортка змінила код виходу на ${code} · вимір важливіший за роботу (D81)"
test "$out" = 'працює' || fail "зі зламаним php обгортка зіпсувала вивід кроку: «${out}»"

# --- 5. Драйвер називає причину, коли обгортки немає ------------------------
# Без цієї межі зникла обгортка давала порожній конверт і повідомлення
# «run drive не віддав конверт» · тобто наслідок замість причини.
grep -Fq 'test -x "$TIMED"' "$ROOT/cli/run/run-loop.sh" \
    || fail 'драйвер не перевіряє наявності обгортки міток'

# --- 6. Мітки стоять там, де ми справді хотіли міряти -----------------------
for step in 'drive' 'mode.start'; do
    grep -Fq "\"\$TIMED\" $step" "$ROOT/cli/run/run-loop.sh" \
        || fail "у драйвері немає мітки кроку «${step}»"
done
PUBLISHED_STEPS="$(php -r 'require $argv[1]; echo implode("\n", Bdo\Translate\Cli\Command\Run\RunDriveCommand::timedSteps());' "$ROOT/lib/autoload.php")"
for step in validate.early validate.final commit; do
    grep -Fqx "$step" <<< "$PUBLISHED_STEPS" \
        || fail "RunDriveCommand::timedSteps() не публікує «${step}»"
done

echo 'step times: OK · обгортка прозора, мітка є й на відмові, чуже імʼя кроку відхилено, звіт не змішує пачки.'
