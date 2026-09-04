#!/usr/bin/env bash
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
        printf 'Відлік почато: %s, межа %s хв.\n' "$(date -r "$started" '+%Y-%m-%d %H:%M:%S')" "$BUDGET_MINUTES"
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
            "$(date -r "$started" '+%Y-%m-%d %H:%M')" $((spent / 60)) $((spent % 60)) "$budget"
        if [ "$left" -gt 0 ]; then
            printf 'Лишилось: %d хв. Нових великих етапів після %s не починати.\n' \
                "$left" "$(date -r $((started + budget * 60)) '+%H:%M')"
        else
            printf 'МЕЖУ ВИЧЕРПАНО на %d хв. Завершити поточний етап і зупинитись.\n' $(( -left ))
            test "${1:-status}" = check && exit 1
        fi
        ;;
    *)
        echo "Використання: session-timer.sh [start [ISO-час] | status | check]" >&2
        exit 2
        ;;
esac
