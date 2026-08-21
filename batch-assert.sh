#!/usr/bin/env bash
# Перевірити, що файли належать поточній пачці.
#
#   ./batch-assert.sh rows.json [candidate.json]
#
# Окремий крок, а не частина кожного скрипта, з двох причин: його може викликати
# і диригент перед будь-якою дією, і сусідні скрипти; і вивід тут чистий -
# у `php -r` уроджений обробник виключень не працює, тому текст помилки інакше
# тонув би у PHP-трасуванні, яке агент переказує власнику як «сталася помилка».
#
# Код виходу: 0 - файли свої, 1 - чужі або пачку не розпочато.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROWS_FILE="${1:?Потрібен rows.json}"
CAND_FILE="${2:-}"

php -r '
require $argv[1];
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;

try {
    $workspace = Workspace::requireCurrent($argv[2]);
    $rows = RowSet::fromFile($argv[3]);
    $workspace->assertRows($rows);
    if ($argv[4] !== "") {
        $workspace->assertCandidate($rows, Candidate::fromFile($argv[4]));
    }
} catch (Throwable $e) {
    fwrite(STDERR, "ПОМИЛКА: " . $e->getMessage() . "\n");
    exit(1);
}
printf("Файли належать пачці %s (%d рядків).\n", $workspace->id(), count($rows));
' "$SCRIPT_DIR/lib/autoload.php" "${BDO_STATE_DIR:-$SCRIPT_DIR/state}" "$ROWS_FILE" "$CAND_FILE"
