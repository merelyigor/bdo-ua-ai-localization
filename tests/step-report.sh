#!/usr/bin/env bash
# Звіт про крок показує ЗМІСТ роботи, і рівно те, що є у файлах.
#
# Навіщо перевірка. Драйвер друкував назву кроку, і власник десять хвилин
# дивився в німий екран: не видно ні що пішло в модель, ні що вона відповіла.
# Звіт це закриває, але сам стає місцем, де легко почати вигадувати · показати
# «розкладку», якої немає у відповіді, або приховати рядок, який модель
# зіпсувала. Тому тест питає ФАКТИ: кожна роль показується власною формою, а
# нічого, чого немає у файлі, на екран не потрапляє.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

H1="$(printf '%064d' 1)"
H2="$(printf '%064d' 2)"
report() { bash "$ROOT/cli/run/step-report.sh" "$@"; }

php -r '
[$dir, $h1, $h2] = [$argv[1], $argv[2], $argv[3]];
file_put_contents("$dir/payload.json", json_encode(["terms" => [["canonical_source" => "Armor", "ukrainian" => "Обладунки"]],
    "examples" => [["en" => "a", "ua" => "б"]], "items" => [
    ["identity_hash" => $h1, "source_text" => "Dark Figurehead: Panokseon"],
    ["identity_hash" => $h2, "source_text" => "Ancient Armor of the Deep"],
]], JSON_UNESCAPED_UNICODE));
file_put_contents("$dir/candidate.json", json_encode([
    ["identity_hash" => $h1, "text" => "Ніс: Паноксон"],
    ["identity_hash" => $h2, "text" => "Стародавні обладунки глибин"],
], JSON_UNESCAPED_UNICODE));
file_put_contents("$dir/verdicts.json", json_encode([
    ["identity_hash" => $h1, "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
    ["identity_hash" => $h2, "status" => "REVIEW", "severity" => "minor", "issue" => "неприродна назва", "fix" => "Обладунки безодні"],
], JSON_UNESCAPED_UNICODE));
file_put_contents("$dir/judge.json", json_encode([
    ["identity_hash" => $h2, "destination" => "ai_layer", "confidence" => 78, "reason" => "Текст природний."],
], JSON_UNESCAPED_UNICODE));
file_put_contents("$dir/terms.json", json_encode([
    ["canonical_source" => "Panokseon", "status" => "ready", "ukrainian_proposal" => "Паноксон"],
], JSON_UNESCAPED_UNICODE));
file_put_contents("$dir/empty.json", "[]");
' "$TMP" "$H1" "$H2"

# 1. ЗАПИТ: скільки рядків, який контекст і які саме джерела.
#
#    `|| fail` тут не формальність: голе присвоєння під `set -e` обриває ТЕСТ
#    без жодного слова, і зламаний звіт виглядав би як «щось не так», а не як
#    названа причина (§12).
out="$(report --before translation-worker "$TMP/payload.json")" \
    || fail 'звіт про запит завершився ненульовим кодом'
printf '%s' "$out" | grep -Fq 'перекладач → 2 рядків' || fail "запит не назвав роль і обсяг: $out"
printf '%s' "$out" | grep -Fq 'затверджених термінів 1' || fail "запит не назвав контекст: $out"
printf '%s' "$out" | grep -Fq 'Ancient Armor of the Deep' || fail "запит не показав джерела: $out"
printf '%s' "$out" | grep -Fq "$H1" && fail 'у звіт просочився повний identity_hash замість тексту'

# 2. ВІДПОВІДЬ воркера · пара «джерело → переклад», а не JSON.
out="$(report --after translation-worker "$TMP/payload.json" "$TMP/candidate.json")"
printf '%s' "$out" | grep -Fq '→ Стародавні обладунки глибин' || fail "відповідь воркера не показала перекладу: $out"
printf '%s' "$out" | grep -Fq 'Ancient Armor of the Deep' || fail 'відповідь не привʼязана до джерела'

# 3. QA · розкладка вердиктів і ПОКАЗ саме проблемного рядка з виправленням.
out="$(report --after translation-qa "$TMP/payload.json" "$TMP/verdicts.json")"
printf '%s' "$out" | grep -Fq 'REVIEW/minor · неприродна назва' || fail "QA не показала дефект: $out"
printf '%s' "$out" | grep -Fq 'виправлення: Обладунки безодні' || fail "QA не показала готового виправлення: $out"
printf '%s' "$out" | grep -Fq 'розкладка: PASS/none 1 | REVIEW/minor 1' || fail "QA не дала розкладки: $out"

# 4. Суддя · маршрут УКРАЇНСЬКОЮ, впевненість і підстава.
out="$(report --after translation-judge "$TMP/payload.json" "$TMP/judge.json")"
printf '%s' "$out" | grep -Fq 'у ШІ-шар (78%)' || fail "суддя не показав маршрут і впевненість: $out"
printf '%s' "$out" | grep -Fq 'ai_layer 1' || fail 'немає розкладки маршрутів'
printf '%s' "$out" | grep -Fq 'destination' && fail 'суддя показаний англійським ключем замість підпису'

# 5. Термінолог · власна форма «канонікал → пропозиція».
out="$(report --after translation-terminology "$TMP/payload.json" "$TMP/terms.json")"
printf '%s' "$out" | grep -Fq 'Panokseon → Паноксон (ready)' || fail "термінолог показаний не своєю формою: $out"

# 6. Порожня відповідь не вигадується: це названий стан, а не тиша.
out="$(report --after translation-worker "$TMP/payload.json" "$TMP/empty.json")"
printf '%s' "$out" | grep -Fq 'відповіді ще немає' || fail "порожню відповідь не названо: $out"

# 7. Стеля рядків: показане обмежене, приховане названо числом.
php -r '$items = []; for ($i = 0; $i < 30; $i++) { $items[] = ["identity_hash" => str_pad((string) $i, 64, "0", STR_PAD_LEFT), "source_text" => "Row $i"]; }
    file_put_contents($argv[1], json_encode(["items" => $items], JSON_UNESCAPED_UNICODE));' "$TMP/big.json"
out="$(BDO_STEP_REPORT_ROWS=3 report --before translation-worker "$TMP/big.json")"
test "$(printf '%s' "$out" | grep -c 'Row ')" = 3 || fail "стеля рядків не діє: $out"
printf '%s' "$out" | grep -Fq 'і ще 27 рядків' || fail "приховане не названо числом: $out"

# 7а. Стеля рахує НАПЕЧАТАНІ рядки, а не переглянуті.
#
#     На живому прогоні 2026-09-04 QA дала `PASS 34 | REVIEW 2`, і жодного
#     `REVIEW` на екрані не було: лічильник збільшувався на кожну відповідь, і
#     після шести `PASS` цікаве вже не друкувалось. Звіт про прозорість
#     приховував рівно те, на що дивляться.
php -r '$items = [];
for ($i = 0; $i < 8; $i++) { $items[] = ["identity_hash" => str_pad((string) $i, 64, "0", STR_PAD_LEFT), "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""]; }
$items[] = ["identity_hash" => str_repeat("f", 64), "status" => "REVIEW", "severity" => "minor", "issue" => "русизм: тревожні", "fix" => "тривожні"];
file_put_contents($argv[1], json_encode($items, JSON_UNESCAPED_UNICODE));' "$TMP/late-review.json"
out="$(BDO_STEP_REPORT_ROWS=3 report --after translation-qa "$TMP/payload.json" "$TMP/late-review.json")" \
    || fail 'звіт про пізній REVIEW упав'
printf '%s' "$out" | grep -Fq 'русизм: тревожні' \
    || fail "єдиний REVIEW після восьми PASS не показано · стеля рахує не те: $out"
printf '%s' "$out" | grep -Fq 'PASS/none 8 | REVIEW/minor 1' \
    || fail "розкладка мусить рахувати ВСІ відповіді: $out"

# 7б. Без керуючого термінала звіт працює, а не падає.
#
#     `stty size < /dev/tty` без tty віддає ненульовий код, `pipefail` робить це
#     кодом конвеєра, і голе присвоєння під `set -e` убило б звіт разом із
#     прогоном (§12). Тут `setsid` відриває процес від термінала · саме той
#     стан, у якому крок і виконується під gate або в cron.
if command -v setsid >/dev/null 2>&1; then
    out="$(setsid bash "$ROOT/cli/run/step-report.sh" --before translation-worker "$TMP/payload.json" 2>&1)" \
        || fail "без термінала звіт упав: $out"
else
    out="$(bash "$ROOT/cli/run/step-report.sh" --before translation-worker "$TMP/payload.json" < /dev/null 2>&1)" \
        || fail "звіт упав без stdin-термінала: $out"
fi
printf '%s' "$out" | grep -Fq 'перекладач → 2 рядків' \
    || fail "без термінала звіт не намалював крок: $out"

# 8. Драйвер справді ходить цим шляхом, і вимикач існує · інакше gate і тести,
#    що читають рівно рядки драйвера, ламались би від звіту.
grep -Fq 'report --before "$role" "$payload"' "$ROOT/cli/run/run-loop.sh" \
    || fail 'драйвер не показує запит перед викликом ролі'
grep -Fq 'report --after "$role" "$payload" "$response"' "$ROOT/cli/run/run-loop.sh" \
    || fail 'драйвер не показує відповідь ролі'
grep -Fq 'BDO_STEP_REPORT:-1' "$ROOT/cli/run/run-loop.sh" \
    || fail 'немає вимикача звіту'
grep -Fq 'run-transcript.log' "$ROOT/cli/run/run-loop.sh" \
    || fail 'звіт не дублюється в журнал прогону · після прибирання пачки його не лишиться нізвідки'
# Збій рендерера не має валити прогін: це звіт, а не крок конвеєра.
out="$(report --after translation-worker "$TMP/payload.json" "$TMP/немає-такого.json" 2>&1 || true)"
printf '%s' "$out" | grep -Fq 'відповіді ще немає' || fail "відсутній файл відповіді не названо: $out"

echo 'step report: OK · кожна роль показана власною формою, приховане названо числом.'
