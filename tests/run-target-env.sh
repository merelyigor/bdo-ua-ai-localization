#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "$ROOT/cli/system/select-env.sh" >/dev/null
if [ "$BDO_API_ENV" = prod ]; then wrong=local; else wrong=prod; fi
printf '%s\n' "$wrong" > "$TMP/run-target"
if BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null 2>&1; then
    echo 'run-target mismatch was accepted' >&2
    exit 1
fi
printf '%s\n' "$BDO_API_ENV" > "$TMP/run-target"
BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null
echo 'run target env guard: OK'
