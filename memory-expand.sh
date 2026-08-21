#!/usr/bin/env bash
# Зібрати повного кандидата: переклад моделі + близнюки + те, що дала памʼять.
#
#   ./memory-expand.sh candidate.json twins.json memory-candidate.json > full.json
#
# Близнюк отримує текст свого представника з тієї самої пачки: однаковий
# англійський оригінал не має давати двох різних українських варіантів у межах
# однієї пачки - саме так корпус і починає суперечити сам собі.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAND_FILE="${1:?Потрібен candidate.json від воркера}"
TWINS_FILE="${2:?Потрібен twins.json}"
MEMORY_CAND="${3:-}"

php -r '
require $argv[1];
use Bdo\Translate\Batch\Candidate;

$byHash = Candidate::fromFile($argv[2])->all();
if ($argv[4] !== "" && file_exists($argv[4])) {
    $byHash += Candidate::fromFile($argv[4])->all();
}
$twins = file_exists($argv[3]) ? (json_decode(file_get_contents($argv[3]), true) ?: []) : [];

$filled = 0;
foreach ($twins as $twin => $representative) {
    if (!isset($byHash[$representative])) {
        fwrite(STDERR, "Немає перекладу представника для " . substr((string) $twin, 0, 12) . "\n");
        exit(1);
    }
    $byHash[$twin] = $byHash[$representative];
    $filled++;
}
fprintf(STDERR, "Зібрано %d рядків (з них близнюків заповнено %d)\n", count($byHash), $filled);
$out = [];
foreach ($byHash as $hash => $text) $out[] = ["identity_hash" => $hash, "text" => $text];
echo json_encode($out, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT), "\n";
' "$SCRIPT_DIR/lib/autoload.php" "$CAND_FILE" "$TWINS_FILE" "$MEMORY_CAND"
