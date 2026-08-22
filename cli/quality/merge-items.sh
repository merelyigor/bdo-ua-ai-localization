#!/usr/bin/env bash
# Влити виправлення repair у наявний кандидат без повторного перекладу пачки.
#
#   ./merge-items.sh candidate.json fixes.json merged.json
#
# candidate.json і fixes.json - масиви {identity_hash, text}. Кожен хеш із
# fixes мусить існувати в candidate; дублікат або чужий хеш - помилка.
set -euo pipefail

BASE_FILE="${1:?Потрібен candidate.json (повна пачка)}"
FIXES_FILE="${2:?Потрібен fixes.json від translation-repair}"
OUTPUT_FILE="${3:?Потрібен вихідний merged.json}"

php -r '
$base = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$fixes = json_decode(file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
if (!is_array($base) || $base === []) throw new RuntimeException("candidate.json порожній або не масив");
$index = [];
foreach ($base as $i => $item) {
    $hash = $item["identity_hash"] ?? "";
    if (!is_string($hash) || $hash === "") throw new RuntimeException("Елемент без identity_hash у candidate.json");
    $index[$hash] = $i;
}
$seen = [];
$replaced = 0;
foreach ($fixes as $fix) {
    $hash = $fix["identity_hash"] ?? "";
    $text = $fix["text"] ?? null;
    if (!isset($index[$hash])) throw new RuntimeException("Виправлення для хеша поза кандидатом: $hash");
    if (isset($seen[$hash])) throw new RuntimeException("Дубль хеша у fixes.json: $hash");
    if (!is_string($text) || trim($text) === "") throw new RuntimeException("Порожній text у виправленні $hash");
    $seen[$hash] = true;
    $base[$index[$hash]]["text"] = $text;
    $replaced++;
}
if ($replaced === 0) throw new RuntimeException("fixes.json не містить жодного виправлення");
file_put_contents($argv[3], json_encode($base, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
echo "Замінено $replaced рядків із " . count($base) . "\n";
' "$BASE_FILE" "$FIXES_FILE" "$OUTPUT_FILE"
