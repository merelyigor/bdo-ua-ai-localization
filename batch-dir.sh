#!/usr/bin/env bash
# Надрукувати теку поточної пачки; порожньо й код 1, якщо пачку не розпочато.
#
# Допоміжний однорядковий скрипт: інші скрипти й диригент питають шлях саме
# так, замість складати його вручну з ідентифікатора.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
php -r '
require $argv[1];
$w = Bdo\Translate\Batch\Workspace::current($argv[2]);
if ($w === null) exit(1);
echo $w->dir();
' "$SCRIPT_DIR/lib/autoload.php" "${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
