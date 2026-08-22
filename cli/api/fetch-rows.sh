#!/usr/bin/env bash
# Завантажити пачку рядків для перекладу з API й зберегти у JSON-файл.
#
# Використання:
#   ./fetch-rows.sh [кількість] [параметри_додаткові]
#
# Приклади:
#   ./fetch-rows.sh 20                                         # 20 неперекладених
#   ./fetch-rows.sh 10 "domain=item&semantic_type=name"        # 10 назв предметів
#   ./fetch-rows.sh 15 "patch=active&diff=added"               # 15 нових з патча
#   ./fetch-rows.sh 10 "state=stale"                           # 10 застарілих
#
# Вихід: ./output/rows_YYYYMMDD_HHMMSS.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/cli/system/select-env.sh"

BATCH="${1:-20}"
EXTRA="${2:-}"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

mkdir -p "$SCRIPT_DIR/output"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT="$SCRIPT_DIR/output/rows_${TIMESTAMP}.json"

URL="$API/rows?limit=${BATCH}&include_total=1&fields=classification,tokens,constraints,glossary,reference,patch"
# Для переперекладу (exclude_proposed) потрібні поточні machine-переклади як
# контекст для моделі: щоб не розтягувати скорочення, не портити вже добре.
case "$EXTRA" in
    *exclude_proposed*) URL="${URL},layers" ;;
esac
[ -n "$EXTRA" ] && URL="${URL}&${EXTRA}"

# Заливка ШІ навмисно не позначає рядок опрацьованим (сторінка патча рахує
# рішення людей, а не покриття перекладом), тому вже перекладені рядки лишаються
# у вибірці. Без `missing` вибірка віддає ті самі перші рядки патча щоразу: на
# прогонах 2026-08-16 три пачки поспіль опрацювали ОДНІ Й ТІ САМІ 20 рядків,
# щоразу переписуючи попередній переклад іншим варіантом.
# Тому фільтр додається сам. Явний `missing=` або `exclude_proposed=` у EXTRA
# має пріоритет (другий означає перепереклад — там missing= не потрібен).
case "$EXTRA" in
    *missing=*|*state=stale*|*exclude_proposed=*) ;;
    *)
        URL="${URL}&missing=machine&exclude_proposed=1"
        echo "Додано missing=machine&exclude_proposed=1: інакше вибірка повертала б ті самі рядки." >&2
        ;;
esac

echo "Завантажую $BATCH рядків..."
curl -fsS -H "X-API-Key: $KEY" "$URL" > "$OUT"

php -r '
$d = json_decode(file_get_contents("'"$OUT"'"), true);
$rows = $d["data"]["rows"] ?? [];
$count = count($rows);
$total = $d["meta"]["total_matching"] ?? "?";
$hasMore = $d["meta"]["has_more"] ?? false;
$cursor = $d["meta"]["next_cursor"] ?? null;
echo "Отримано: $count рядків (загалом: $total)\n";
echo "has_more=" . ($hasMore ? "true" : "false") . "  next_cursor=" . ($cursor ?? "null") . "\n";
echo "Збережено: '"$OUT"'\n";
if ($count > 0) {
    echo "\n-- Перші 5 рядків (скорочено) --\n";
    foreach (array_slice($rows, 0, 5) as $i => $r) {
        $src = mb_substr($r["source_text"], 0, 60);
        $dom = $r["classification"]["domain"] ?? "?";
        $st = $r["classification"]["semantic_type"] ?? "?";
        $gl = $r["glossary"]["terms"] ?? [];
        $ua = "-";
        foreach ($gl as $t) { if (!empty($t["ukrainian"])) { $ua = $t["ukrainian"]; break; } }
        $n = $i + 1;
        echo "  $n. [$dom/$st] $src\n";
        echo "     UA: $ua\n";
    }
}
'
