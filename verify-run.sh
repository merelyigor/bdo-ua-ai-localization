#!/usr/bin/env bash
# Перевірити фактичну поведінку субагентів за базою OpenCode, а не за скріншотами.
#
#   ./verify-run.sh          # останні 10 сесій translation-*
#   ./verify-run.sh 25       # останні 25
#
# Для кожної дочірньої сесії показує реальний провайдер/модель, токени та виклики
# інструментів, і позначає порушення контракту:
#   ROUTE  - маршрут не ollama-local (субагент міг з'їсти ліміт платної моделі)
#   THINK  - ненульові reasoning-токени (reasoning_effort не дійшов)
#   TOOLS  - constrained-агент викликав інструмент (має бути tools "*": false)
#   EMPTY  - нульовий вихід (субагент помер, не відповівши)
set -euo pipefail

LIMIT="${1:-10}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"

# Оцінюємо сесії ЦЬОГО прогону, а не всю історію. Інакше порушення, полагоджене
# годину тому, лишається у вибірці й зупиняє новий прогін: 2026-08-20 диригент
# двічі спинився на вже здоровій конфігурації через QA-сесію з попереднього
# прогону. Мітку ставить `run-start.sh`; без неї (прогін не розпочато) дивимось
# усю історію, як раніше.
SINCE=0
SINCE_NOTE="уся історія (прогін не розпочато · run-start.sh)"
if [ -f "$STATE_DIR/run-started-at" ]; then
    SINCE="$(head -1 "$STATE_DIR/run-started-at")"
    SINCE_NOTE="сесії поточного прогону"
fi
case "$SINCE" in
    ''|*[!0-9]*) SINCE=0; SINCE_NOTE="уся історія (пошкоджена мітка старту)" ;;
esac
echo "Оцінюємо: $SINCE_NOTE"
echo

DB="$HOME/.local/share/opencode/opencode.db"
test -f "$DB" || { echo "Немає бази OpenCode: $DB" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "Потрібен sqlite3" >&2; exit 1; }

# Копія: OpenCode тримає базу відкритою, читаємо без блокування запису.
TMP="$(mktemp -t ocverify)"
trap 'rm -f "$TMP" "$TMP-wal" "$TMP-shm"' EXIT
sqlite3 "$DB" ".backup '$TMP'" 2>/dev/null || cp "$DB" "$TMP"

sqlite3 -noheader -separator '|' "$TMP" "
SELECT s.id, s.agent,
       COALESCE(json_extract(s.model,'\$.providerID'),'?') || '/' || COALESCE(json_extract(s.model,'\$.id'),'?'),
       s.tokens_input, s.tokens_output, s.tokens_reasoning, s.cost,
       COALESCE((SELECT group_concat(DISTINCT json_extract(p.data,'\$.tool'))
                 FROM part p WHERE p.session_id = s.id
                 AND json_extract(p.data,'\$.type') = 'tool'), ''),
       substr(s.title, 1, 30)
FROM session s
WHERE s.agent IN ('translation-worker','translation-repair','translation-qa',
                  'translation-smoke','translation-terminology')
  AND s.time_created >= $SINCE
ORDER BY s.time_created DESC LIMIT $LIMIT;" | awk -F'|' '
BEGIN { fails = 0 }
{
    id = $1; agent = $2; route = $3; inp = $4; outp = $5; think = $6; cost = $7; tools = $8; title = $9
    problems = ""
    if (route !~ /^ollama-local\//) problems = problems " ROUTE"
    if (think + 0 > 0) problems = problems " THINK"
    if (outp + 0 == 0) problems = problems " EMPTY"
    constrained = (agent == "translation-worker" || agent == "translation-repair" \
                || agent == "translation-qa" || agent == "translation-smoke")
    if (constrained && tools != "") problems = problems " TOOLS"
    mark = (problems == "") ? "OK  " : "FAIL"
    if (problems != "") fails++
    printf "%s %-22s %-28s in=%-6s out=%-5s think=%-3s $%s\n", mark, agent, substr(route,1,28), inp, outp, think, cost
    printf "     %s\n", title
    if (tools != "") printf "     інструменти: %s\n", tools
    if (problems != "") printf "     ПОРУШЕННЯ:%s\n", problems
}
END {
    printf "\n"
    if (fails == 0) print "Усі дочірні сесії відповідають контракту."
    else { printf "Дочірніх сесій із порушеннями: %d\n", fails }
    exit (fails == 0) ? 0 : 1
}' || RC=1

# Диригент свідомо на платній моделі, тому під ROUTE/THINK не підпадає.
# Показуємо його окремо: тут важливо СКІЛЬКИ платних токенів пішло на пачку.
echo
echo "Диригент (платна модель, не оцінюється за контрактом субагентів):"
sqlite3 -noheader -separator '|' "$TMP" "
SELECT COALESCE(json_extract(s.model,'\$.providerID'),'?') || '/' || COALESCE(json_extract(s.model,'\$.id'),'?'),
       s.tokens_input, s.tokens_output, s.tokens_reasoning, s.cost, substr(s.title,1,34)
FROM session s WHERE s.agent = 'translation'
ORDER BY s.time_created DESC LIMIT 3;" | awk -F'|' '
{ printf "     %-26s in=%-8s out=%-6s think=%-6s $%s\n       %s\n", substr($1,1,26), $2, $3, $4, $5, $6 }
END { if (NR == 0) print "     (сесій диригента ще немає)" }'

exit "${RC:-0}"
