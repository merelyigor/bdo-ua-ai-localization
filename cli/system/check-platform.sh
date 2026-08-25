#!/usr/bin/env bash
# Перевірити підтримувану платформу: macOS, Linux або Windows через WSL2.
set -euo pipefail

kernel="$(uname -s)"
case "$kernel" in
Darwin) echo 'Платформа: macOS' ;;
Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
        test -n "${WSL_DISTRO_NAME:-}" || { echo 'FAIL: виявлено WSL без WSL_DISTRO_NAME; потрібен WSL2 runtime.' >&2; exit 1; }
        case "$(pwd -P)" in
        /mnt/*) echo 'WARN: репозиторій лежить на Windows mount; для швидкості перенеси його у Linux filesystem (наприклад ~/GitHub).' >&2 ;;
        esac
        echo "Платформа: Windows/WSL2 (${WSL_DISTRO_NAME})"
    else echo 'Платформа: Linux'
    fi
    ;;
*) echo "FAIL: $kernel не підтримується; на Windows використовуй WSL2." >&2; exit 1 ;;
esac

# `sqlite3` у переліку не для краси: `./bdo audit` читає ним базу OpenCode, а
# аудит є єдиним джерелом правди про субагентів. Без нього збій вилазив аж у
# кінці прогону, коли перевіряти вже пізно.
for tool in bash php jq curl git sqlite3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "FAIL: немає $tool" >&2
        if grep -qi microsoft /proc/version 2>/dev/null; then
            echo 'Встанови залежність ВСЕРЕДИНІ WSL2, не через winget. Ubuntu 24.04: sudo apt update && sudo apt install php-cli jq curl git sqlite3 shellcheck' >&2
        fi
        exit 1
    fi
done
php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
php -r 'exit(PHP_VERSION_ID >= 80300 ? 0 : 1);' 2>/dev/null || { echo "FAIL: потрібен PHP 8.3+, знайдено ${php_version:-невідому версію}." >&2; exit 1; }

# Дані OpenCode можуть лежати по інший бік межі WSL: сам застосунок · native
# Windows, а цей скрипт · Linux. Тут це попередження, а не FAIL: пачку можна
# прогнати й без аудиту, а от мовчки дізнатись про це в кінці · не можна.
# shellcheck source=/dev/null
source "$(cd "$(dirname "$0")/../.." && pwd)/cli/system/opencode-home.sh"
if [ -n "$OPENCODE_DB" ]; then
    echo "База OpenCode: $OPENCODE_DB"
else
    echo "WARN: бази OpenCode не видно, ./bdo audit і models не працюватимуть. Перевірено:" >&2
    printf '%s' "$OPENCODE_TRIED" >&2
    echo 'Native Windows OpenCode із набором у WSL: додай у .env BDO_OPENCODE_HOME=/mnt/c/Users/<user>' >&2
fi
echo 'Platform preflight: OK'
