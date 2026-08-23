#!/usr/bin/env bash
# Дефекти відповідей child, які флоу вилікував сам.
#
#   ./flow-incidents.sh            зведення за ролями й причинами
#   ./flow-incidents.sh --list     останні записи повністю
#   ./flow-incidents.sh --clear    архівувати журнал після розбору
#
# Навіщо окремий журнал. Мета власника · безперервний ланцюжок: коли child
# віддає JSON у markdown-огорожі або порожню відповідь, прогін не зупиняється ·
# плагін фіксує факт, а наступний `./bdo run drive` перезапускає того самого
# child з уточненням. Але «полагодилось само» не означає «проблеми немає»:
# повторюваний дефект треба виправляти на рівні проєкту (промпт ролі, схема,
# інша модель), і саме для цього тут лишається слід.
#
# Журнал пише плагін, а не цей скрипт. Тут лише читання.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
LOG="$STATE_DIR/flow-incidents.jsonl"
MODE="${1:-summary}"

test -f "$LOG" || { echo "Інцидентів немає: $LOG не створено."; exit 0; }

case "$MODE" in
    --clear)
        mv "$LOG" "$LOG.$(date +%Y%m%d_%H%M%S).archived"
        rm -f "$STATE_DIR/child-incidents.json"
        echo "Журнал заархівовано; лічильники спроб скинуто."
        ;;
    --list)
        php -r '
        foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            $e = json_decode($line, true);
            if (! is_array($e)) continue;
            printf("%s  %-24s спроба %d  %s\n    %s\n",
                $e["at"] ?? "?", $e["role"] ?? "?", $e["attempt"] ?? 0, $e["reason"] ?? "?",
                str_replace("\n", " ", substr((string) ($e["sample"] ?? ""), 0, 160)));
        }' "$LOG"
        ;;
    summary)
        php -r '
        $rows = [];
        $total = 0;
        foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            $e = json_decode($line, true);
            if (! is_array($e)) continue;
            $key = ($e["role"] ?? "?") . " | " . ($e["reason"] ?? "?");
            $rows[$key] = ($rows[$key] ?? 0) + 1;
            $total++;
        }
        printf("Інцидентів формату: %d\n", $total);
        arsort($rows);
        foreach ($rows as $key => $count) printf("  %4d  %s\n", $count, $key);
        echo "\nПовні записи: ./bdo incidents --list | після розбору: ./bdo incidents --clear\n";
        echo "Повторюваний дефект тієї самої ролі означає роботу над промптом або моделлю,\n";
        echo "а не над окремою пачкою.\n";
        ' "$LOG"
        ;;
    *) echo "Дозволено: (без аргументів) | --list | --clear" >&2; exit 2 ;;
esac
