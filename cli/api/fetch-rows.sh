#!/usr/bin/env bash
# Завантажити пачку рядків для перекладу з API й зберегти у JSON-файл.
#
# Використання:
#   ./fetch-rows.sh [кількість] [параметри_додаткові]
#
# Приклади:
#   ./fetch-rows.sh 20                                         # 20 неперекладених
#   ./fetch-rows.sh 20 "domain=item&semantic_type=name"        # 20 назв предметів
#   ./fetch-rows.sh 20 "patch=active&diff=added"               # 20 нових з патча
#   ./fetch-rows.sh 20 "state=stale"                           # 20 застарілих
#
# Вихід: ./output/rows_YYYYMMDD_HHMMSS.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/cli/system/select-env.sh"

BATCH="${1:-50}"
EXTRA="${2:-}"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

if ! [[ "$BATCH" =~ ^[0-9]+$ ]] || (( BATCH < 20 || BATCH > 100 )); then
    echo "Розмір логічної пачки має бути від 20 до 100." >&2
    exit 2
fi

mkdir -p "$SCRIPT_DIR/output"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT="$SCRIPT_DIR/output/rows_${TIMESTAMP}.json"

URL="$API/rows?limit=50&include_total=1&fields=classification,tokens,constraints,glossary,reference,patch"
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
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bdo-fetch.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
# Рядки з вичерпаними спробами у вибірку не беруться (D58: один identity пройшов
# конвеєр 21 раз, бо сервер віддавав його в кожну пачку). Виключене
# записується в `state/run-excluded.json` під запитом цієї цілі: `run drive`
# віднімає його від «лишилось рядків», інакше прогін ніколи не дійде до
# `goal_complete`. Інший запит обнуляє список · це вже інша ціль.
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
EXCLUDED_FILE="$STATE_DIR/run-excluded.json"
php -r '
$file=$argv[1]; $query=$argv[2];
$x=is_file($file)?(json_decode((string)file_get_contents($file),true)?:[]):[];
if(($x["query"]??null)!==$query){ file_put_contents($file,json_encode(["query"=>$query,"identities"=>[]],JSON_UNESCAPED_SLASHES)); }
' "$EXCLUDED_FILE" "$EXTRA"
# Сторінок більше за потрібне: виключені рядки займають місця на початку
# вибірки, і без добору пачка з 50 могла б стати пачкою з нуля.
max_pages="${BDO_FETCH_MAX_PAGES:-10}"
cursor=""
remaining="$BATCH"
page=0
while (( remaining > 0 && page < max_pages )); do
    page_limit=$(( remaining > 50 ? 50 : remaining ))
    page_url="${URL/limit=50/limit=$page_limit}"
    [ -n "$cursor" ] && page_url="${page_url}&cursor=${cursor}"
    page_file="$TMP_DIR/page_${page}.json"
    "$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$page_url" > "$page_file"
    php -r '
        require $argv[3];
        use Bdo\Translate\Pipeline\RowAttempts;
        $target = $argv[1];
        $page = json_decode((string) file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
        $aggregate = is_file($target) ? json_decode((string) file_get_contents($target), true, 512, JSON_THROW_ON_ERROR) : ["data" => ["rows" => []], "meta" => []];
        $filtered = (new RowAttempts($argv[4]))->filterRows($page["data"]["rows"] ?? [], RowAttempts::maxAttempts());
        $aggregate["data"]["rows"] = array_merge($aggregate["data"]["rows"] ?? [], $filtered["kept"]);
        if (isset($page["meta"])) $aggregate["meta"] = $page["meta"];
        file_put_contents($target, json_encode($aggregate, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR));
        if ($filtered["dropped"] !== []) {
            $x = json_decode((string) file_get_contents($argv[5]), true) ?: ["identities" => []];
            $x["identities"] = array_values(array_unique(array_merge($x["identities"] ?? [], $filtered["dropped"])));
            file_put_contents($argv[5], json_encode($x, JSON_UNESCAPED_SLASHES));
            fwrite(STDERR, sprintf("Пропущено %d рядків із вичерпаними спробами (BDO_ROW_MAX_ATTEMPTS); вони чекають людину: ./bdo quarantine\n", count($filtered["dropped"])));
        }
        // `count` · лише ЗАЛИШЕНІ рядки: інакше виключені займали б місце в пачці.
        echo json_encode(["count" => count($filtered["kept"]), "page_rows" => count($page["data"]["rows"] ?? []), "has_more" => (bool) ($page["meta"]["has_more"] ?? false), "next_cursor" => $page["meta"]["next_cursor"] ?? null], JSON_UNESCAPED_UNICODE), "\n";
    ' "$OUT" "$page_file" "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$EXCLUDED_FILE" > "$TMP_DIR/page_${page}.meta"
    got="$(php -r '$x=json_decode((string)file_get_contents($argv[1]),true); echo (int)($x["count"]??0);' "$TMP_DIR/page_${page}.meta")"
    page_rows="$(php -r '$x=json_decode((string)file_get_contents($argv[1]),true); echo (int)($x["page_rows"]??0);' "$TMP_DIR/page_${page}.meta")"
    has_more="$(php -r '$x=json_decode((string)file_get_contents($argv[1]),true); echo !empty($x["has_more"]) ? "1" : "0";' "$TMP_DIR/page_${page}.meta")"
    cursor="$(php -r '$x=json_decode((string)file_get_contents($argv[1]),true); echo $x["next_cursor"] ?? "";' "$TMP_DIR/page_${page}.meta")"
    remaining=$(( remaining - got ))
    # Порожня СТОРІНКА зупиняє добір; сторінка, з якої все виключено, · ні.
    (( page_rows == 0 || has_more == 0 || remaining <= 0 )) && break
    [[ -z "$cursor" ]] && break
    page=$(( page + 1 ))
done

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
