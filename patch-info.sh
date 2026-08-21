#!/usr/bin/env bash
# Показати статистику активного патча: загальна кількість, стани, домени.
# Використовує GET /patch/summary та GET /rows?include_total=1.
#
# Використання:
#   ./patch-info.sh                    # активний патч
#   ./patch-info.sh <snapshot_id>      # конкретний знімок
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
source "$SCRIPT_DIR/select-env.sh"

SNAPSHOT="${1:-active}"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

echo "================================================"
echo "  СТАТИСТИКА ПАТЧУ: $SNAPSHOT"
echo "================================================"
echo ""

# --- 1. Summary ---
echo "== 1. Загальна статистика =="
curl -fsS -H "X-API-Key: $KEY" "$API/patch/summary?patch=$SNAPSHOT" > "$TMP_DIR/patch_summary.json"

php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "patch/summary")->raw();
$s = $d["data"]["summary"];
$sid = $d["meta"]["snapshot_id"] ?? "?";
echo "  snapshot_id: $sid\n";
echo "  всього: {$s["total"]}\n";
echo "  перекладних: {$s["translatable"]}\n";
echo "  без перекладу: {$s["untranslated"]}\n";
echo "\n  Стани:\n";
foreach ($s["states"] as $state => $count) {
    echo "    $state: $count\n";
}
echo "\n  По доменах:\n";
foreach ($s["domains"] as $d2) {
    $un = $d2["untranslated"];
    $mark = $un > 0 ? " ← є що перекладати" : "";
    echo "    {$d2["domain"]}: {$d2["total"]}$mark\n";
}
' "$TMP_DIR/patch_summary.json" "$SCRIPT_DIR/lib/autoload.php"

# --- 2. Без машинного ---
echo ""
echo "== 2. Без машинного перекладу =="
curl -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&missing=machine&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_no_machine"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "rows")->raw();
echo "  рядків: {$d["meta"]["total_matching"]}\n";
' "$TMP_DIR/patch_no_machine" "$SCRIPT_DIR/lib/autoload.php"

# --- 3. Без ручного ---
echo ""
echo "== 3. Без ручного перекладу =="
curl -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&missing=manual&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_no_manual"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "rows")->raw();
echo "  рядків: {$d["meta"]["total_matching"]}\n";
' "$TMP_DIR/patch_no_manual" "$SCRIPT_DIR/lib/autoload.php"

# --- 4. Застарілі ---
echo ""
echo "== 4. Застарілі (джерело змінилось) =="
curl -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&state=stale&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_stale"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "rows")->raw();
echo "  рядків: {$d["meta"]["total_matching"]}\n";
' "$TMP_DIR/patch_stale" "$SCRIPT_DIR/lib/autoload.php"


echo ""
echo "================================================"
