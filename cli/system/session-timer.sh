#!/usr/bin/env bash
if [ "${BDO_ORCHESTRATOR:-php}" != sh ]; then
    exec php "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/cli/bdo.php" session-timer "$@"
fi
# Скільки триває поточна робоча сесія і скільки лишилось до межі.
#
#   ./session-timer.sh start [ISO-час]   # почати відлік (типово · зараз)
#   ./session-timer.sh                   # скільки минуло й скільки лишилось
#   ./session-timer.sh check             # код 1, якщо межу вичерпано
#
# Навіщо. Довга сесія коштує не лише токенів: чим довше вона триває, тим більше
# в ній накопичується контексту й тим імовірніше, що робота обірветься посеред
# кроку. Власник задав межу 4 години (рішення 2026-09-04) і попросив, щоб її
# було ВИДНО, а не оцінювалось на око.
#
# Межа мʼяка за побудовою: скрипт нічого не вбиває. Він дає цифру, за якою
# агент вирішує завершити поточний етап і зупинитись, а не почати новий.
#
# ЧАС ЗБЕРІГАЄТЬСЯ EPOCH-СЕКУНДАМИ, і це не деталь реалізації. Перша редакція
# писала локальний рядок `2026-09-03 23:36:39`, а рахувала його через PHP
# `strtotime`, у якого своя типова таймзона: таймер показав 3 години замість
# шести, тобто впевнено збрехав рівно там, де його й заводили. Epoch не має
# таймзони взагалі.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
FILE="$STATE_DIR/session-timer.json"
BUDGET_MINUTES="${BDO_SESSION_BUDGET_MINUTES:-240}"

# D158: epoch -> локальний рядок. `date -r <epoch>` це BSD; GNU date розуміє
# `-r` як «час файла», тому на Linux мовчки друкував ПОРОЖНЄ місце замість дати
# («Відлік почато: , межа 240 хв.»). Спіймано CI на ubuntu 2026-09-12, коли
# парність із PHP вимагала однакового рядка на обох ОС. Порядок спроб той
# самий, що й у `to_epoch`: спершу BSD, потім GNU.
from_epoch() {
    date -r "$1" "+$2" 2>/dev/null \
        || date -d "@$1" "+$2" 2>/dev/null \
        || return 1
}

# Локальний рядок -> epoch. BSD (`date -j -f`) і GNU (`date -d`) роблять це
# по-різному, тому пробуємо обидва; помилка тут краща за мовчазне «зараз».
to_epoch() {
    local text="$1"
    date -j -f "%Y-%m-%d %H:%M:%S" "$text" "+%s" 2>/dev/null \
        || date -d "$text" "+%s" 2>/dev/null \
        || return 1
}

case "${1:-status}" in
    start)
        mkdir -p "$STATE_DIR"
        if [ -n "${2:-}" ]; then
            started="$(to_epoch "$2")" || { echo "Незрозумілий час старту: $2" >&2; exit 1; }
        else
            started="$(date +%s)"
        fi
        printf '{\n  "started_epoch": %s,\n  "budget_minutes": %s\n}\n' \
            "$started" "$BUDGET_MINUTES" > "$FILE"
        printf 'Відлік почато: %s, межа %s хв.\n' "$(from_epoch "$started" '%Y-%m-%d %H:%M:%S')" "$BUDGET_MINUTES"
        ;;
    status|check)
        if [ ! -f "$FILE" ]; then
            echo "Відлік не запущено: ./bdo timer start" >&2
            exit 0
        fi
        started="$(sed -n 's/.*"started_epoch": *\([0-9]*\).*/\1/p' "$FILE")"
        budget="$(sed -n 's/.*"budget_minutes": *\([0-9]*\).*/\1/p' "$FILE")"
        test -n "$started" && test -n "$budget" \
            || { echo "Пошкоджений файл таймера: $FILE" >&2; exit 1; }
        spent=$(( ( $(date +%s) - started ) / 60 ))
        left=$(( budget - spent ))
        printf 'Сесія: %s | минуло %d год %02d хв із %d хв межі\n' \
            "$(from_epoch "$started" '%Y-%m-%d %H:%M')" $((spent / 60)) $((spent % 60)) "$budget"
        if [ "$left" -gt 0 ]; then
            printf 'Лишилось: %d хв. Нових великих етапів після %s не починати.\n' \
                "$left" "$(from_epoch $((started + budget * 60)) '%H:%M')"
        else
            printf 'МЕЖУ ВИЧЕРПАНО на %d хв. Завершити поточний етап і зупинитись.\n' $(( -left ))
            # D157: було `test … = check && exit 1` ОСТАННІМ рядком гілки, тому
            # при `status` список `&&` завершувався зі статусом 1 і ставав кодом
            # виходу всього скрипта. Контракт у шапці обіцяє код 1 лише для
            # `check`, а `status` мовчки віддавав 1 на вичерпаній межі.
            if [ "${1:-status}" = check ]; then exit 1; fi
        fi
        ;;
    *)
        echo "Використання: session-timer.sh [start [ISO-час] | status | check]" >&2
        exit 2
        ;;
esac
