#!/usr/bin/env bash
# Почати пачку: створити ізольовану теку під її робочі файли.
#
#   ./batch-new.sh rows.json      # почати пачку з цієї вибірки
#   ./batch-new.sh --show         # яка пачка зараз поточна
#   ./batch-new.sh --end          # закрити пачку (тека лишається)
#
# Навіщо. Робочі файли пачки раніше мали фіксовані імена в state/, тож друга
# пачка мовчки затирала першу, а імена rows і candidate диригент вигадував сам.
# Схема з enum рятувала від чужого identity всередині відповіді моделі, але не
# від чужого ФАЙЛА на вході. Тепер кожна пачка має власну теку
# state/batches/<час>_<ключ>/, а manifest зберігає ключ набору identity, тому
# приналежність файла перевіряється, а не мається на увазі.
#
# Друкує шлях теки: усі наступні кроки складають свої файли саме туди.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
mkdir -p "$STATE_DIR"

case "${1:-}" in
    --show)
        php -r '
        require $argv[1];
        $w = Bdo\Translate\Batch\Workspace::current($argv[2]);
        if ($w === null) { echo "Пачку не розпочато.\n"; exit(0); }
        $m = $w->manifest();
        printf("Поточна пачка: %s\n  рядків: %s | ключ: %s | створено: %s\n  тека: %s\n",
            $w->id(), $m["rows"] ?? "?", $m["identity_key"] ?? "?", $m["created_at"] ?? "?", $w->dir());
        ' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR"
        exit 0
        ;;
    --end)
        php -r '
        require $argv[1];
        Bdo\Translate\Batch\Workspace::closeCurrent($argv[2]);
        echo "Пачку закрито. Тека лишилась - прибирає ./bdo clean\n";
        ' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR"
        exit 0
        ;;
esac

ROWS_FILE="${1:?Потрібен rows.json з API}"
test -f "$ROWS_FILE" || { echo "Немає файлу: $ROWS_FILE" >&2; exit 1; }

# Час формує bash: у PHP-класі не має бути прихованої залежності від годинника,
# інакше той самий набір рядків дає різний результат при кожному виклику.
STAMP="$(date +%Y%m%d_%H%M%S)"

php -r '
require $argv[1];
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Batch\Workspace;

$rows = RowSet::fromFile($argv[2]);
$rows->identityHashes();   // формат і унікальність - до створення теки
$workspace = Workspace::create($argv[3], $rows, $argv[4]);

// Вибірка копіюється в теку пачки й далі береться звідти: інакше вихідний файл
// можна перезаписати наступним fetch-rows, і пачка втратить своє джерело.
copy($argv[2], $workspace->path("rows.json"));

printf("Пачку розпочато: %s\n  рядків: %d | ключ набору: %s\n", $workspace->id(), count($rows), $rows->key());
printf("  тека: %s\n", $workspace->dir());
echo "\nДалі всі файли пачки складай сюди. Рядки бери з rows.json у цій теці.\n";
' "$SCRIPT_DIR/lib/autoload.php" "$ROWS_FILE" "$STATE_DIR" "$STAMP"
