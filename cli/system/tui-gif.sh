#!/usr/bin/env bash
# Записати екрани TUI у GIF для документації й звітів.
#
#   ./tui-gif.sh                 записати docs/assets/tui-status.gif
#   ./tui-gif.sh --tape          лише показати сценарій, нічого не записувати
#   ./tui-gif.sh --out FILE.gif  свій шлях виводу
#
# Навіщо. Скріншот вікна власник робить руками, і в звіті агента його немає
# взагалі · тому опис екрана в документації старіє тихо. `vhs` рендерить той
# самий TUI у GIF детерміновано: сценарій (`.tape`) описує натискання, а вихід
# є артефактом, який можна покласти в документ або в звіт.
#
# Межа сенсу названа прямо: GIF є ДОКУМЕНТАЦІЄЮ, а не доказом. Доказ того, що
# вікно працює · `tests/tui-live.sh` (справжній PTY, перевірка кодів виходу).
# Гарний GIF на зламаному вікні зробити легко, і саме тому він нічого не
# доводить.
#
# `vhs` не є залежністю набору: без нього скрипт ПАДАЄ з названою причиною й
# інструкцією, а не малює порожній файл.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$SCRIPT_DIR/docs/assets/tui-status.gif"
MODE=render

while [ $# -gt 0 ]; do
    case "$1" in
        --tape) MODE=tape; shift ;;
        --out)
            OUT="${2:?--out потребує шлях}"
            case "$OUT" in *.gif) ;; *) echo "--out мусить бути *.gif, отримано '$OUT'" >&2; exit 2 ;; esac
            shift 2
            ;;
        *) echo "Дозволено: --tape | --out FILE.gif" >&2; exit 2 ;;
    esac
done

# Сценарій пишемо тут, а не тримаємо файлом: він мусить відповідати ПОТОЧНОМУ
# меню, а меню живе в `bin/tui.sh`. Окремий `.tape` на диску розійшовся б із
# ним тихо · рівно так само, як ручна копія дерева команд у документації.
#
# Натискаються ЛИШЕ безпечні пункти: 1 (стан), 2 (журнал), q (вихід). Пункти
# 1-5 запускають прогін і в записі не використовуються ніколи.
tape() {
    cat <<TAPE
Output $OUT
Set Shell bash
Set FontSize 15
Set Width 1500
Set Height 900
Set Padding 12
Type "cd $SCRIPT_DIR && ./bdo"
Enter
Sleep 6s
Type "1"
Enter
Sleep 8s
Enter
Sleep 2s
Type "2"
Enter
Sleep 4s
Enter
Sleep 2s
Type "q"
Enter
Sleep 2s
TAPE
}

if [ "$MODE" = tape ]; then
    tape
    exit 0
fi

if ! command -v vhs >/dev/null 2>&1; then
    cat >&2 <<'MISS'
tui-gif: немає vhs · записати GIF нічим.
  встановити:  brew install vhs
  подивитись сценарій без запису:  ./bdo gif --tape
Порожнього файла замість запису не створюємо: він читався б як «GIF є».
MISS
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
TAPE_FILE="$(mktemp -t bdo-tui-tape.XXXXXX)"
trap 'rm -f "$TAPE_FILE"' EXIT
tape > "$TAPE_FILE"
vhs "$TAPE_FILE"
test -s "$OUT" || { echo "tui-gif: vhs завершився, але $OUT порожній або відсутній" >&2; exit 1; }
printf 'Записано: %s (%s КБ)\n' "$OUT" "$(( $(wc -c < "$OUT") / 1024 ))"
echo 'Це документація, не доказ: працездатність вікна доводить tests/tui-live.sh.'
