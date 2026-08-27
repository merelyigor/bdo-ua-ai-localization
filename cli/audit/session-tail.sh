#!/usr/bin/env bash
# Показати ОСТАННІ кроки живої сесії диригента: що він викликав і чим це скінчилось.
#
#   ./session-tail.sh            # 25 останніх кроків активного primary
#   ./session-tail.sh 60         # більше кроків
#   ./session-tail.sh 25 --errors # лише відмови
#
# Навіщо окрема команда, коли є `./bdo audit`.
#
# `audit` відповідає на питання «чи дотримались субагенти контракту»: моделі,
# токени, THINK/TOOLS/ROUTE. Він НЕ показує, що робив диригент і на чому впав.
# 2026-08-28 це коштувало живого розбору: пачка стояла в `healing`, я дивився на
# стан пачки і на лічильники токенів сесії, побачив «нічого не рухається» і
# зробив висновок «сесія мовчить». Насправді сесія працювала: диригент двічі
# намагався САМ полагодити `lib/Pipeline/StateMachine.php` через `bash php -r`,
# і обидва рази guard відмовив. Ні стан пачки, ні `tokens_input` цього не
# показують · відмовлений виклик не додає токенів і не рухає пачку.
#
# Тому дебаг сесії мусить читати саме частини повідомлень (`part`), а не зведені
# лічильники. Порожній вивід тут є відповіддю «сесії немає», а не мовчанням.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIMIT="${1:-25}"
ONLY_ERRORS=0
case "${2:-}" in
    --errors) ONLY_ERRORS=1 ;;
    '') ;;
    *) echo "Невідомий прапорець: $2" >&2; exit 1 ;;
esac
case "$LIMIT" in
    ''|*[!0-9]*) echo "Кількість кроків має бути числом." >&2; exit 1 ;;
esac

# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/opencode-home.sh"
DB="$OPENCODE_DB"
if [ -z "$DB" ]; then
    echo "Немає бази OpenCode. Перевірено:" >&2
    printf '%s' "$OPENCODE_TRIED" >&2
    exit 1
fi
command -v sqlite3 >/dev/null || {
    echo 'Потрібен sqlite3: саме ним читається база сесій OpenCode.' >&2
    echo 'Доставити: ./bdo platform --fix' >&2
    exit 1
}

TMP="$(mktemp -t octail)"
trap 'rm -f "$TMP" "$TMP-wal" "$TMP-shm"' EXIT
sqlite3 "$DB" ".backup '$TMP'" 2>/dev/null || cp "$DB" "$TMP"

SESSION="$(sqlite3 -noheader "$TMP" "
SELECT id FROM session
WHERE directory = '$SCRIPT_DIR'
  AND agent IN ('патч','ручний','пропозиції','покращення-ші')
ORDER BY time_updated DESC LIMIT 1;")"

if [ -z "$SESSION" ]; then
    echo "Сесій диригента для $SCRIPT_DIR у базі немає."
    exit 0
fi

sqlite3 -noheader -separator '|' "$TMP" "
SELECT datetime(time_created/1000,'unixepoch','localtime'), agent,
       COALESCE(json_extract(model,'\$.id'),'?')
FROM session WHERE id = '$SESSION';" \
    | awk -F'|' '{printf "Сесія: %s | режим %s | модель %s\n", $1, $2, $3}'
echo

# Останні N частин у ХРОНОЛОГІЧНОМУ порядку: читати згори вниз, як у чаті.
sqlite3 -noheader -separator $'\t' "$TMP" "
SELECT * FROM (
  SELECT time_created AS ts,
         strftime('%H:%M:%S', time_created/1000, 'unixepoch', 'localtime'),
         json_extract(data,'\$.type'),
         COALESCE(json_extract(data,'\$.tool'),''),
         COALESCE(json_extract(data,'\$.state.status'),''),
         -- Переноси рядків прибираються ТУТ: одна частина = один рядок виводу,
         -- інакше багаторядковий текст чи вивід ламає розбір колонок.
         replace(replace(COALESCE(json_extract(data,'\$.state.error'),''), char(10), ' '), char(9), ' '),
         replace(replace(COALESCE(json_extract(data,'\$.state.input.command'),
                  json_extract(data,'\$.state.input.filePath'),
                  json_extract(data,'\$.state.input.subagent_type'),
                  json_extract(data,'\$.text'),''), char(10), ' '), char(9), ' '),
         replace(replace(COALESCE(json_extract(data,'\$.state.output'),''), char(10), ' '), char(9), ' ')
  FROM part
  WHERE session_id = '$SESSION'
    AND json_extract(data,'\$.type') IN ('tool','text')
  ORDER BY time_created DESC LIMIT $LIMIT
) ORDER BY ts ASC;" \
| ONLY_ERRORS="$ONLY_ERRORS" awk -F'\t' '
function short(s, n) { gsub(/[\r\n]+/, " ", s); return (length(s) > n) ? substr(s, 1, n) "…" : s }
{
    when = $2
    kind = $3; tool = $4; status = $5; err = $6; what = $7; out = $8
    if (ENVIRON["ONLY_ERRORS"] == "1" && err == "" && status != "error") next
    if (kind == "text") { printf "%s  ТЕКСТ    %s\n", when, short(what, 100); next }
    mark = (err != "" || status == "error") ? "ВІДМОВА " : "ok      "
    printf "%s  %s%-10s %s\n", when, mark, tool, short(what, 76)
    if (err != "") printf "%s           причина: %s\n", "        ", short(err, 150)
    else if (out != "" && tool == "bash") printf "%s           %s\n", "        ", short(out, 110)
}
'

echo
# Порожній вивід є ВІДПОВІДДЮ, а не мовчанням: інакше «нічого не показало»
# читається як «нічого не сталося», і саме на цьому 2026-08-28 я помилився.
STEPS="$(sqlite3 -noheader "$TMP" "
SELECT count(*) FROM part WHERE session_id = '$SESSION'
  AND json_extract(data,'\$.type') IN ('tool','text');")"
FAILS="$(sqlite3 -noheader "$TMP" "
SELECT count(*) FROM part WHERE session_id = '$SESSION'
  AND json_extract(data,'\$.state.error') IS NOT NULL;")"
printf 'Усього кроків у сесії: %s | відмов: %s\n' "$STEPS" "$FAILS"
test "$ONLY_ERRORS" = 1 || echo "Лише відмови: ./bdo session $LIMIT --errors"
