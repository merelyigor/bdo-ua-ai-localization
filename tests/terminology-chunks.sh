#!/usr/bin/env bash
# Термінолог працює ЧАСТИНАМИ, і збій коштує частину, а не весь виклик.
#
# Заміряно 2026-09-06 на живих викликах: 98-136 термінів одним запитом, 208-621
# секунда. Пачку це не ламало (роль не є ворітьми), але ціна невдачі дорівнювала
# всьому виклику · обрив на девʼяностому терміні коштував десять хвилин роботи
# разом із девʼяноста готовими рішеннями.
#
# Перевіряється ПОВЕДІНКА рушія на справжніх файлах пачки, а не написання коду:
# скільки частин, що потрапляє в кожну, як складається підсумок і що робиться з
# частиною, яка вичерпала повтори.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"

# --- 1. Сам поділ · без рушія ------------------------------------------------
php -r '
require $argv[1];
use Bdo\Translate\Payload\Chunks;
$dir = $argv[2];
$items = [];
for ($i = 1; $i <= 98; $i++) { $items[] = ["canonical_source" => "term$i"]; }
file_put_contents($dir."/full.json", json_encode($items));

if (Chunks::count($dir."/full.json", 40) !== 3) { fwrite(STDERR, "98 термінів по 40 · мусить бути 3 частини\n"); exit(1); }
if (Chunks::write($dir."/full.json", 0, $dir."/c.json", 40) !== 40) { fwrite(STDERR, "перша частина не 40\n"); exit(1); }
if (Chunks::write($dir."/full.json", 2, $dir."/c.json", 40) !== 18) { fwrite(STDERR, "остання частина не 18\n"); exit(1); }
if (Chunks::write($dir."/full.json", 3, $dir."/c.json", 40) !== 0) { fwrite(STDERR, "неіснуюча частина дала записи\n"); exit(1); }

// Зіпсована відповідь НЕ обнуляє накопичене · у цьому й сенс розбиття.
file_put_contents($dir."/acc.json", json_encode([["canonical_source" => "готове"]]));
file_put_contents($dir."/bad.json", "не JSON");
if (Chunks::append($dir."/bad.json", $dir."/acc.json") !== 1) {
    fwrite(STDERR, "зіпсована частина зʼїла вже накопичене\n"); exit(1);
}
' "$ROOT/lib/autoload.php" "$TMP" || fail 'поділ на частини працює не так, як обіцяно'

# --- 2. Рушій справді кличе роль частинами -----------------------------------
# Готуємо пачку рівно в тому стані, у якому починається робота термінолога.
php -r '
$rows = [];
for ($i = 1; $i <= 90; $i++) {
    $rows[] = [
        "identity_hash" => hash("sha256", "row$i"),
        "source_hash" => hash("sha256", "src$i"),
        "source_text" => "Item $i with Term$i inside",
        "classification" => ["domain" => "item", "semantic_type" => "name"],
        "glossary" => ["terms" => [[
            "canonical_source" => "Term$i",
            "ukrainian" => null,
            "severity" => "mandatory",
        ]]],
    ];
}
file_put_contents($argv[1], json_encode(["data" => ["rows" => $rows]], JSON_THROW_ON_ERROR));
' "$STATE/rows.json"

cat > "$TMP/.env" <<ENV
BDO_ENV=DEV
BDO_API_BASE_DEV=http://127.0.0.1:1
BDO_API_KEY_DEV=test
ENV

BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-new.sh" "$STATE/rows.json" >/dev/null
B="$(BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-dir.sh")"
php -r '$m=json_decode(file_get_contents($argv[1]),true);$m["state"]="awaiting_terminology";$m["mode"]="patch";$m["channel"]="machine";
    file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));' "$B/manifest.json"

# Останній конверт рушія. Ненульовий код тут очікуваний і НЕ є збоєм тесту:
# після термінолога рушій іде в підготовку воркера, а вона офлайн законно каже
# `context_unavailable`. Нас цікавить саме конверт, тому код гасимо явно.
drive() { TRANSLATE_ENV_FILE="$TMP/.env" BDO_AUTO_CLEAN=0 BDO_TERM_RESOLVE_TIMEOUT=1 \
    BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null | tail -1 || true; }

# Стан `selected` · саме там рушій сам будує payload і бере ПЕРШУ частину.
# Ключове: перевіряємо те, що зробив РУШІЙ, а не те, що підклав тест.
php -r '$m=json_decode(file_get_contents($argv[1]),true);$m["state"]="selected";
    file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));' "$B/manifest.json"
out="$(drive)"
grep -q '"role":"translation-terminology"' <<<"$out" \
    || fail "рушій не пішов у термінолога зі стану selected: $out"
test -s "$B/terminology-payload.full.json" \
    || fail 'рушій не зберіг ПОВНОГО payload · частини нема з чого брати'
total="$(php -r 'require $argv[2]; echo Bdo\Translate\Payload\Items::count($argv[1]);' "$B/terminology-payload.full.json" "$ROOT/lib/autoload.php")"
test "$total" = 90 || fail "у повному payload ${total} термінів замість 90"

# Відповідь моделі на ту частину, яка зараз лежить у payload.
answer_current() {
    php -r '
    require $argv[3];
    $items = [];
    foreach (Bdo\Translate\Payload\Items::fromFile($argv[1]) as $t) {
        $items[] = [
            "canonical_source" => $t["canonical_source"],
            "status" => "ready",
            "term_id" => "1",
            "entity_type" => "item",
            "ukrainian_proposal" => "переклад ".$t["canonical_source"],
            "next_action" => "",
        ];
    }
    file_put_contents($argv[2], json_encode(["items" => $items], JSON_UNESCAPED_UNICODE));
    ' "$B/terminology-payload.json" "$B/term-proposals.json" "$ROOT/lib/autoload.php"
}

# Частина 1 із 3 · роль мусить отримати рівно 40 термінів, а не всі 90.
size="$(php -r 'require $argv[2]; echo Bdo\Translate\Payload\Items::count($argv[1]);' "$B/terminology-payload.json" "$ROOT/lib/autoload.php")"
test "$size" = 40 \
    || fail "роль отримала ${size} термінів замість 40 · виклик знову йде одним шматком на всю пачку"

seen_continue=0
for step in 1 2 3; do
    answer_current
    out="$(drive)"
    if grep -q '"reason":"terminology_chunk_' <<<"$out"; then
        seen_continue=$((seen_continue + 1))
        size="$(php -r 'require $argv[2]; echo Bdo\Translate\Payload\Items::count($argv[1]);' "$B/terminology-payload.json" "$ROOT/lib/autoload.php")"
        test "$size" -le 40 || fail "частина ${step} містить ${size} термінів · більше за стелю"
    fi
done
test "$seen_continue" -ge 2 || fail "рушій не пройшов частинами: конвертів про наступну частину ${seen_continue}"

# --- 3. Підсумок повний і з identity -----------------------------------------
count="$(php -r 'require $argv[2]; echo Bdo\Translate\Payload\Items::count($argv[1]);' "$B/term-proposals.json" "$ROOT/lib/autoload.php")"
test "$count" = 90 || fail "у підсумку ${count} пропозицій замість 90 · частини не склались"
php -r '
require $argv[1];
$d = json_decode((string) file_get_contents($argv[2]), true) ?: [];
$with = 0;
foreach ($d as $p) { if (isset($p["source_identity"]["identity_hash"])) { $with++; } }
if ($with !== count($d)) {
    fwrite(STDERR, "identity відновлено лише для {$with} із ".count($d)."\n"); exit(1);
}' "$ROOT/lib/autoload.php" "$B/term-proposals.json" || fail 'identity не відновлено після складання частин'

# --- 4. Збій частини коштує ЧАСТИНУ, а не всю роботу -------------------------
# Готуємо ту саму пачку наново й НЕ відповідаємо на першу частину, вичерпавши
# бюджет повторів. Рушій мусить пропустити саме її й піти далі.
rm -rf "$STATE/batches" "$STATE/current-batch"
BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-new.sh" "$STATE/rows.json" >/dev/null
B="$(BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-dir.sh")"
php -r '$m=json_decode(file_get_contents($argv[1]),true);$m["state"]="selected";$m["mode"]="patch";$m["channel"]="machine";
    file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));' "$B/manifest.json"
drive >/dev/null

first_chunk="$(cat "$B/terminology-chunk")"
test "$first_chunk" = 0 || fail "курсор частин почався не з нуля: ${first_chunk}"

# Вичерпуємо бюджет повторів цієї частини: вікно й загальний бюджет по секунді,
# перша спроба заводить лічильник, друга через секунду вже поза бюджетом.
starve() {
    TRANSLATE_ENV_FILE="$TMP/.env" BDO_AUTO_CLEAN=0 \
        BDO_CHILD_RETRY_WINDOW_SECONDS=1 BDO_CHILD_RETRY_TOTAL_SECONDS=1 \
        BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null | tail -1 || true
}
starve >/dev/null
sleep 2
out="$(starve)"
after="$(cat "$B/terminology-chunk")"
test "$after" -gt 0 \
    || fail "вичерпана частина не пропущена (курсор ${after}) · робота стане на ній назавжди: $out"
grep -qE '"reason":"terminology_chunk_|"role":"translation-terminology"|"kind":"child"' <<<"$out" \
    || fail "після пропуску частини рушій не пішов далі: $out"

# І бюджет мусить бути ОКРЕМИЙ на кожну частину · інакше одна невдала частина
# зʼїдає бюджет усіх наступних, і сенс розбиття зникає.
php -r '
$a = json_decode((string) file_get_contents($argv[1]), true) ?: [];
$keys = array_keys($a);
$perChunk = array_filter($keys, static fn ($k) => str_starts_with($k, "awaiting_terminology:"));
if ($perChunk === []) {
    fwrite(STDERR, "бюджет повторів спільний на всі частини: ".implode(", ", $keys)."\n"); exit(1);
}' "$B/drive-retries.json" || fail 'повтори рахуються не на частину'

echo 'terminology chunks: OK · роль іде частинами по 40, підсумок повний, identity на місці, збій коштує частину.'
