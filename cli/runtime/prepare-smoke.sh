#!/usr/bin/env bash
# Підготувати найдешевший OpenCode child smoke без PHP, API або BDO run.
# Вивід · готовий envelope для видимого штатного OpenCode Task.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$ROOT/state}"
SMOKE_DIR="$STATE_DIR/smoke"
mkdir -p "$SMOKE_DIR"
# Smoke мусить перевіряти ТУ САМУ схему, що й робочі ролі.
#
# Досі він мав власну крихітну схему з обʼєктним коренем і двома `const`, і саме
# тому півтора місяця показував «маршрут здоровий» на конфігурації, де жоден
# реальний child не працював: staged-схема робочих ролей мала корінь `array`,
# який OpenAI-сумісні провайдери відхиляють кодом `[400]`. Виміряно 2026-08-27:
# `opencode-go` мав 0 успішних дитячих сесій із 3 при зелених smoke.
#
# Тепер smoke будує справжню staged-схему через той самий `build-schema.sh` на
# одному синтетичному рядку. Форма, ключі й обгортка · один в один як у воркера,
# тому провайдер, який не приймає робочу схему, валить саме smoke.
SMOKE_HASH="$(printf 'bdo-smoke-row' | shasum -a 256 | awk '{print $1}')"
php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [[
    "identity_hash" => $argv[2], "source_hash" => hash("sha256", "smoke"), "source_text" => "Ancient Sword",
]]]], JSON_THROW_ON_ERROR));' "$SMOKE_DIR/rows.json" "$SMOKE_HASH"
BDO_STATE_DIR="$STATE_DIR" bash "$ROOT/cli/prepare/build-schema.sh" \
    --out "$STATE_DIR/current-smoke-schema.json" "$SMOKE_DIR/rows.json" >/dev/null
php -r 'file_put_contents($argv[1], json_encode([[
    "identity_hash" => $argv[2], "source_text" => "Ancient Sword",
]], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));' "$SMOKE_DIR/payload.json" "$SMOKE_HASH"
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
