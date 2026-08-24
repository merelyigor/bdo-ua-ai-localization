#!/usr/bin/env bash
# Побудувати payload для translation-judge · лише спірні рядки пачки.
#
#   ./judge-payload.sh rows.json candidate.json verdicts.json [validate.json]
#
# Друкує JSON-масив спірних рядків у stdout, а в stderr · підсумок. Порожній
# масив означає, що судити нема чого й виклик моделі не потрібен.
#
# ЩО ТАКЕ СПІРНИЙ РЯДОК. Не «будь-який не-PASS»: механічний дефект (зламаний
# токен, довжина, гомогліф, русизм) є фактом, і його маршрут визначено без
# моделі. Спір · це там, де рішення потребує судження:
#   - переклад дорівнює джерелу (назва продукту або справді пропущений рядок);
#   - QA дав не-PASS, але механіка чиста.
#
# Суддя не отримує інструментів (виклик інструмента вимикає constrained
# decoding), тому все потрібне для рішення кладеться сюди скриптом: джерело,
# кандидат, глосарій, приклади, межі, вердикт QA, механічні дефекти й код
# відмови API, якщо він був.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json}"
CAND_FILE="${2:?Потрібен candidate.json}"
VERDICT_FILE="${3:?Потрібен verdicts.json}"
VALIDATE_FILE="${4:-}"

CONTEXT_FILE=""
BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
test -n "$BATCH_DIR" && test -f "$BATCH_DIR/context.json" && CONTEXT_FILE="$BATCH_DIR/context.json"

php -r '
require $argv[6];
use Bdo\Translate\Api\Response;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Pipeline\JudgePolicy;
use Bdo\Translate\Quality\Defects;

$rows = RowSet::fromFile($argv[1]);
$candidate = Candidate::fromFile($argv[2]);
$verdicts = [];
foreach (json_decode((string) file_get_contents($argv[3]), true) ?: [] as $v) {
    $verdicts[$v["identity_hash"] ?? ""] = $v;
}
$validate = $argv[4] !== "" && file_exists($argv[4]) ? Response::fromFile($argv[4], "validate") : null;
$rejections = $validate?->rejections() ?? [];
$examplesByHash = [];
if ($argv[5] !== "" && file_exists($argv[5])) {
    $examplesByHash = json_decode((string) file_get_contents($argv[5]), true) ?: [];
}

$payload = [];
$stats = ["identical" => 0, "unresolved" => 0, "qa" => 0, "mechanical" => 0];
foreach ($rows as $row) {
    $hash = $row->identityHash();
    if (! $candidate->has($hash)) continue;
    $text = $candidate->text($hash);
    if (trim($text) === "") continue;          // порожнє · це збій, а не спір

    $mechanical = Defects::inTranslation($row, $text);
    $verdict = $verdicts[$hash] ?? [];
    $status = (string) ($verdict["status"] ?? "PASS");
    $severity = (string) ($verdict["severity"] ?? "none");
    $identical = $text === $row->sourceText();
    $unresolved = $row->unresolvedEntities();

    if ($mechanical !== []) { $stats["mechanical"]++; continue; }
    if (! JudgePolicy::isDisputed($status, $severity, $mechanical, $identical)) continue;

    $item = [
        "identity_hash" => $hash,
        "source_text" => $row->sourceText(),
        "candidate" => $text,
    ];
    if ($row->semanticType() !== null) $item["semantic_type"] = $row->semanticType();
    if ($identical) { $item["identical_to_source"] = true; $stats["identical"]++; }
    if ($unresolved !== []) { $item["unresolved"] = $unresolved; $stats["unresolved"]++; }
    $glossary = $row->glossary();
    if ($glossary !== []) $item["glossary"] = $glossary;
    $pending = $row->pendingTerms();
    if ($pending !== []) $item["canonical_pending"] = $pending;
    $limits = $row->limits();
    if ($limits !== null) $item["limits"] = $limits;
    if (! empty($examplesByHash[$hash])) $item["examples"] = $examplesByHash[$hash];
    if (strtoupper($status) !== "PASS") {
        $item["qa"] = ["status" => $status, "severity" => $severity, "issue" => (string) ($verdict["issue"] ?? "")];
        $stats["qa"]++;
    }
    // Відмова API · окремий сигнал: суддя має знати, що сервер цей текст не
    // прийме, і що його вирок тут потрібен для журналу, а не для запису.
    if (isset($rejections[$hash])) $item["api_rejected"] = $rejections[$hash];
    $payload[] = $item;
}

echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
fwrite(STDERR, sprintf(
    "payload судді: %d спірних рядків | переклад=джерело %d | нерозпізнані назви %d | вердикт QA %d | механічні (без судді, у модерацію) %d\n",
    count($payload), $stats["identical"], $stats["unresolved"], $stats["qa"], $stats["mechanical"]));
' "$ROWS_FILE" "$CAND_FILE" "$VERDICT_FILE" "$VALIDATE_FILE" "$CONTEXT_FILE" "$SCRIPT_DIR/lib/autoload.php"
