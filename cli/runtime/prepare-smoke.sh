#!/usr/bin/env bash
# Підготувати найдешевший OpenCode child smoke без PHP, API або BDO run.
# Вивід · готовий envelope для видимого штатного OpenCode Task.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$ROOT/state}"
SMOKE_DIR="$STATE_DIR/smoke"
mkdir -p "$SMOKE_DIR"
printf '%s\n' '{"request":"Return the exact capability object required by your strict schema."}' > "$SMOKE_DIR/payload.json"
printf '%s\n' '{"ok":true,"state":"smoke","next":{"kind":"child","role":"translation-smoke","payload_path":"smoke/payload.json","response_path":"smoke/response.json"}}'
