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

// 3. Той самий детектор бачить дефект у фінальному тексті рядка.
$file = tempnam(sys_get_temp_dir(), "rows");
file_put_contents($file, json_encode(["data" => ["rows" => [[
    "identity_hash" => str_repeat("a", 64), "source_hash" => "x", "source_text" => "Armor Set",
]]]], JSON_THROW_ON_ERROR));
$row = RowSet::fromFile($file)->getOrEmpty(str_repeat("a", 64));
unlink($file);
if (Defects::inTranslation($row, "Комплект обладунків") !== []) $fail("чистий текст позначено дефектним");
foreach (["Комплект доспехів", "Комплект 0бладунків", "Видається на протязі дня"] as $bad) {
    if (Defects::inTranslation($row, $bad) === []) $fail("дефект у фінальному тексті пропущено: $bad");
}
' "$ROOT/lib/autoload.php" || fail 'детектори не тримають контракт'

# 4. Вирок маршруту · поведінкою, а не пошуком тексту в скрипті.
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

echo 'mechanical final check: OK'
