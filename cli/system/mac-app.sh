#!/usr/bin/env bash
# Виконуваний shell-вхід для BDO.app. Уся логіка Dock живе в PHP-команді
# `mac-app`; тут лишається тільки PATH bootstrap і передача керування.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SCRIPT_DIR

# LaunchServices може запустити скопійований бандл без теки набору поруч.
# Це єдина помилка, яку треба пояснити до переходу в PHP: самого entrypoint
# поруч уже немає.
if [ ! -x "$SCRIPT_DIR/bdo" ]; then
    printf '%s\n' 'Набір не знайдено поруч із додатком.' >&2
    exit 1
fi

# LaunchServices starts this script without the terminal PATH. Bootstrap it
# before the PHP entrypoint is called; PHP cannot repair PATH after its shebang.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/cli/system/gui-path.sh"

PHP_BIN="$(command -v php)"
exec "$PHP_BIN" "$SCRIPT_DIR/cli/bdo.php" mac-app "${1:-start}"
