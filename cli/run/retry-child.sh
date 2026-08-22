#!/usr/bin/env bash
# Показати або контрольовано скинути відкритий child circuit поточної пачки.
# Reset нічого не видаляє: failure receipt перейменовується в audit archive.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BATCH="$($ROOT/cli/batch/batch-dir.sh)"
action="${1:-status}"
shopt -s nullglob
failures=("$BATCH"/*.failure.json)

case "$action" in
status)
    if [ "${#failures[@]}" -eq 0 ]; then echo 'Child circuit: closed'; exit 0; fi
    echo "Child circuit: OPEN (${#failures[@]} failure receipt)"
    for file in "${failures[@]}"; do
        jq '{role,failed_at,attempts}' "$file"
    done
    exit 1
    ;;
reset)
    test "${#failures[@]}" -gt 0 || { echo 'Child circuit уже закритий.'; exit 0; }
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    for file in "${failures[@]}"; do
        archived="${file%.failure.json}.failure.${stamp}.json"
        mv "$file" "$archived"
        echo "Архівовано: $archived"
    done
    echo 'Child circuit: reset. Наступний translation_child знову має максимум 3 спроби.'
    ;;
*) echo 'Використання: ./bdo retry status|reset' >&2; exit 2 ;;
esac
