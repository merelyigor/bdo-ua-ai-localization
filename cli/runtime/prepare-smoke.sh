#!/usr/bin/env bash
# Підготувати найдешевший OpenCode child smoke без PHP, API або BDO run.
# Вивід · готовий envelope для видимого штатного OpenCode Task.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$ROOT/state}"
SMOKE_DIR="$STATE_DIR/smoke"
mkdir -p "$SMOKE_DIR"
printf '%s\n' '{"task":"echo_response","response":{"ok":true,"text":"готово"}}' > "$SMOKE_DIR/payload.json"
# Старий response прибирається: інакше механічний капчер результату Task і
# translation_result сприймуть його за відповідь нового прогону.
rm -f "$SMOKE_DIR/response.json"
# Той самий envelope дублюється у state/next-child.json: плагін
# translation-child-contract підставляє з нього точний payload у Task prompt
# і зберігає результат Task у response_path без копіювання диригентом.
php -r 'printf("%s\n", json_encode(["kind" => "child", "role" => "translation-smoke",
    "payload_path" => $argv[1] . "/payload.json",
    "response_path" => $argv[1] . "/response.json",
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));' "$SMOKE_DIR" > "$STATE_DIR/next-child.json"
php -r 'echo json_encode(["ok" => true, "state" => "smoke",
    "next" => json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR),
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";' "$STATE_DIR/next-child.json"
