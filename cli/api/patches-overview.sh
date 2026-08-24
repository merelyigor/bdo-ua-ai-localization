#!/usr/bin/env bash
# Де ще лишилась робота: скільки рядків без перекладу в кожному патчі.
#
#   ./patches-overview.sh                     усі патчі, обидва шари
#   ./patches-overview.sh 5                   лише останні 5
#   ./patches-overview.sh 5 machine           лише ШІ-шар (удвічі менше запитів)
#   ./patches-overview.sh all manual --full   + всього рядків і стани перекладу
#
# Навіщо. Пресети режимів націлені на `active`, і це щоденний випадок. Але
# виміряно 2026-08-24: в активному патчі лишався ОДИН рядок без
# machine-перекладу, тоді як у патчі 1 їх 29927, а в патчі 3 · 442. Тобто
# «нема що перекладати» означало лише «нема в активному». Узяти потрібний:
# `./bdo mode start patch 15 3`.
#
# ЧОМУ `--full` НЕ ЗА ЗАМОВЧУВАННЯМ. `GET /patch/summary` на великому патчі
# рахує довго: виміряно 87 секунд на патчі 5 (12937 рядків) проти секунд на
# `GET /rows?...&include_total=1`. За замовчуванням тому беремо лише те, про що
# питають · кількість рядків, доступних для перекладу.
#
# ЧОГО ТУТ НЕМАЄ І ЧОМУ. Ігрового номера патча й дати випуску API не віддає:
# `GET /patch/summary` повертає в `meta` рівно `snapshot_id`, переліку патчів
# немає взагалі (`/patches`, `/snapshots`, `/patch/list` · 404), і в `/guide`
# такого ендпоінта теж немає. Тому нумерація тут внутрішня, від активного вниз.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

LIMIT_ARG="all"
LAYER="both"
FULL=0
for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        machine|manual|both) LAYER="$arg" ;;
        all) LIMIT_ARG="all" ;;
        ''|*[!0-9]*) echo "Аргументи: [кількість|all] [machine|manual|both] [--full]" >&2; exit 2 ;;
        *) LIMIT_ARG="$arg" ;;
    esac
done
case "$LIMIT_ARG" in all|0) LIMIT=0 ;; *) LIMIT="$LIMIT_ARG" ;; esac

api_get() { curl -fsS -H "X-API-Key: $KEY" --max-time "${2:-45}" "$API/$1" 2>/dev/null || echo '{}'; }

missing_count() {  # $1 = patch, $2 = machine|manual
    api_get "rows?patch=$1&missing=$2&limit=1&include_total=1" \
        | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo $d["meta"]["total_matching"]??"?";'
}

ACTIVE="$(api_get "patch/summary?patch=active" 120 \
    | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo (int)($d["meta"]["snapshot_id"]??0);')"
test "$ACTIVE" -gt 0 || { echo "Не вдалося визначити активний патч (перевір ключ і мережу)." >&2; exit 1; }

FIRST=1
if [ "$LIMIT" -gt 0 ]; then
    FIRST=$((ACTIVE - LIMIT + 1))
    test "$FIRST" -ge 1 || FIRST=1
fi

# Дані збираємо тут, а друкує PHP: `printf` у bash рахує БАЙТИ, тому кириличні
# заголовки ламали вирівнювання колонок.
ROWS_TSV=""
for ((n = ACTIVE; n >= FIRST; n--)); do
    machine="-"; manual="-"; total="-"; states="-"
    if [ "$LAYER" != manual ]; then machine="$(missing_count "$n" machine)"; fi
    if [ "$LAYER" != machine ]; then manual="$(missing_count "$n" manual)"; fi
    if [ "$FULL" = 1 ]; then
        read -r total states <<< "$(api_get "patch/summary?patch=$n" 180 | php -r '
            $d = json_decode((string) file_get_contents("php://stdin"), true);
            $s = $d["data"]["summary"] ?? [];
            $states = [];
            foreach (($s["states"] ?? []) as $name => $count) $states[] = $name . " " . $count;
            printf("%s %s", $s["total"] ?? "?", $states === [] ? "-" : implode(", ", $states));
        ')"
    fi
    mark=""
    test "$n" = "$ACTIVE" && mark="активний"
    ROWS_TSV="${ROWS_TSV}${n}\t${machine}\t${manual}\t${total}\t${states}\t${mark}\n"
done

printf '%b' "$ROWS_TSV" | php -r '
$layer = $argv[1];
$full = $argv[2] === "1";
$rows = [];
while (($line = fgets(STDIN)) !== false) {
    $line = rtrim($line, "\n");
    if ($line === "") continue;
    $rows[] = explode("\t", $line);
}

$head = ["патч"];
if ($layer !== "manual") $head[] = "у ШІ-шар";
if ($layer !== "machine") $head[] = "у ручний";
if ($full) { $head[] = "рядків"; $head[] = "стани перекладу"; }
$head[] = "";

$table = [$head];
$sumMachine = 0; $sumManual = 0;
foreach ($rows as $r) {
    [$n, $machine, $manual, $total, $states, $mark] = $r;
    $line = [$n];
    if ($layer !== "manual") { $line[] = $machine; if (ctype_digit($machine)) $sumMachine += (int) $machine; }
    if ($layer !== "machine") { $line[] = $manual; if (ctype_digit($manual)) $sumManual += (int) $manual; }
    if ($full) { $line[] = $total; $line[] = $states; }
    $line[] = $mark;
    $table[] = $line;
}

// Ширина рахується по СИМВОЛАХ: кирилиця в заголовку інакше зсуває колонки.
$width = [];
foreach ($table as $line) {
    foreach ($line as $i => $cell) $width[$i] = max($width[$i] ?? 0, mb_strlen((string) $cell));
}
$render = static function (array $line) use ($width): string {
    $out = [];
    foreach ($line as $i => $cell) {
        $cell = (string) $cell;
        $out[] = $cell.str_repeat(" ", $width[$i] - mb_strlen($cell));
    }

    return rtrim(implode("  ", $out));
};
$total = array_sum($width) + 2 * (count($width) - 1);

echo $render($table[0]), "\n", str_repeat("-", max(20, $total)), "\n";
foreach (array_slice($table, 1) as $line) echo $render($line), "\n";
echo str_repeat("-", max(20, $total)), "\n";
if ($layer !== "manual") printf("Разом у ШІ-шар: %d рядків\n", $sumMachine);
if ($layer !== "machine") printf("Разом у ручний: %d рядків\n", $sumManual);
echo "Узяти патч у роботу: ./bdo mode start patch 15 <номер>\n";
if (! $full) echo "Всього рядків і стани перекладу: ./bdo patches ... --full (повільно на великих патчах)\n";
echo "Нумерація внутрішня (snapshot_id): ігрового номера й дати патча API не віддає.\n";
' "$LAYER" "$FULL"
