#!/usr/bin/env bash
# Payload для короткого проходу САМЕ ПО НАЗВАХ · для translation-repair.
#
#   ./names-payload.sh rows.json final-candidate.json validate.json > names-payload.json
#
# Навіщо окремий прохід. Фінальна валідація перед записом відхиляє рядок кодом
# `glossary_violation` і каже ТОЧНО, чого бракує: `details.glossary[].expected`.
# Досі такий рядок після фінальної валідації йшов у модерацію, а модерацію
# сервер перевіряє тим самим правилом і теж відмовляє (D56) · рядок падав у
# карантин і повертався в наступну пачку (D58). Заміряно 2026-09-04: 10% рядків
# пачки локальна модель перекладає без затвердженої назви · це вже якість
# моделі, і найдешевше її виправити одним коротким проходом, де в payload немає
# нічого, крім рядка й наказу «ужий «X» для «Y»».
#
# Тут лише рядки з `glossary_violation`, у яких є `expected`; інші відмови
# (розмітка, довжина) цим проходом не лікуються й ідуть звичайним шляхом.
# Порожній масив означає, що прохід не потрібен.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json}"
CAND_FILE="${2:?Потрібен final-candidate.json}"
VALIDATE_FILE="${3:?Потрібен файл відповіді validate}"

php -r '
require $argv[4];
use Bdo\Translate\Api\Response;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1]);
$candidate = Candidate::fromFile($argv[2]);
$validate = is_file($argv[3]) ? Response::fromFile($argv[3], "validate") : null;

$payload = [];
foreach ($validate?->results() ?? [] as $result) {
    if (($result["status"] ?? "") !== "rejected" || ($result["code"] ?? "") !== "glossary_violation") continue;
    $hash = (string) ($result["identity_hash"] ?? "");
    if ($hash === "" || ! $rows->has($hash) || ! $candidate->has($hash)) continue;
    $orders = [];
    foreach ($result["details"]["glossary"] ?? [] as $issue) {
        $expected = (string) ($issue["expected"] ?? "");
        $canonical = (string) ($issue["canonical"] ?? "");
        if ($expected === "" || $canonical === "") continue;
        // Той самий наказ, що й у Response::rejections(): repair його вже знає.
        $orders[] = sprintf("ужий «%s» для «%s»", $expected, $canonical);
    }
    if ($orders === []) continue;
    $row = $rows->getOrEmpty($hash);
    $item = [
        "identity_hash" => $hash,
        "source_text" => $row->sourceText(),
        "current" => $candidate->text($hash),
        "defects" => array_values(array_unique($orders)),
    ];
    $keep = $row->keepTokens();
    if ($keep !== []) $item["keep"] = $keep;
    $glossary = $row->glossary();
    if ($glossary !== []) $item["glossary"] = $glossary;
    $limits = $row->limits();
    if ($limits !== null) $item["limits"] = $limits;
    $payload[] = $item;
}
echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
fwrite(STDERR, sprintf("прохід по назвах: %d рядків із наказом «ужий»\n", count($payload)));
' "$ROWS_FILE" "$CAND_FILE" "$VALIDATE_FILE" "$SCRIPT_DIR/lib/autoload.php"
