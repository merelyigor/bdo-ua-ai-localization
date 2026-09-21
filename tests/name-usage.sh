#!/usr/bin/env bash
# Усталене написання назви виводиться з даних, а не з фантазії моделі.
#
# Причина існування кроку · вимір 2026-09-21 на 1661 рядку: 116 мали `Illezra`
# в оригіналі, і ЖОДЕН не отримав терміна з нею, бо окремий термін стоїть у
# стані `ready` без українського поля. Модель лишалась без відповіді й писала
# `Ілlezra`. Написання назви при цьому вже існувало в 61 затвердженому
# складеному терміні · його треба було не питати, а вивести.
#
# Рішення власника 2026-09-21: рішення про канонічне написання ухвалює НАБІР,
# а не людина · «якби роль сказала, що перевірила, і записала Ілезра з одною л,
# я б не сперечався». Тому тест стереже саме ДЕТЕРМІНОВАНІСТЬ цього рішення.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

php -r '
require $argv[1];
use Bdo\Translate\Glossary\NameUsage;
$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };

// 1. Живий доказ із глосарія: 32 вживання з одною «л» проти 25 з двома.
//    Перемагає більшість, а всередині родини · НАЗИВНИЙ відмінок, який уже є
//    в даних. Число тут не декоративне: саме воно є рішенням.
$forms = ["Ілезри" => 29, "Іллезри" => 20, "Іллезра" => 5, "Ілезра" => 3];
$verdict = NameUsage::decide("Illezra", $forms);
if ($verdict["canonical"] !== "Ілезра") {
    $fail("канонічне написання виведено хибно: ".$verdict["canonical"]);
}
if (! str_contains($verdict["reason"], "32")) {
    $fail("вирок не називає, скільком вживанням він завдячує: ".$verdict["reason"]);
}

// 2. Порожній доказ · НЕ рішення. «Невідомо» не дорівнює «порожньо», і назва
//    не вигадується ніколи.
if (NameUsage::decide("Lifea", [])["canonical"] !== "") $fail("написання вигадано без жодного доказу");
if (NameUsage::decide("Grey", ["Ґрей" => 1])["canonical"] !== "") {
    $fail("одне вживання визнано усталеним звичаєм проєкту");
}

// 3. Нічия лишається людині: код не кидає монету.
$tie = NameUsage::decide("Illezra", ["Ілезра" => 5, "Іллезра" => 5]);
if ($tie["canonical"] !== "") $fail("при рівній лічбі код усе одно обрав написання");
if (! str_contains($tie["reason"], "нічия")) $fail("нічия не названа вголос: ".$tie["reason"]);

// 4. Поріг схожості ЗАМІРЯНИЙ, а не вгаданий (див. коментар у NameUsage).
//    Правильні пари мусять проходити навіть коли транслітерація розходиться в
//    середині слова, а хибні · падати.
foreach ([["Illezra", "Ілезри"], ["Valencia", "Валенсія"], ["Velia", "Велія"],
          ["Bartali", "Бартеллі"], ["Labreska", "Лабрескас"]] as [$name, $form]) {
    if (! NameUsage::isFormOf($name, $form)) $fail("правильну форму відкинуто: $name / $form");
}
foreach ([["Silver", "Сільвії"], ["Soldiers", "солдатів"], ["Providence", "Провидіння"],
          ["Valkyries", "Валькірію"]] as [$name, $form]) {
    if (NameUsage::isFormOf($name, $form)) $fail("хибний збіг пройшов: $name / $form");
}

// 5. Латинське слово формою української назви не є.
if (NameUsage::isFormOf("Illezra", "Illezra")) $fail("латинський оригінал визнано українською формою");

// 6. Кандидатами є лише назви, на які в рядка ще НЕМАЄ відповіді.
// Перелік · саме НАЗВИ З ОРИГІНАЛУ, як їх віддає `array_keys($row->glossary())`.
$candidates = NameUsage::candidates("Illezra appeared near Valencia.", ["Valencia"]);
if (! in_array("Illezra", $candidates, true)) $fail("назва без відповідника не потрапила в кандидати");
if (in_array("Valencia", $candidates, true)) $fail("назва із готовим відповідником пішла на виведення дарма");
' "$ROOT/lib/autoload.php" || fail 'виведення написання назв не відповідає контракту'

# 7. Крок мусить бути ВКЛЮЧЕНИЙ у прогін, інакше він декорація: payload воркера
#    читає блок, драйвер його готує, а промпт ролі знає, що з ним робити.
grep -Fq "new NamesUsagePayloadCommand()" "$ROOT/lib/Cli/Command/Run/RunDriveCommand.php" \
    || fail 'драйвер не виводить написання назв · блок у payload буде порожній завжди'
grep -Fq "name-usage.json" "$ROOT/lib/Cli/Command/Prepare/WorkerPayloadCommand.php" \
    || fail 'payload воркера не читає виведених назв · крок нікуди не доходить'
grep -Fq "'names' => \$sharedNames" "$ROOT/lib/Cli/Command/Prepare/WorkerPayloadCommand.php" \
    || fail 'блок назв не потрапляє в payload під власним ключем'
grep -Fq '`names`' "$ROOT/roles/translation-worker.md" \
    || fail 'промпт ролі не знає про блок назв · роль його проігнорує'
grep -Fq 'спершу шукай у `names`' "$ROOT/roles/translation-worker.md" \
    || fail 'промпт не наказує вживати усталене написання замість власної транслітерації'

# 8. Відсутній дамп глосарія · не «назв немає», а сказана вголос причина.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf '%s' '{"data":{"rows":[{"identity_hash":"'"$(printf 'a%.0s' {1..64})"'","source_text":"Illezra appeared."}]}}' \
    > "$work/rows.json"
out="$(BDO_STATE_DIR="$work/empty-state" php "$ROOT/cli/bdo.php" names-usage-payload "$work/rows.json" 2>&1)" \
    || fail 'крок упав без дампа глосарія замість того, щоб назвати причину'
grep -Fq 'Дамп глосарія відсутній' <<<"$out" \
    || fail 'без дампа крок промовчав · це читалось би як «назв у пачці немає»'

echo 'name usage: OK · написання виведено з даних, порожній доказ і нічия лишились без рішення, крок увімкнений у прогін.'
