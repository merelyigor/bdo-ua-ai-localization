#!/usr/bin/env bash
# Звіти обслуговування · PHP-команди, а не shell-обгортки.
#
# Вісім звітів (`timing`, `judge`, `incidents`, `quarantine`, `review`,
# `suspects`, `audit`, `bench`) були скриптами, які майже цілком складались із
# `php -r '…'` усередині лапок. Порт 2026-09-17 переніс тіло в
# `lib/Cli/Command/Audit/**`. Порт доводиться не словом: тут перевіряється, що
# маршрут ВЕДЕ В PHP, що команда друкує саме те, що обіцяє, і що межі
# аргументів лишились тими самими.
#
# Вивід звірявся з shell-версією БАЙТ У БАЙТ у момент порту (12 випадків
# читання + два `--clear` разом із побічним ефектом). Тут лишаються ознаки, які
# переживуть зміну даних: формат рядків, коди виходу й тексти відмов.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-audit-reports.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

STATE="$TMP/state"
mkdir -p "$STATE/batches/20260101_010101_abcdef0123456789"

# --- 1. Маршрут веде в PHP, а не в скрипт ------------------------------------
# Це і є суть порту: `kind => script` тут означав би, що команда знову пішла
# через оболонку.
php -r '
require $argv[1];
use Bdo\Translate\Cli\Router;
foreach (["timing", "judge", "incidents", "quarantine", "review", "suspects", "audit", "models-run", "bench"] as $name) {
    $target = (string) Router::targetFor([$name]);
    if (! str_starts_with($target, "php:")) {
        fwrite(STDERR, "маршрут {$name} веде не в PHP, а в «{$target}»\n");
        exit(1);
    }
}
' "$ROOT/lib/autoload.php" 2>"$TMP/route.err" || {
    cat "$TMP/route.err" >&2
    fail 'звіт обслуговування знову їде через shell-скрипт'
}

# Kernel мусить ЗНАТИ кожну з цих команд · інакше маршрут веде в нікуди. Це та
# сама перевірка, що й у `tests/command-registry.sh`, але звужена до звітів:
# там вона дивиться весь Router і легко губить один новий рядок серед сотні.
for command in timing-report judge-report model-incidents quarantine-report project-review glossary-suspects model-run model-bench; do
    php -r '
    require $argv[1];
    $kernel = new ReflectionClass(Bdo\Translate\Cli\Kernel::class);
    $method = $kernel->getMethod("command");
    if ($method->invoke($kernel->newInstance(), $argv[2]) === null) {
        fwrite(STDERR, "Kernel не знає команди ".$argv[2]."\n");
        exit(1);
    }' "$ROOT/lib/autoload.php" "$command" || fail "Kernel не знає $command · маршрут веде в нікуди"
done

# --- 2. Порожній стан · відповідь, а не мовчання ------------------------------
# «Нічого немає» мусить бути сказане словами: порожній вивід не є відповіддю.
run() { BDO_STATE_DIR="$STATE" "$ROOT/bdo" "$@"; }

out="$(run timing 2>&1)" || fail 'timing на порожньому стані впав'
grep -Fq 'Міток часу ще немає' <<<"$out" || fail "timing мовчить про порожній журнал: $out"
out="$(run judge 2>&1)" || fail 'judge на порожньому стані впав'
grep -Fq 'Суддя ще не ухвалював рішень' <<<"$out" || fail "judge мовчить про порожній журнал: $out"
out="$(run incidents 2>&1)" || fail 'incidents на порожньому стані впав'
grep -Fq 'моделі не викликали жодного разу' <<<"$out" || fail "incidents мовчить: $out"
out="$(run quarantine 2>&1)" || fail 'quarantine на порожньому стані впав'
grep -Fq 'Карантин порожній' <<<"$out" || fail "quarantine мовчить: $out"

# --- 3. Межі аргументів лишились тими самими ---------------------------------
# Код 2 · «команду покликано неправильно», і це НЕ те саме, що код 1 («робота
# не вдалась»). Скрипти розрізняли ці два випадки, порт мусить теж.
expect_code() {
    local want="$1" name="$2"; shift 2
    set +e
    BDO_STATE_DIR="$STATE" "$ROOT/bdo" "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"
    local code=$?
    set -e
    test "$code" = "$want" || fail "$name дав код $code замість $want: $(cat "$TMP/$name.err")"
}
expect_code 2 timing-bad timing 3abc
grep -Fq 'потрібне число пачок або --all' "$TMP/timing-bad.err" || fail 'timing не назвав причину відмови'
expect_code 2 judge-bad judge --oops
expect_code 2 incidents-bad incidents --oops
expect_code 2 incidents-badnum incidents --list x
expect_code 2 quarantine-bad quarantine --oops
expect_code 1 bench-bad bench --oops
grep -Fq 'невідомий аргумент «--oops»' "$TMP/bench-bad.err" \
    || fail "bench загубив аргумент у повідомленні (інтерполяція без дужок): $(cat "$TMP/bench-bad.err")"
expect_code 1 bench-repeat bench --repeat x модель
grep -Fq 'отримано «x»' "$TMP/bench-repeat.err" || fail 'bench загубив значення --repeat у повідомленні'
expect_code 2 suspects-bad suspects --oops

# --- 4. Звіт справді читає дані ----------------------------------------------
# Фікстура мінімальна, але РЕАЛЬНА: рядок журналу того самого вигляду, що пише
# `cli/model/client.php`. Порожній звіт на непорожньому журналі · саме той
# клас дефекту, від якого ці перевірки й стоять.
printf '%s\n' '{"at":"2026-09-17T10:00:00+00:00","role":"translation-worker","verdict":"ok","ms":1500,"in":100,"out":200}' >"$STATE/model-calls.jsonl"
printf '%s\n' '{"at":"2026-09-17T10:01:00+00:00","role":"translation-qa","verdict":"not_json","ms":2500,"in":300,"out":0}' >>"$STATE/model-calls.jsonl"
out="$(run incidents 2>&1)" || fail 'incidents впав на непорожньому журналі'
grep -Fq 'Збоїв: 1 із 2 викликів' <<<"$out" || fail "incidents не порахував збої: $out"
grep -Fq 'translation-qa | not_json' <<<"$out" || fail "incidents не згрупував за роллю й причиною: $out"

set +e
BDO_STATE_DIR="$STATE" "$ROOT/bdo" audit >"$TMP/audit.out" 2>&1
audit_code=$?
set -e
test "$audit_code" = 1 || fail "audit мусить дати код 1 при збоях, дав $audit_code"
grep -Fq 'ВИРОК: 1 викликів зі збоєм' "$TMP/audit.out" || fail "audit не назвав збій: $(cat "$TMP/audit.out")"
grep -Fq 'Швидкість генерації' "$TMP/audit.out" || fail 'audit не показує токенів за секунду'

printf '%s\n' '{"identity_hash":"aaaa0000bbbb1111","at":"2026-09-17T10:00:00+00:00","reason":"api_source_equivalent","channel":"machine","source_text":"Sword","candidate":"Меч"}' >"$STATE/quarantine.jsonl"
out="$(run quarantine --list 2>&1)" || fail 'quarantine --list впав'
grep -Fq 'Карантин: 1 записів на 1 унікальних рядків' <<<"$out" || fail "quarantine не порахував записи: $out"
grep -Fq 'api_source_equivalent' <<<"$out" || fail 'quarantine не згрупував за причиною'
grep -Fq 'EN: Sword' <<<"$out" || fail 'quarantine --list не показує оригінал'

# --- 5. `--clear` ЗСУВАЄ слід в архів, а не знищує ----------------------------
# Саме цим слідом доведено D53, D56 і D58: команда, яка його стирає, забирає
# єдиний доказ.
run quarantine --clear >"$TMP/clear.out" 2>&1 || fail 'quarantine --clear впав'
grep -Fq 'Слід зсунуто в архів' "$TMP/clear.out" || fail 'quarantine --clear мовчить про архів'
test -s "$STATE/quarantine.jsonl.archived" || fail 'quarantine --clear не зберіг слід · доказ утрачено'
grep -Fq 'aaaa0000bbbb1111' "$STATE/quarantine.jsonl.archived" || fail 'в архіві не той рядок'
test ! -s "$STATE/quarantine.jsonl" || fail 'quarantine --clear не очистив карантин'

printf '%s\n' '{"at":"2026-09-17T10:00:00+00:00","identity_hash":"aaaa0000bbbb1111","confidence":80,"verdict":"ai_layer","applied":"ai_layer","qa_status":"REVIEW","qa_severity":"minor","reason":"дрібниця"}' >"$STATE/judge-decisions.jsonl"
run judge --clear >"$TMP/judge-clear.out" 2>&1 || fail 'judge --clear впав'
grep -Fq 'заархівовано' "$TMP/judge-clear.out" || fail 'judge --clear мовчить'
test ! -e "$STATE/judge-decisions.jsonl" || fail 'judge --clear лишив журнал на місці'
ls "$STATE"/judge-decisions.jsonl.*.archived >/dev/null 2>&1 || fail 'judge --clear не створив архіву'

# --- 6. `suspects --list` нічого не пише -------------------------------------
# Звіт для людини й позначки для коду · побічні ефекти. `--list` мусить лишатись
# читанням: інакше «просто подивитись» тихо змінює payload наступної пачки.
printf '%s\n' '{"terms":[{"canonical_source":"Week","ukrainian":"Місяць","seen":2,"policy":"translate"}]}' >"$STATE/term-notes-queue.json"
before="$(ls "$STATE" | sort | tr '\n' ' ')"
out="$(BDO_STATE_DIR="$STATE" BDO_PIPELINE_OFFLINE=1 "$ROOT/bdo" suspects --list 2>&1)" || fail 'suspects --list впав'
grep -Fq 'лише бачені в роботі' <<<"$out" || fail "suspects не назвав охоплення: $out"
grep -Fq 'Week -> Місяць' <<<"$out" || fail "suspects не знайшов підозри: $out"
after="$(ls "$STATE" | sort | tr '\n' ' ')"
test "$before" = "$after" || fail "suspects --list змінив стан: [$before] -> [$after]"

# ОХОПЛЕННЯ НАЗИВАЄТЬСЯ ЧЕСНО (D181). Shell кликав `cli/api/glossary-list.sh`,
# якого немає з версії 7.0.8, тому повний перелік не діставався НІКОЛИ, а звіт
# мовчки писав «лише бачені». Тепер джерелом є PHP-команда, і назва охоплення
# мусить іти за нею, а не за здогадом.
grep -Fq 'new GlossaryListCommand()' "$ROOT/lib/Cli/Command/Audit/GlossarySuspectsCommand.php" \
    || fail 'suspects знову бере повний перелік не з PHP-команди · охоплення тихо деградує (D181)'
grep -Fq 'весь глосарій' "$ROOT/lib/Cli/Command/Audit/GlossarySuspectsCommand.php" \
    || fail 'suspects не розрізняє повне охоплення від часткового'

# --- 7. `bench` не чіпає прод і вимагає робочого розміру ----------------------
# D82: на payload у 5 рядків неповна відповідь не відтворюється взагалі, тому
# замала фікстура є ВІДМОВОЮ, а не тихим виміром.
mkdir -p "$TMP/small"
printf '%s\n' '[{"id":"r1","source_text":"Sword"}]' >"$TMP/small/worker-payload.json"
expect_code 1 bench-small bench --payloads "$TMP/small" будь-яка-модель
grep -Fq 'треба щонайменше' "$TMP/bench-small.err" || fail 'bench прийняв замалу фікстуру (D82)'
grep -Fq 'D82' "$TMP/bench-small.err" || fail 'bench не називає причину відмови'

# Жодного запису в API з цієї команди · це не гасло, а властивість коду.
if grep -Eq 'BatchCommitCommand|WriteTranslationsCommand|--write' "$ROOT/lib/Cli/Command/Audit/ModelBenchCommand.php"; then
    fail 'bench дістав шлях до запису в API · вимір мусить лишатись читанням'
fi

# Оточення підпроцесу ДОПОВНЮЄТЬСЯ, а не замінюється: `proc_open` із масивом env
# віддає рівно його, і перша редакція порту забрала в клієнта моделі PATH та
# TRANSLATE_ENV_FILE · вимір давав `no_journal 0.0 с` замість причини.
grep -Fq 'array_merge(getenv(), $environment)' "$ROOT/lib/Cli/Command/Audit/ModelBenchCommand.php" \
    || fail 'bench замінює оточення підпроцесу замість доповнення · клієнт моделі втратить PATH'

# --- 8. `review` читає реєстри, а не вигадує ---------------------------------
out="$(run review 2>&1)" || fail 'review впав'
for section in '== 1. Плани в роботі ==' '== 2. Дефекти ==' '== 3. Черга робіт ==' '== 4. Останні пачки ==' '== 5. Живі сигнали =='; do
    grep -Fq "$section" <<<"$out" || fail "review загубив розділ «${section}»"
done
grep -Fq 'поточної пачки немає' <<<"$out" || fail 'review мовчить про відсутню пачку'
# Лічильник дефектів мусить іти за СЬОМОЮ колонкою таблиці, а не за початком
# рядка: інакше він тихо показує нулі при непорожньому реєстрі.
php -r '
$open = 0; $closed = 0; $accepted = 0;
foreach (file($argv[1], FILE_IGNORE_NEW_LINES) as $line) {
    if (preg_match("/^\| D[0-9]+ /", $line) !== 1) { continue; }
    $status = preg_replace("/[ \t]/", "", explode("|", $line)[6] ?? "");
    if ($status === "відкритий") { $open++; }
    if ($status === "закритий") { $closed++; }
    if ($status === "прийнятий") { $accepted++; }
}
if (($open + $closed + $accepted) < 1) { fwrite(STDERR, "реєстр дефектів прочитано неправильно: порожній\n"); exit(1); }
printf("%d %d\n", $open, $closed);
' "$ROOT/docs/plans/DEFECTS.md" >"$TMP/defects.txt" || fail 'реєстр дефектів читається неправильно'
read -r want_open want_closed <"$TMP/defects.txt"
grep -Fq "відкритих: $want_open | прийнятих:" <<<"$out" \
    || fail "review показав інше число відкритих дефектів, ніж є в реєстрі ($want_open)"
grep -Fq "закритих: $want_closed" <<<"$out" \
    || fail "review показав інше число закритих дефектів, ніж є в реєстрі ($want_closed)"

echo 'cli audit reports: OK · вісім звітів є PHP-командами, межі аргументів, --clear зсуває слід в архів, review рахує реєстр'
