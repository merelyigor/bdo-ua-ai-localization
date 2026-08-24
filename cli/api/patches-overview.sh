#!/usr/bin/env bash
# Де ще лишилась робота: скільки рядків без перекладу в кожному патчі.
#
#   ./patches-overview.sh                  усі патчі, обидва шари
#   ./patches-overview.sh 5                лише останні 5
#   ./patches-overview.sh 5 machine        лише ШІ-шар (швидше вдвічі)
#   ./patches-overview.sh all manual       усі патчі, лише ручний шар
#
# Навіщо. Пресети режимів націлені на `active`, і це щоденний випадок. Але
# виміряно 2026-08-24: в активному патчі 6 лишався ОДИН рядок без
# machine-перекладу, тоді як у патчі 1 їх 29927, а в патчі 3 · 442. Тобто
# «нема що перекладати» означало лише «нема в активному». Узяти потрібний:
# `./bdo mode start patch 15 3`.
#
# ЧОГО ТУТ НЕМАЄ І ЧОМУ. Ігрового номера патча й дати випуску API не віддає:
# `GET /patch/summary` повертає в `meta` рівно `snapshot_id`, переліку патчів
# немає взагалі (`/patches`, `/snapshots`, `/patch/list` · 404), і в `/guide`
# такого ендпоінта теж немає. Тому нумерація тут внутрішня, від активного вниз.
# Щоб зʼявились номер і дата, їх має віддавати сервер · це зміна в серверному
# проєкті, не тут.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

LIMIT_ARG="${1:-all}"
LAYER="${2:-both}"
case "$LAYER" in machine|manual|both) ;; *) echo "Другий аргумент: machine, manual або both." >&2; exit 2 ;; esac
case "$LIMIT_ARG" in all|0) LIMIT=0 ;; *[!0-9]*) echo "Перший аргумент: число патчів або all." >&2; exit 2 ;; *) LIMIT="$LIMIT_ARG" ;; esac

api_get() { curl -fsS -H "X-API-Key: $KEY" --max-time 30 "$API/$1" 2>/dev/null || echo '{}'; }

missing_count() {  # $1 = patch, $2 = machine|manual
    api_get "rows?patch=$1&missing=$2&limit=1&include_total=1" \
        | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo $d["meta"]["total_matching"]??"?";'
}

ACTIVE="$(api_get "patch/summary?patch=active" \
    | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo (int)($d["meta"]["snapshot_id"]??0);')"
test "$ACTIVE" -gt 0 || { echo "Не вдалося визначити активний патч (перевір ключ і мережу)." >&2; exit 1; }

FIRST=1
if [ "$LIMIT" -gt 0 ]; then
    FIRST=$((ACTIVE - LIMIT + 1))
    test "$FIRST" -ge 1 || FIRST=1
fi

case "$LAYER" in
    machine) printf '%-6s %-9s %-13s %-34s %s\n' "патч" "рядків" "у ШІ-шар" "стани перекладу" "" ;;
    manual)  printf '%-6s %-9s %-13s %-34s %s\n' "патч" "рядків" "у ручний" "стани перекладу" "" ;;
    both)    printf '%-6s %-9s %-13s %-13s %-34s %s\n' "патч" "рядків" "у ШІ-шар" "у ручний" "стани перекладу" "" ;;
esac
printf '%s\n' "-------------------------------------------------------------------------------"

total_machine=0
total_manual=0
for ((n = ACTIVE; n >= FIRST; n--)); do
    summary="$(api_get "patch/summary?patch=$n")"
    read -r rows states <<< "$(printf '%s' "$summary" | php -r '
        $d = json_decode((string) file_get_contents("php://stdin"), true);
        $s = $d["data"]["summary"] ?? [];
        $states = [];
        foreach (($s["states"] ?? []) as $name => $count) $states[] = $name . " " . $count;
        printf("%s %s", $s["total"] ?? "?", $states === [] ? "-" : implode("/", $states));
    ')"
    mark=""
    test "$n" = "$ACTIVE" && mark="активний"

    machine="-"; manual="-"
    if [ "$LAYER" != manual ]; then
        machine="$(missing_count "$n" machine)"
        case "$machine" in ''|*[!0-9]*) ;; *) total_machine=$((total_machine + machine)) ;; esac
    fi
    if [ "$LAYER" != machine ]; then
        manual="$(missing_count "$n" manual)"
        case "$manual" in ''|*[!0-9]*) ;; *) total_manual=$((total_manual + manual)) ;; esac
    fi

    case "$LAYER" in
        machine) printf '%-6s %-9s %-13s %-34s %s\n' "$n" "$rows" "$machine" "$states" "$mark" ;;
        manual)  printf '%-6s %-9s %-13s %-34s %s\n' "$n" "$rows" "$manual" "$states" "$mark" ;;
        both)    printf '%-6s %-9s %-13s %-13s %-34s %s\n' "$n" "$rows" "$machine" "$manual" "$states" "$mark" ;;
    esac
done
printf '%s\n' "-------------------------------------------------------------------------------"
test "$LAYER" != manual && printf 'Разом у ШІ-шар: %d рядків\n' "$total_machine"
test "$LAYER" != machine && printf 'Разом у ручний: %d рядків\n' "$total_manual"
echo "Узяти патч у роботу: ./bdo mode start patch 15 <номер>"
echo "Нумерація внутрішня (snapshot_id): ігрового номера й дати патча API не віддає."
