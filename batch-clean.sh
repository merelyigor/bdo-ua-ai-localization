#!/usr/bin/env bash
# Прибрати робочі файли завершених пачок і старі відповіді API.
#
#   ./batch-clean.sh              # показати, що буде прибрано, і нічого не робити
#   ./batch-clean.sh --apply      # прибрати
#   ./batch-clean.sh --days 3 --apply
#
# Що прибирається: теки пачок у state/batches/ і файли в output/, старші за
# BDO_KEEP_DAYS (типово 7). Поточна пачка не чіпається ніколи.
#
# Що НЕ прибирається за жодних умов:
#   - state/quarantine.jsonl - це перелік рядків, які не доїхали; його розбирає
#     власник, і втратити його означає втратити роботу;
#   - state/write-log.jsonl - незнищенний слід того, що і куди записано;
#   - state/run-target і state/current-batch - живий стан;
#   - будь-що поза цими двома теками.
#
# Режим за замовчуванням - показ. Видалення робочих файлів необоротне, а різниця
# між «показати» і «зробити» має бути в явному прапорці, а не в уважності.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
OUTPUT_DIR="$SCRIPT_DIR/output"
DAYS="${BDO_KEEP_DAYS:-7}"
APPLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --days) DAYS="${2:?--days потребує число}"; shift 2 ;;
        *) echo "Невідомий аргумент: $1" >&2; exit 1 ;;
    esac
done

case "$DAYS" in
    ''|*[!0-9]*) echo "--days має бути цілим числом, отримано '$DAYS'." >&2; exit 1 ;;
esac

CURRENT_ID=""
test -f "$STATE_DIR/current-batch" && CURRENT_ID="$(head -1 "$STATE_DIR/current-batch" | tr -d '[:space:]')"

echo "Зберігаємо все, молодше за $DAYS дн. Поточна пачка: ${CURRENT_ID:-немає}"
echo

removed=0
if [ -d "$STATE_DIR/batches" ]; then
    while IFS= read -r dir; do
        name="$(basename "$dir")"
        if [ -n "$CURRENT_ID" ] && [ "$name" = "$CURRENT_ID" ]; then
            echo "  ПРОПУСК (поточна): $name"
            continue
        fi
        size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
        if [ "$APPLY" = 1 ]; then
            rm -rf "$dir"
            echo "  прибрано: $name ($size)"
        else
            echo "  буде прибрано: $name ($size)"
        fi
        removed=$((removed + 1))
    done < <(find "$STATE_DIR/batches" -mindepth 1 -maxdepth 1 -type d -mtime "+$DAYS" | sort)
fi

files=0
if [ -d "$OUTPUT_DIR" ]; then
    while IFS= read -r file; do
        if [ "$APPLY" = 1 ]; then
            rm -f "$file"
            echo "  прибрано: output/$(basename "$file")"
        else
            echo "  буде прибрано: output/$(basename "$file")"
        fi
        files=$((files + 1))
    done < <(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 2 -type f -mtime "+$DAYS" | sort)
fi

echo
printf "Тек пачок: %d | файлів у output: %d\n" "$removed" "$files"
if [ "$APPLY" = 1 ]; then
    echo "ВИРОК: прибрано. Карантин і поточна пачка недоторкані."
elif [ $((removed + files)) -eq 0 ]; then
    echo "ВИРОК: прибирати нічого."
else
    echo "ВИРОК: це лише показ. Прибрати: ./batch-clean.sh --days $DAYS --apply"
fi
