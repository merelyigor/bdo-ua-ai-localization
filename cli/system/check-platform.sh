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

for tool in bash php jq curl git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: немає $tool" >&2; exit 1; }
done
echo 'Platform preflight: OK'
