#!/usr/bin/env bash
# Показати статистику активного патча: загальна кількість, стани, домени.
# Використовує GET /patch/summary та GET /rows?include_total=1.
#
# Використання:
#   ./patch-info.sh                    # активний патч
#   ./patch-info.sh <snapshot_id>      # конкретний знімок
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
source "$SCRIPT_DIR/cli/system/select-env.sh"

SNAPSHOT="${1:-active}"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

echo "================================================"
echo "  СТАТИСТИКА ПАТЧУ: $SNAPSHOT"
echo "================================================"
echo ""

# --- 1. Summary ---
echo "== 1. Загальна статистика =="
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/patch/summary?patch=$SNAPSHOT" > "$TMP_DIR/patch_summary.json"

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
// ДВІ колонки, а не одна.
//
// Раніше друкувалось лише `total` із позначкою «← є що перекладати», і число
// читалось як обсяг роботи. Заміряно 2026-08-27: у патчі 1 домен `item` мав
// `total` 285 561 при 513 рядках без перекладу, тобто помилка в 500 разів.
// Той самий клас, що й колонка «у ШІ-шар» у `./bdo patches`.
echo "\n  По категоріях (усього / без перекладу):\n";
$domains = $s["domains"];
usort($domains, static fn (array $a, array $b): int => ($b["untranslated"] ?? 0) <=> ($a["untranslated"] ?? 0));
foreach ($domains as $d2) {
    $un = (int) ($d2["untranslated"] ?? 0);
    $mark = $un > 0 ? "  ← є що перекладати" : "";
    printf("    %-14s %9s / %-9s%s\n", $d2["domain"], $d2["total"], $un, $mark);
}
echo "\n  «без перекладу» включає рядки, що вже чекають на людину в модерації.\n";
echo "  Скільки з них доступно ПРОГОНУ · розділ 2 нижче.\n";
echo "  Узяти одну категорію: у формі старту на сторінці ./bdo web\n";
' "$TMP_DIR/patch_summary.json" "$SCRIPT_DIR/lib/autoload.php"

# --- 2. Без машинного ---
echo ""
echo "== 2. Без машинного перекладу =="
# ДВА різні числа, і плутати їх дорого.
#
# `missing=machine` рахує всі рядки без ШІ-перекладу, зокрема ті, що вже пішли
# в модерацію й чекають на людину. Прогін бере ІНШУ вибірку · із
# `exclude_proposed=1`, бо запропоноване вдруге не перекладають.
#
# Заміряно 2026-08-27 одразу після пачки `title`: перше число 15, друге 0.
# Власник бачив «title 15 · є що перекладати», просив перекласти, а `mode start`
# чесно відповідав «усе перекладено». Обидві відповіді правдиві, і саме тому
# розбіжність треба показувати, а не ховати за одним числом.
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&missing=machine&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_no_machine"
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&missing=machine&exclude_proposed=1&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_available"
php -r '
require $argv[3];
$all = Bdo\Translate\Api\Response::fromFile($argv[1], "rows")->raw()["meta"]["total_matching"] ?? 0;
$free = Bdo\Translate\Api\Response::fromFile($argv[2], "rows")->raw()["meta"]["total_matching"] ?? 0;
printf("  доступно прогону:      %d\n", $free);
printf("  чекають на людину:     %d (уже в модерації)\n", max(0, $all - $free));
printf("  разом без ШІ-шару:     %d\n", $all);
' "$TMP_DIR/patch_no_machine" "$TMP_DIR/patch_available" "$SCRIPT_DIR/lib/autoload.php"

# --- 3. На покращення ШІ (legacy) ---
echo ""
echo "== 3. Доступно на покращення ШІ =="
# Режим `покращення-ші` не мав ЖОДНОЇ команди, яка показує його власний обсяг.
# 2026-08-27 диригент на питання «що є на покращення?» пішов читати
# `docs/plans/BACKLOG.md` · тобто відповів про плани проєкту замість рядків,
# бо іншого джерела просто не існувало. Число тут рахується тим самим фільтром,
# що й прогін (`RunSpec::filterFor("improve", ...)`), тому «показав» і
# «візьме в роботу» не можуть розійтись.
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&machine_provenance=legacy&exclude_proposed=1&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_legacy"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "rows")->raw();
printf("  рядків Bosia (legacy): %d\n", $d["meta"]["total_matching"] ?? 0);
echo "  Це переклад НАНОВО з англійського джерела · режим «покращення ШІ»\n";
' "$TMP_DIR/patch_legacy" "$SCRIPT_DIR/lib/autoload.php"

# --- 4. Без ручного ---
echo ""
echo "== 4. Без ручного перекладу =="
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&missing=manual&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_no_manual"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "rows")->raw();
echo "  рядків: {$d["meta"]["total_matching"]}\n";
' "$TMP_DIR/patch_no_manual" "$SCRIPT_DIR/lib/autoload.php"

# --- 5. Застарілі ---
echo ""
echo "== 5. Застарілі (джерело змінилось) =="
"$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/rows?patch=$SNAPSHOT&state=stale&limit=1&include_total=1&fields=core" > "$TMP_DIR/patch_stale"
php -r '
require $argv[2];
$d = Bdo\Translate\Api\Response::fromFile($argv[1], "rows")->raw();
echo "  рядків: {$d["meta"]["total_matching"]}\n";
' "$TMP_DIR/patch_stale" "$SCRIPT_DIR/lib/autoload.php"


echo ""
echo "================================================"
