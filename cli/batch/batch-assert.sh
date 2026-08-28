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

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
# Без аргументу перевіряємо ПОТОЧНУ пачку.
#
# `./bdo batch check` · діагностична команда, і саме так її називає реєстр
# (`batch new|dir|check|end`). 2026-08-28 диригент виконав її під час розбору й
# отримав `batch-assert.sh: line 15: 1: Потрібен rows.json` · сире повідомлення
# bash із номером рядка чужого скрипта замість відповіді на питання «чи файли
# пачки свої». Питання має відповідь за замовчуванням: rows.json поточної пачки.
ROWS_FILE="${1:-}"
CAND_FILE="${2:-}"
if [ -z "$ROWS_FILE" ]; then
    BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
    if [ -z "$BATCH_DIR" ]; then
        echo 'ПОМИЛКА: пачку не розпочато · перевіряти нічого. Почни з ./bdo mode start.' >&2
        exit 1
    fi
    ROWS_FILE="$BATCH_DIR/rows.json"
    if [ ! -s "$ROWS_FILE" ]; then
        echo "ПОМИЛКА: у пачці немає rows.json ($ROWS_FILE)." >&2
        exit 1
    fi
fi

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
' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$ROWS_FILE" "$CAND_FILE"
