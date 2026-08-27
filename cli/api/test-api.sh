#!/usr/bin/env bash
# Перевірка з'єднання з API: /me, /guide (хедер), /taxonomy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/cli/system/select-env.sh"

API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }

echo "== 1. /me =="
ME_FILE=$(mktemp)
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/me" > "$ME_FILE"
php -r '
require $argv[2];
$response = Bdo\Translate\Api\Response::fromJson((string) file_get_contents($argv[1]), "/me");
$d = $response->raw();
echo "OK\n";
$u = $d["data"]["user"];
$l = $d["data"]["limits"];
echo "  {$u["email"]} ({$u["role"]})\n";
echo "  запитів/хв: {$l["requests_per_minute"]}\n";
echo "  рядків лишилось сьогодні: {$l["rows_remaining_today"]}\n";
echo "  квота скидається: {$l["quota_resets_at"]}\n";
' "$ME_FILE" "$SCRIPT_DIR/lib/autoload.php"
rm -f "$ME_FILE"

echo ""
echo "== 2. /guide (хедер) =="
GUIDE_FILE=$(mktemp)
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/guide" > "$GUIDE_FILE"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromJson((string) file_get_contents($argv[1]), "/guide")->raw();
echo "OK\n";
echo "  версія: {$d["data"]["version"]}\n";
echo "  жорстких правил: " . count($d["data"]["hard_rules"] ?? []) . "\n";
echo "  заборон: " . count($d["data"]["never"] ?? []) . "\n";
' "$GUIDE_FILE" "$SCRIPT_DIR/lib/autoload.php"
rm -f "$GUIDE_FILE"

echo ""
echo "== 3. /taxonomy =="
TAX_FILE=$(mktemp)
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/taxonomy" > "$TAX_FILE"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromJson((string) file_get_contents($argv[1]), "/taxonomy")->raw();
if (($d["success"] ?? false) === true) { echo "OK\n"; }
else { echo "FAIL\n"; exit(1); }
// `/taxonomy` віддає плоскі рядки, а не обʼєкти зі `value`. Через
// `array_column` перевірка друкувала «домени: » порожнім і виглядала
// справною · знайдено 2026-08-27, коли зʼясувалось, що в переліку категорій
// коду бракує `market`, а API його має.
$domains = array_values($d["data"]["domains"] ?? []);
echo "  домени (" . count($domains) . "): " . implode(", ", $domains) . "\n";
$types = array_values($d["data"]["semantic_types"] ?? []);
echo "  типи (" . count($types) . "): " . implode(", ", $types) . "\n";
echo "  кодів помилок: " . count($d["data"]["error_codes"] ?? []) . "\n";
' "$TAX_FILE" "$SCRIPT_DIR/lib/autoload.php"
rm -f "$TAX_FILE"

echo ""
green "API працює. Ключ активний, ліміти доступні."
