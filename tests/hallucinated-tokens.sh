#!/usr/bin/env bash
# Детектор вигаданих токенів · розмітка, якої немає у джерелі.
#
# Токеном вважається `{...}` або `<...>`. Дефект: токен у тексті
# трапляється більше разів, ніж у джерелі. На живій пачці 2026-08-27
# із 400 рядків: 6 випадків, `{PAEnd}` вигадано 4 рази при 0 у джерелі,
# один рядок дістав цілу пару `<PAColor0x…>` + `<PAOldColor>` без аналогів.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

php -r '
require $argv[1];
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\Defects;
use Bdo\Translate\Quality\HallucinatedTokens;

$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };

// Тестовий набір для чотирьох випадків
$H1 = str_repeat("1", 64);
$H2 = str_repeat("2", 64);
$H3 = str_repeat("3", 64);
$H4 = str_repeat("4", 64);

$file = tempnam(sys_get_temp_dir(), "rows");
file_put_contents($file, json_encode(["data" => ["rows" => [
    // Випадок А: {PAEnd} у перекладі при 0 у джерелі
    ["identity_hash" => $H1, "source_hash" => "a", "source_text" => "Source text"],
    // Випадок Б: токен, який у джерелі є стільки ж разів
    ["identity_hash" => $H2, "source_hash" => "b", "source_text" => "Text with {BDO_NL}"],
    // Випадок В: токен у джерелі є 1 раз, а в перекладі 2
    ["identity_hash" => $H3, "source_hash" => "c", "source_text" => "Text with <PAColor>"],
    // Випадок Г: токен у cosmetic tokens · дефекту немає
    ["identity_hash" => $H4, "source_hash" => "d", "source_text" => "Text",
     "tokens" => ["cosmetic" => ["<PAOldColor>" => 1]]],
]]], JSON_THROW_ON_ERROR));

$rows = RowSet::fromFile($file);
unlink($file);

// А) {PAEnd} у перекладі при 0 у джерелі → дефект є
$rowA = $rows->getOrEmpty($H1);
$textA = "Source text {PAEnd}";
$defectsA = Defects::inTranslation($rowA, $textA);
if (!array_filter($defectsA, fn($d) => str_contains($d, "вигаданий токен") && str_contains($d, "{PAEnd}"))) {
    $fail("А) {PAEnd} вигадано, але дефект не знайдено");
}

// Б) токен, який у джерелі є стільки ж разів → дефекту немає
$rowB = $rows->getOrEmpty($H2);
$textB = "Переклад with {BDO_NL}";
$defectsB = Defects::inTranslation($rowB, $textB);
if (array_filter($defectsB, fn($d) => str_contains($d, "вигаданий токен"))) {
    $fail("Б) токен із джерела стільки ж разів не мусить бути дефектом");
}

// В) токен у джерелі є 1 раз, а в перекладі 2 → дефект є
$rowC = $rows->getOrEmpty($H3);
$textC = "Переклад <PAColor> з додатком <PAColor>";
$defectsC = Defects::inTranslation($rowC, $textC);
if (!array_filter($defectsC, fn($d) => str_contains($d, "вигаданий токен") && str_contains($d, "<PAColor>"))) {
    $fail("В) додатковий <PAColor> мусить бути дефектом");
}

// Г) токен у cosmetic tokens · дефекту НЕМАЄ
$rowD = $rows->getOrEmpty($H4);
$textD = "Text <PAOldColor>";
$defectsD = Defects::inTranslation($rowD, $textD);
if (array_filter($defectsD, fn($d) => str_contains($d, "вигаданий токен") && str_contains($d, "<PAOldColor>"))) {
    $fail("Г) косметичний токен не мусить бути дефектом");
}
' "$ROOT/lib/autoload.php" || fail 'механічна перевірка вигаданих токенів впала'

echo 'hallucinated tokens: OK · детектор сорт чотири випадки'
