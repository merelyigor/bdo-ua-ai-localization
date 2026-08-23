#!/usr/bin/env bash
# Підготувати найдешевший OpenCode child smoke без PHP, API або BDO run.
# Вивід · готовий envelope для видимого штатного OpenCode Task.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$ROOT/state}"
SMOKE_DIR="$STATE_DIR/smoke"
mkdir -p "$SMOKE_DIR"
printf '%s\n' '{"task":"echo_response","response":{"ok":true,"text":"готово"}}' > "$SMOKE_DIR/payload.json"
php -r 'echo json_encode(["ok" => true, "state" => "smoke", "next" => [
    "kind" => "child", "role" => "translation-smoke",
    "payload_path" => $argv[1] . "/payload.json",
    "response_path" => $argv[1] . "/response.json",
]], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";' "$SMOKE_DIR"
