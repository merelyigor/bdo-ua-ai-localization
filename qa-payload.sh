#!/usr/bin/env bash
# Побудувати компактний payload для translation-qa.
#
#   ./qa-payload.sh rows.json candidate.json
#
# Друкує JSON-масив: identity_hash, source_text, candidate, glossary, keep.
# QA працює під constrained decoding, а обмежена відповідь не може містити
# викликів інструментів, тому QA НЕ читає файли сам: усе, що йому потрібно,
# приходить цим payload.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"
CANDIDATE_FILE="${2:?Потрібен candidate.json від translation-worker}"

php -r '
require $argv[3];
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1]);
$candidate = Candidate::fromFile($argv[2]);

$payload = [];
foreach ($rows as $row) {
    $hash = $row->identityHash();
    if (!$candidate->has($hash)) throw new RuntimeException("Немає перекладу для $hash");
    $item = [
        "identity_hash" => $hash,
        "source_text" => $row->sourceText(),
        "candidate" => $candidate->text($hash),
    ];
    if ($row->semanticType() !== null) $item["semantic_type"] = $row->semanticType();
    $glossary = $row->glossary();
    if ($glossary !== []) $item["glossary"] = $glossary;
    $keep = $row->keepTokens();
    if ($keep !== []) $item["keep"] = $keep;
    // Ті самі сигнали, що бачив воркер: інакше QA судить у гірших умовах,
    // ніж той, кого він перевіряє, і вигадує претензії до канонічності.
    $pending = $row->pendingTerms();
    if ($pending !== []) $item["canonical_pending"] = $pending;
    $limits = $row->limits();
    if ($limits !== null) $item["limits"] = $limits;
    if ($row->isNonTranslatable()) $item["non_translatable"] = true;
    $payload[] = $item;
}
echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
' "$ROWS_FILE" "$CANDIDATE_FILE" "$SCRIPT_DIR/lib/autoload.php"
