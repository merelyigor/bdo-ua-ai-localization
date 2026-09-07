#!/usr/bin/env bash
# Набір мусить працювати, коли його запустили НЕ з термінала.
#
# Значок у Dock стартує процес через LaunchServices, і той дає мінімальний
# PATH: `/usr/bin:/bin:/usr/sbin:/sbin`. Homebrew ставить `php` у
# `/opt/homebrew/bin`, тому набір, який ідеально працює в терміналі, з-під
# значка вмирав написом «web: немає php» (виявлено власником 2026-09-06).
#
# Перевірка йде ТИМ САМИМ шляхом, що й робота: `./bdo` запускається під
# справді обчищеним оточенням (`env -i`), а не з підробленою змінною. Інакше
# вона довела б лише те, що файл існує.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

MIN_PATH='/usr/bin:/bin:/usr/sbin:/sbin'

# Передумова тесту. Якщо php лежить у базовому PATH, тест нічого не доводить ·
# він мусить сказати це вголос, а не тихо «пройти».
if env -i PATH="$MIN_PATH" bash -c 'command -v php' >/dev/null 2>&1; then
    printf 'gui path: SKIP · php у базовому PATH, кліковий запуск тут не ламався\n'
    exit 0
fi

cd "$ROOT"

# 1. Логін-оболонка. Основний шлях: беремо PATH звідти, де набір працює.
env -i PATH="$MIN_PATH" HOME="$HOME" SHELL="${SHELL:-/bin/zsh}" \
    ./bdo help >/dev/null 2>&1 \
    || fail 'кліковий запуск не бачить php · значок у Dock помре на «немає php»'

# 2. Запасний шлях. SHELL не заданий · лишаються типові теки Homebrew.
env -i PATH="$MIN_PATH" HOME="$HOME" ./bdo help >/dev/null 2>&1 \
    || fail 'без SHELL запасні теки не підхопились · кліковий запуск лишається зламаним'

# 3. Профіль має право друкувати. `~/.zprofile` цілком законно пише щось на
#    кшталт «nvm: середовище завантажено», і цей рядок НЕ сміє стати
#    частиною PATH · саме для цього в обміні є маркер.
#
#    Друк навмисно ПОЧИНАЄТЬСЯ зі скісної риски. Балаканина, що починається з
#    літери, відсіюється й без маркера (перевіркою `/*`), тому тест на ній
#    доводив би нуль · саботаж це показав.
#
#    І дивимось ми на САМ PATH, а не на «`./bdo help` спрацював»: із отруєним
#    PATH набір усе одно знаходить php через запасні теки, тому успіх команди
#    отруєння не бачить взагалі.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/noisy-shell" <<'SH'
#!/usr/bin/env bash
printf '/tmp/bdo-junk-note завантажено\n'
exec /bin/bash -c "$2"
SH
chmod +x "$TMP/noisy-shell"
got="$(env -i PATH="$MIN_PATH" HOME="$HOME" SHELL="$TMP/noisy-shell" \
    bash -c '. "$1/cli/system/gui-path.sh"; printf %s "$PATH"' _ "$ROOT" 2>/dev/null)" \
    || fail 'gui-path.sh упав під балакучим профілем'
case "$got" in
    *bdo-junk-note*) fail "друк профілю потрапив у PATH · маркер обміну не тримає межу: $got" ;;
esac
case "$got" in
    *"
"*) fail 'у PATH опинився перенос рядка · обмін із оболонкою не відфільтрований' ;;
esac
test -n "$got" || fail 'під балакучим профілем PATH став порожнім'

# 4. У ТЕРМІНАЛІ ЦІНА НУЛЬ. Коли php уже видно, файл не має права чіпати PATH:
#    інакше кожен виклик набору тягнув би за собою логін-оболонку.
before="$PATH"
# shellcheck source=../cli/system/gui-path.sh
. "$ROOT/cli/system/gui-path.sh"
test "$PATH" = "$before" \
    || fail 'gui-path.sh змінює PATH там, де php уже знайдено · зайвий підпроцес на кожен виклик'

# 5. КЛІКОВИЙ ЗАПУСК ДАЄ ІНШИЙ ІНТЕРПРЕТАТОР · головна частина (D106).
#
# PATH значка містить `/usr/local/bin` і `/bin`, тому `php` там знаходився, а
# `bash` лишався `/bin/bash` 3.2.57 · і скрипти, які в терміналі йдуть у
# bash 5, з-під значка виконувались старим bash. Пачка власника стала на
# `qa_args[@]: unbound variable`, чого в bash 5 не буває взагалі.
#
# Тому перевіряємо саме ВЕРСІЮ bash, а не наявність php: наявності було не
# досить, і перша редакція цього не ловила.
CLICK_PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
got="$(env -i PATH="$CLICK_PATH" HOME="$HOME" SHELL="${SHELL:-/bin/zsh}" \
    bash -c '. "$1/cli/system/gui-path.sh"; printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}:$(bash -c "printf %s \"\${BASH_VERSINFO[0]}\"")"' _ "$ROOT" 2>/dev/null)"
child="${got##*:}"
test -n "$child" || fail 'не вдалося дізнатись версію bash після відновлення PATH'
test "$child" -ge 4 \
    || fail "після відновлення PATH дочірній bash усе одно $child · кліковий запуск виконує скрипти старим інтерпретатором (D106)"

printf 'gui path: OK · кліковий запуск бачить php і НОВИЙ bash, профіль не отруює PATH, у терміналі змін немає.\n'
