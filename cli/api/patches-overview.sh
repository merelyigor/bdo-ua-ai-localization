#!/usr/bin/env bash
# Де ще лишилась робота: патчі, їхні номери, дати й рядки без перекладу.
#
#   ./patches-overview.sh                     усі патчі, обидва шари
#   ./patches-overview.sh 5                   лише останні 5
#   ./patches-overview.sh 5 machine           лише ШІ-шар (удвічі менше запитів)
#   ./patches-overview.sh all both --full     + зміни патча і стани перекладу
#
# Навіщо. Пресети режимів націлені на `active`, і це щоденний випадок. Але
# виміряно 2026-08-24: в активному патчі лишався ОДИН рядок без
# machine-перекладу, тоді як у патчі 1 їх 29927, а в патчі 3 · 442. Тобто
# «нема що перекладати» означало лише «нема в активному». Узяти потрібний:
# `./bdo mode start patch 15 3`.
#
# ДЖЕРЕЛО. `GET /patches` (додано на сервері 2026-08-24) віддає одним запитом
# номер патча в грі, дати, зміни й розклад станів. Раніше цього не було зовсім,
# і набір міг показати лише внутрішній `snapshot_id`, перебираючи знімки вниз.
# Той старий шлях лишається як fallback: на сервері без нового ендпоінта
# команда не має падати, вона просто показує менше.
#
# Кількість рядків, доступних для перекладу В КОНКРЕТНИЙ ШАР, з `/patches` не
# виводиться: `states` рахує рядки за НАЙВИЩИМ наявним шаром, тому рядок із
# manual і без machine там лежить у `manual`. Це окремий швидкий запит
# `GET /rows?...&include_total=1` на патч.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

LIMIT=0
LAYER="both"
FULL=0
for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        machine|manual|both) LAYER="$arg" ;;
        all|0) LIMIT=0 ;;
        ''|*[!0-9]*) echo "Аргументи: [кількість|all] [machine|manual|both] [--full]" >&2; exit 2 ;;
        *) LIMIT="$arg" ;;
    esac
done

api_get() { curl -fsS -H "X-API-Key: $KEY" --max-time "${2:-60}" "$API/$1" 2>/dev/null || echo '{}'; }

missing_count() {  # $1 = patch, $2 = machine|manual
    api_get "rows?patch=$1&missing=$2&limit=1&include_total=1" 45 \
        | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo $d["meta"]["total_matching"]??"?";'
}

PATCHES_JSON="$(api_get patches 90)"
LIST="$(printf '%s' "$PATCHES_JSON" | php -r '
$d = json_decode((string) file_get_contents("php://stdin"), true);
foreach ($d["data"]["patches"] ?? [] as $p) {
    printf("%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
        $p["snapshot_id"] ?? "?",
        $p["patch_number"] ?? "-",
        substr((string) ($p["published_at"] ?? ""), 0, 10) ?: "-",
        $p["rows"]["total"] ?? "-",
        implode(", ", array_map(
            static fn ($k, $v): string => "$k $v",
            array_keys($p["rows"]["states"] ?? []),
            array_values($p["rows"]["states"] ?? []),
        )) ?: "-",
        implode("/", [$p["changes"]["added"] ?? "-", $p["changes"]["changed"] ?? "-", $p["changes"]["removed"] ?? "-"]),
        ($p["is_active"] ?? false) ? "активний" : (string) ($p["status"] ?? ""));
}')"

# Fallback для сервера без `GET /patches`: як раніше, від активного вниз.
if [ -z "$LIST" ]; then
    echo "GET /patches недоступний · показую лише внутрішні номери знімків." >&2
    ACTIVE="$(api_get "patch/summary?patch=active" 120 \
        | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo (int)($d["meta"]["snapshot_id"]??0);')"
    test "$ACTIVE" -gt 0 || { echo "Не вдалося визначити активний патч (перевір ключ і мережу)." >&2; exit 1; }
    for ((n = ACTIVE; n >= 1; n--)); do
        LIST="${LIST}${n}\t-\t-\t-\t-\t-\t$([ "$n" = "$ACTIVE" ] && echo активний)\n"
    done
    LIST="$(printf '%b' "$LIST")"
fi

test "$LIMIT" -gt 0 && LIST="$(printf '%s\n' "$LIST" | head -n "$LIMIT")"

ROWS_TSV=""
while IFS=$'\t' read -r snapshot number published total states changes mark; do
    test -n "$snapshot" || continue
    machine="-"; manual="-"
    test "$LAYER" != manual && machine="$(missing_count "$snapshot" machine)"
    test "$LAYER" != machine && manual="$(missing_count "$snapshot" manual)"
    ROWS_TSV="${ROWS_TSV}${snapshot}\t${number}\t${published}\t${total}\t${machine}\t${manual}\t${states}\t${changes}\t${mark}\n"
done <<< "$LIST"

# Друкує PHP: `printf` у bash рахує БАЙТИ, і кириличні заголовки зсували колонки.
printf '%b' "$ROWS_TSV" | php -r '
$layer = $argv[1];
$full = $argv[2] === "1";

$head = ["патч", "№ у грі", "опубліковано", "рядків"];
if ($layer !== "manual") $head[] = "у ШІ-шар";
if ($layer !== "machine") $head[] = "у ручний";
if ($full) { $head[] = "стани"; $head[] = "дод/змін/вид"; }
$head[] = "";

$table = [$head];
$sumMachine = 0; $sumManual = 0;
while (($line = fgets(STDIN)) !== false) {
    $line = rtrim($line, "\n");
    if ($line === "") continue;
    [$snapshot, $number, $published, $total, $machine, $manual, $states, $changes, $mark] = array_pad(explode("\t", $line), 9, "");
    $row = [$snapshot, $number, $published, $total];
    if ($layer !== "manual") { $row[] = $machine; if (ctype_digit($machine)) $sumMachine += (int) $machine; }
    if ($layer !== "machine") { $row[] = $manual; if (ctype_digit($manual)) $sumManual += (int) $manual; }
    if ($full) { $row[] = $states; $row[] = $changes; }
    $row[] = $mark;
    $table[] = $row;
}

$width = [];
foreach ($table as $row) {
    foreach ($row as $i => $cell) $width[$i] = max($width[$i] ?? 0, mb_strlen((string) $cell));
}
$render = static function (array $row) use ($width): string {
    $out = [];
    foreach ($row as $i => $cell) {
        $cell = (string) $cell;
        $out[] = $cell.str_repeat(" ", $width[$i] - mb_strlen($cell));
    }

    return rtrim(implode("  ", $out));
};
$line = str_repeat("-", max(20, array_sum($width) + 2 * (count($width) - 1)));

echo $render($table[0]), "\n", $line, "\n";
foreach (array_slice($table, 1) as $row) echo $render($row), "\n";
echo $line, "\n";
if ($layer !== "manual") printf("Разом у ШІ-шар: %d рядків\n", $sumMachine);
if ($layer !== "machine") printf("Разом у ручний: %d рядків\n", $sumManual);
echo "Узяти патч у роботу: ./bdo mode start patch 15 <патч>\n";
if (! $full) echo "Стани перекладу і зміни патча: ./bdo patches ... --full\n";
' "$LAYER" "$FULL"
