#!/usr/bin/env bash
# Де ще лишилась робота: скільки рядків без перекладу в кожному патчі.
#
#   ./patches-overview.sh          усі патчі від активного до першого
#   ./patches-overview.sh 5        лише останні 5
#
# Навіщо. Пресети режимів націлені на `active`, і це щоденний випадок. Але
# виміряно 2026-08-24: в активному патчі 6 лишався ОДИН рядок без
# machine-перекладу, тоді як у патчі 1 їх 29927, а в патчі 3 · 442. Тобто
# «нема що перекладати» означало лише «нема в активному», і робота була
# невидимою. Тепер вона видно однією командою, а взяти її можна третім
# аргументом: `./bdo mode start patch 15 3`.
#
# Перелік патчів API не віддає, тому snapshot_id активного береться з
# `GET /patch/summary?patch=active`, а далі йдемо вниз до 1. Це read-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"
LIMIT="${1:-0}"

total_matching() {  # $1 = patch, $2 = missing
    curl -fsS -H "X-API-Key: $KEY" --max-time 30 \
        "$API/rows?patch=$1&missing=$2&limit=1&include_total=1" 2>/dev/null \
        | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo $d["meta"]["total_matching"]??"?";' \
        || echo "?"
}

ACTIVE="$(curl -fsS -H "X-API-Key: $KEY" --max-time 30 "$API/patch/summary?patch=active" \
    | php -r '$d=json_decode((string)file_get_contents("php://stdin"),true);echo (int)($d["meta"]["snapshot_id"]??0);')"
test "$ACTIVE" -gt 0 || { echo "Не вдалося визначити активний патч." >&2; exit 1; }

# Без аргументу показуємо ВСІ патчі, від активного до першого. Раніше тут
# лишалось FIRST=$ACTIVE, і команда мовчки друкувала один рядок · виглядало як
# «інших патчів немає», хоча в патчі 1 лежало 29927 неперекладених рядків.
FIRST=1
if [ "$LIMIT" -gt 0 ]; then
    FIRST=$((ACTIVE - LIMIT + 1))
    test "$FIRST" -ge 1 || FIRST=1
fi

printf '%-8s %-14s %-14s %s\n' "патч" "без machine" "без manual" ""
printf '%s\n' "----------------------------------------------------"
work_machine=0
for ((n = ACTIVE; n >= FIRST; n--)); do
    machine="$(total_matching "$n" machine)"
    manual="$(total_matching "$n" manual)"
    mark=""
    test "$n" = "$ACTIVE" && mark="активний"
    case "$machine" in ''|*[!0-9]*) ;; *) work_machine=$((work_machine + machine)) ;; esac
    printf '%-8s %-14s %-14s %s\n' "$n" "$machine" "$manual" "$mark"
done
printf '%s\n' "----------------------------------------------------"
printf 'Разом без machine-перекладу: %d рядків\n' "$work_machine"
echo "Узяти конкретний патч у роботу: ./bdo mode start patch 15 <номер>"
