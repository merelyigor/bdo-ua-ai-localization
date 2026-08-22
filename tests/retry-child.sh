#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/batches/test"
printf '%s\n' 'test' > "$TMP/current-batch"
printf '%s\n' '{"role":"translation-worker","attempts":[{"error":"fetch failed"}]}' > "$TMP/batches/test/candidate.json.failure.json"

if BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/retry-child.sh" status >/dev/null; then
    echo 'status accepted an open circuit' >&2
    exit 1
fi
BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/retry-child.sh" reset >/dev/null
test ! -f "$TMP/batches/test/candidate.json.failure.json"
test "$(find "$TMP/batches/test" -name 'candidate.json.failure.*.json' | wc -l | tr -d ' ')" = 1
BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/retry-child.sh" status | grep -Fq 'closed'
echo 'retry child: OK'
