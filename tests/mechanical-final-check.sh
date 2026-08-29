#!/usr/bin/env bash
# Механічні дефекти у ФІНАЛЬНОМУ тексті знімають рядок із ШІ-шару.
#
# Аудит 2026-08-27 показав дірку: `Defects::inTranslation` працював у
# `heal-plan` (тобто ДО ремонту) і в `batch-commit` лише для рядків, які дивився
# суддя. Після ремонту текст бачив тільки контрольний QA · модель. А власний
# коментар `Defects` каже прямо: «QA саме механічне і пропускає». Отже рядок, у
# який repair вніс русизм чи гомогліф, ішов у ШІ-шар без механічної перевірки.
#
# Тест бере той самий маршрут, що й commit, і вимагає, щоб дефектний рядок пішов
# до людини, а чистий · у шар. Заодно фіксує розширення словника кальок і
# цифрові гомогліфи, додані тим самим заходом.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

php -r '
require $argv[1];
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\Defects;
use Bdo\Translate\Quality\ForeignScript;
use Bdo\Translate\Quality\Homoglyphs;
use Bdo\Translate\Quality\Russianisms;

$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };

// 1. Кальки · русизми, написані бездоганною українською. До 2026-08-27 словник
//    ловив «доспехи» й «оружие», але жодну з цих фраз.
$calques = ["на протязі години", "приймати участь", "співпадає з описом",
    "міроприємство скасовано", "слідуючий рівень", "в залежності від класу",
    "по відношенню до гравця", "у якості нагороди", "вияснити причину"];
foreach ($calques as $text) {
    if (Russianisms::find($text) === []) $fail("калька пройшла як чиста: $text");
}
// Правильна українська не має давати спрацювань: хибний вирок блокує добрий
// переклад, і це дорожче за пропущений випадок.
$clean = ["протягом години", "брати участь", "збігається з описом", "захід скасовано",
    "наступний рівень", "залежно від класу", "щодо гравця", "як нагорода",
    "зʼясувати причину", "Каменюка", "камінь сили", "співпраця гільдій"];
foreach ($clean as $text) {
    $hit = Russianisms::find($text);
    if ($hit !== []) $fail("хибне спрацювання на «$text»: ".implode(",", array_column($hit, "word")));
}

// 2. Цифрові гомогліфи · лише там, де цифра стоїть НА МІСЦІ літери.
foreach (["3броя" => "Зброя", "0бладунки" => "Обладунки", "4ерепаха" => "черепаха"] as $bad => $want) {
    $hit = Homoglyphs::find($bad);
    if ($hit === []) $fail("цифровий гомогліф пропущено: $bad");
    if ($hit[0]["fixed"] !== $want) $fail("невірне виправлення $bad -> ".$hit[0]["fixed"]);
}
// Нумерація без пробілу законна: перша версія правила ловила саме її.
foreach (["Рівень1", "Скриня3", "Тир4", "Тир 4", "50% знижки", "2026 рік", "Меч +15"] as $ok) {
    if (Homoglyphs::find($ok) !== []) $fail("хибне спрацювання цифри на «$ok»");
}

// 2б. Змішана абетка, для якої автовиправлення НЕМАЄ, теж є дефектом.
//
//     2026-08-28 на живій пачці рядок `Sаmоtня альтанка серед природи.` пройшов
//     механіку як чистий і дійшов до QA: латинські `S` і `m` кириличних
//     двійників не мають, слово не змінювалось, і умова «повідомляти лише про
//     те, що змінилось» викидала його разом із латинськими `а` та `о`.
$mixed = Homoglyphs::find("Sаmоtня альтанка серед природи.");
if ($mixed === []) $fail("змішана абетка без автовиправлення пропущена");
if ($mixed[0]["fixed"] !== $mixed[0]["word"]) $fail("для невиправного слова обіцяно виправлення");
$row = new \Bdo\Translate\Batch\Row(["identity_hash" => str_repeat("a", 64), "source_text" => "A lonely gazebo in nature."]);
$defects = Defects::inTranslation($row, "Sаmоtня альтанка серед природи.");
if (! array_filter($defects, static fn (string $d): bool => str_contains($d, "змішана абетка"))) {
    $fail("Defects мовчить про змішану абетку: ".implode("; ", $defects));
}
// Слово з оригіналу лишається дозволеним: там змішана абетка є даними гри.
if (Homoglyphs::find("Місто Valencia", "The city of Valencia") !== []) $fail("слово з оригіналу визнано дефектом");

// 3. Чужа писемність. 2026-08-27 локальна збірка вставляла в український текст
//    китайські ієрогліфи, і жоден детектор цього не бачив: Homoglyphs шукає
//    латинські двійники, Russianisms · російські слова. Курс на локальні моделі
//    робить цей клас регулярним, а не разовим.
foreach (["Скриня 光明 воїна" => "китайські", "アイテム скриня" => "кана",
          "Скриня 아이템" => "хангиль"] as $bad => $what) {
    if (ForeignScript::find($bad) === []) $fail("чужа писемність пропущена ($what): $bad");
}
// Символ, який є у ДЖЕРЕЛІ, дефектом не є: гра корейська, і назву треба зберегти.
if (ForeignScript::find("Скриня 光明 воїна", "Chest of 光明") !== []) {
    $fail("символ із джерела визнано дефектом");
}
// Латиниця, теґи й типографіка законні.
foreach (["Black Desert [Title] · 50% +15", "Обладунки «Жарів» — 1 шт."] as $ok) {
    if (ForeignScript::find($ok) !== []) $fail("хибне спрацювання на «$ok»");
}

// 4. Той самий детектор бачить дефект у фінальному тексті рядка.
$file = tempnam(sys_get_temp_dir(), "rows");
file_put_contents($file, json_encode(["data" => ["rows" => [[
    "identity_hash" => str_repeat("a", 64), "source_hash" => "x", "source_text" => "Armor Set",
]]]], JSON_THROW_ON_ERROR));
$row = RowSet::fromFile($file)->getOrEmpty(str_repeat("a", 64));
unlink($file);
if (Defects::inTranslation($row, "Комплект обладунків") !== []) $fail("чистий текст позначено дефектним");
foreach (["Комплект доспехів", "Комплект 0бладунків", "Видається на протязі дня", "Комплект 光明"] as $bad) {
    if (Defects::inTranslation($row, $bad) === []) $fail("дефект у фінальному тексті пропущено: $bad");
}
' "$ROOT/lib/autoload.php" || fail 'детектори не тримають контракт'

# 5. Вирок маршруту · поведінкою, а не пошуком тексту в скрипті.
php -r '
require $argv[1];
use Bdo\Translate\Pipeline\ChannelRouter;
$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };

// Канал machine навмисно пише все, що має текст · це рішення власника.
if (ChannelRouter::route("machine", "REJECT", "critical", true, false) !== ChannelRouter::PASS) {
    $fail("machine перестав писати рядок без механічного дефекту");
}
// Але механіка сильніша за канал: дефект знімає рядок із шару до людини.
foreach (["machine", "proposal", "manual"] as $channel) {
    if (ChannelRouter::route($channel, "PASS", "none", true, true) !== ChannelRouter::PROPOSAL) {
        $fail("механічний дефект не зняв рядок із каналу $channel");
    }
}
// Порожній текст лишається карантином незалежно від механіки.
if (ChannelRouter::route("machine", "PASS", "none", false, false) !== ChannelRouter::QUARANTINE) {
    $fail("порожній текст перестав бути карантином");
}
' "$ROOT/lib/autoload.php" || fail 'маршрут ігнорує механічний дефект'

grep -q 'ChannelRouter::route($argv\[13\], $status, $severity, $hasText, $mechanical !== \[\])' "$ROOT/cli/batch/batch-commit.sh" \
    || fail 'commit не передає механічний вирок у маршрут'

# Відмова API на ФІНАЛЬНІЙ валідації знімає рядок із запису.
#
# З 2026-08-29 сервер відхиляє порушення глосарію (`glossary_violation`).
# Перша валідація йде до QA, і repair її лікує · але текст ПІСЛЯ repair до
# сервера більше не показувався. Якщо саме виправлення порушувало глосарій, ми
# дізнавалися про це аж на записі, і рядок падав у карантин.
FINAL_TMP="$(mktemp -d)"
H="$(printf '%064d' 7)"
cat > "$FINAL_TMP/rows.json" <<JSON
{"data":{"rows":[{"identity_hash":"$H","source_hash":"a","source_text":"A shop on Cheongsa Island."}]}}
JSON
cat > "$FINAL_TMP/candidate.json" <<JSON
[{"identity_hash":"$H","text":"Крамниця на Острові Чхонса."}]
JSON
cat > "$FINAL_TMP/verdicts.json" <<JSON
[{"identity_hash":"$H","status":"PASS","severity":"none","issue":"","fix":""}]
JSON
cat > "$FINAL_TMP/validate.json" <<JSON
{"data":{"results":[{"identity_hash":"$H","status":"rejected","code":"glossary_violation",
 "message":"Порушено глосарій.","details":{"glossary":[{"termId":1,"canonical":"Cheongsa Island",
 "expected":"Острів Ліхтарів","issue":"missing","severity":"mandatory"}]}}]}}
JSON
out="$(BDO_STATE_DIR="$FINAL_TMP/state" bash "$ROOT/cli/batch/batch-commit.sh" "$FINAL_TMP/rows.json" \
    "$FINAL_TMP/candidate.json" "$FINAL_TMP/verdicts.json" --channel machine \
    --api-rejected "$FINAL_TMP/validate.json" 2>&1 || true)"
printf '%s' "$out" | grep -Eq 'До запису: 0' \
    || fail "рядок із відмовою API пішов у запис: $out"
printf '%s' "$out" | grep -Eq 'у модерацію: 1' \
    || fail "рядок із відмовою API не потрапив до людини: $out"
# Без прапорця поведінка лишається старою: PASS іде в запис.
out="$(BDO_STATE_DIR="$FINAL_TMP/state" bash "$ROOT/cli/batch/batch-commit.sh" "$FINAL_TMP/rows.json" \
    "$FINAL_TMP/candidate.json" "$FINAL_TMP/verdicts.json" --channel machine 2>&1 || true)"
printf '%s' "$out" | grep -Eq 'До запису: 1' \
    || fail "без відмови API рядок мусить іти в запис: $out"
rm -rf "$FINAL_TMP"

grep -Fq 'final_validate' "$ROOT/cli/run/run-drive.sh" \
    || fail 'run drive більше не робить фінальної валідації перед комітом'


echo 'mechanical final check: OK'
