#!/usr/bin/env bash
# Розділити кандидата на «механічно дефектні» й «чисті» ДО виклику QA.
#
#   ./mechanical-split.sh rows.json clean.json pre-verdicts.json qa-subset.json
#
# Навіщо. `Defects::inTranslation` рахувався лише в `cli/heal/heal-plan.sh`,
# тобто ПІСЛЯ виклику QA. Рядок, який код уже вміє засудити (русизм, гомогліф,
# чужа писемність, зламаний токен, довжина, регістр глосарія), однаково їхав у
# модель, хоча його маршрут уже визначений. Заміряно 2026-08-27: у пачці з 50
# рядків усі 50 містили російську літеру `ё`, і повний прохід QA на 50 рядках
# був витрачений даремно.
#
# Вихід:
#   pre-verdicts.json · вердикти REJECT/critical для дефектних рядків у форматі
#     translation-qa, тобто далі по флоу вони нічим не відрізняються від думки
#     моделі · крім того, що доведені кодом;
#   qa-subset.json · rows-файл лише з чистими рядками; саме його бачить QA.
#
# Порожній `qa-subset` є легальним результатом: тоді виклик QA не потрібен
# зовсім, і рушій іде одразу в лікування.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json}"
CAND_FILE="${2:?Потрібен clean.json}"
PRE_FILE="${3:?Потрібен шлях для pre-verdicts.json}"
SUBSET_FILE="${4:?Потрібен шлях для qa-subset.json}"

php -r '
require $argv[5];

use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\Defects;

$rows = RowSet::fromFile($argv[1]);
$candidate = Candidate::fromFile($argv[2]);
$raw = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$all = $raw["data"]["rows"] ?? [];

$pre = [];
$clean = [];
foreach ($all as $row) {
    $hash = (string) ($row["identity_hash"] ?? "");
    $text = $candidate->text($hash);
    // Рядка немає в кандидаті · це не механічний дефект, а прогалина покриття:
    // її ловить build-items.sh, і підміняти той вирок тут не можна.
    if ($hash === "" || $text === null || trim((string) $text) === "") {
        $clean[] = $row;
        continue;
    }
    $defects = Defects::inTranslation($rows->getOrEmpty($hash), (string) $text);
    if ($defects === []) {
        $clean[] = $row;
        continue;
    }
    $pre[] = [
        "identity_hash" => $hash,
        "status" => "REJECT",
        "severity" => "critical",
        // Причина · дослівний перелік від детектора: далі його читає heal-plan,
        // і людина в модерації бачить те саме, що бачив код.
        "issue" => "механічний дефект: ".implode("; ", $defects),
        "fix" => "",
    ];
}

$raw["data"]["rows"] = $clean;
file_put_contents($argv[4], json_encode($raw, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
file_put_contents($argv[3], json_encode($pre, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));

fprintf(
    STDERR,
    "механіка до QA: дефектних %d, чистих %d із %d\n",
    count($pre),
    count($clean),
    count($all),
);
echo count($clean), "\n";
' "$ROWS_FILE" "$CAND_FILE" "$PRE_FILE" "$SUBSET_FILE" "$SCRIPT_DIR/lib/autoload.php"
