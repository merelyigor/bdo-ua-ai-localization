#!/usr/bin/env bash
# Показати терміни пачки, для яких канонічний відповідник ще не затверджено.
#
#   ./glossary-gaps.sh rows.json
#
# Термін із severity=mandatory і ukrainian=null означає: назва оголошена
# канонічною, але жоден варіант не затверджений. Якщо перекласти такий рядок
# наосліп, вигадка воркера стане фактичним стандартом патча. Тому цей крок
# виконується ЗАВЖДИ після fetch-rows, а не «за потреби».
#
# Код виходу завжди 0: це запит стану, а не помилка, і він не має обривати
# ланцюг команд. Рішення приймається за текстом вироку в останньому рядку.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"

php -r '
require $argv[2];
use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1]);
$pending = [];
$unresolved = [];
$resolved = 0;
foreach ($rows as $row) {
    $resolved += count($row->glossary());
    foreach ($row->pendingTerms() as $name) $pending[$name] = true;
    foreach ($row->unresolvedEntities() as $name) $unresolved[$name] = $row->identityHash();
}
$pending = array_keys($pending);
printf("Рядків: %d | затверджених термінів: %d | без відповідника: %d | нерозпізнаних назв: %d\n",
    count($rows), $resolved, count($pending), count($unresolved));
foreach ($pending as $name) echo "  без відповідника: $name\n";
foreach ($unresolved as $name => $hash) printf("  нерозпізнана назва: %s\n", $name);
echo "\n";
if ($pending === [] && $unresolved === []) {
    echo "ВИРОК: прогалин немає, можна одразу до translation-worker.\n";
} elseif ($pending !== []) {
    echo "ВИРОК: спочатку translation-terminology для цих термінів, потім worker.\n";
}
if ($unresolved !== []) {
    // Ці рядки API впізнав як назви сутностей, але каталог їх не знає. QA звіряти
    // нема з чим, тому вердикт буде PASS, і в ШІ-шар вони ЗАПИСУЮТЬСЯ як звичайні:
    // рішення власника 2026-08-16 (нова назва предмета не є дефектом; на живій
    // пачці маршрут у модерацію давав 0 записаних рядків проти 13).
    //
    // Раніше цей вирок казав «у модерацію, не в ШІ-шар» · це було невірно й
    // небезпечно: диригент вважав рядок відкладеним, тоді як він ішов у шар.
    // У модерацію такі рядки йдуть лише в ручному прогоні
    // (`bdo commit --names-to-moderation`) і лише для domain=item.
    printf("ВИРОК: %d рядків із нерозпізнаними назвами. Вони ПІДУТЬ у ШІ-шар як нові переклади:\n", count($unresolved));
    echo "        воркер отримує їх позначеними (`unresolved`) і перекладає буквально.\n";
    echo "        У модерацію - лише в ручному прогоні: bdo commit --channel manual --names-to-moderation\n";
}
' "$ROWS_FILE" "$SCRIPT_DIR/lib/autoload.php"
