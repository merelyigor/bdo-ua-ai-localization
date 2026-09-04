#!/usr/bin/env bash
# Перевірити середовище прогону і, за запитом, доставити те, чого бракує.
#
#   ./check-platform.sh          # діагностика: платформа, залежності, дані OpenCode
#   ./check-platform.sh --fix    # доставити відсутні пакети через apt або brew
#
# Підтримувані платформи: macOS, Linux, Windows через WSL2. На Windows у WSL
# виконується САМ набір; OpenCode при цьому може бути native Windows-застосунком ·
# перехід у WSL робить execution-guard, а не агент.
#
# Чому залежності поділені на дві групи, а не на один список.
#
# Раніше будь-який відсутній інструмент валив preflight, а разом із ним · усю
# сесію. Але `sqlite3` потрібен ЛИШЕ для `./bdo audit`, тобто для діагностики
# після прогону, а `shellcheck` · лише для `./bdo gate shell`, тобто для
# розробки самого набору. Через них не можна не перекласти жодного рядка: це
# блокування заради блокування. Тому обовʼязкові лише ті, без яких неможливий
# сам прогін, а решта дає WARN із точною ціною.
set -euo pipefail

FIX=0
case "${1:-}" in
    '') ;;
    --fix) FIX=1 ;;
    *) echo "Дозволено лише --fix, отримано '$1'." >&2; exit 2 ;;
esac

# Без цих п'яти не працює жодна пачка.
REQUIRED='bash php jq curl git'
# Ці лише звужують можливості, і кожен рядок нижче називає, що саме зникає.
declare -a OPTIONAL_NAMES=(sqlite3 shellcheck)
declare -a OPTIONAL_COST=(
    './bdo audit і audit-dump не читатимуть базу сесій OpenCode'
    './bdo gate shell не перевірятиме скрипти'
)

IS_WSL=0
kernel="$(uname -s)"
case "$kernel" in
Darwin) echo 'Платформа: macOS' ;;
Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
        test -n "${WSL_DISTRO_NAME:-}" || { echo 'FAIL: виявлено WSL без WSL_DISTRO_NAME; потрібен WSL2 runtime.' >&2; exit 1; }
        IS_WSL=1
        case "$(pwd -P)" in
        /mnt/*) echo 'WARN: репозиторій лежить на Windows mount; для швидкості перенеси його у Linux filesystem (наприклад ~/GitHub).' >&2 ;;
        esac
        echo "Платформа: Windows/WSL2 (${WSL_DISTRO_NAME})"
    else echo 'Платформа: Linux'
    fi
    ;;
*) echo "FAIL: $kernel не підтримується; на Windows використовуй WSL2." >&2; exit 1 ;;
esac

# Назва пакета не завжди дорівнює назві команди.
package_for() {
    case "$1" in
    php) test "$(uname -s)" = Darwin && echo php || echo php-cli ;;
    *) echo "$1" ;;
    esac
}

# Встановлення відокремлене від діагностики й ніколи не запускається саме.
#
# `sudo -n`, а не `sudo`: без нього агентська сесія без tty зависла б на запиті
# пароля назавжди, і прогін виглядав би як мертвий. Якщо пароль потрібен, ми
# віддаємо власнику РІВНО один рядок для вставки й чесно кажемо, що самі далі
# не пройдемо.
install_missing() {
    local missing="$1" manager packages line
    packages="$(for tool in $missing; do package_for "$tool"; done | tr '\n' ' ')"
    packages="${packages% }"
    if command -v apt-get >/dev/null 2>&1; then
        manager=apt
        line="sudo apt update && sudo apt install -y $packages"
    elif command -v brew >/dev/null 2>&1; then
        manager=brew
        line="brew install $packages"
    else
        echo "FAIL: не знайдено ні apt, ні brew; встанови вручну: $packages" >&2
        return 1
    fi
    echo "Встановлюю ($manager): $packages"
    if [ "$manager" = brew ]; then
        brew install $packages && return 0
    else
        sudo -n apt-get update -qq >/dev/null 2>&1 \
            && sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $packages >/dev/null 2>&1 \
            && return 0
    fi
    echo 'ПОТРІБЕН ПАРОЛЬ: автоматичне встановлення неможливе без tty.' >&2
    echo 'Вставте цей рядок у свій термінал і напишіть агенту «продовжуй»:' >&2
    echo "  $line" >&2
    return 1
}

missing_required=''
for tool in $REQUIRED; do
    command -v "$tool" >/dev/null 2>&1 || missing_required="$missing_required $tool"
done
missing_optional=''
for index in "${!OPTIONAL_NAMES[@]}"; do
    command -v "${OPTIONAL_NAMES[$index]}" >/dev/null 2>&1 \
        || missing_optional="$missing_optional ${OPTIONAL_NAMES[$index]}"
done

if [ "$FIX" = 1 ] && [ -n "$missing_required$missing_optional" ]; then
    install_missing "${missing_required#" "} ${missing_optional#" "}" || exit 1
    missing_required=''
    missing_optional=''
    for tool in $REQUIRED; do
        command -v "$tool" >/dev/null 2>&1 || missing_required="$missing_required $tool"
    done
    for index in "${!OPTIONAL_NAMES[@]}"; do
        command -v "${OPTIONAL_NAMES[$index]}" >/dev/null 2>&1 \
            || missing_optional="$missing_optional ${OPTIONAL_NAMES[$index]}"
    done
fi

if [ -n "$missing_required" ]; then
    for tool in $missing_required; do echo "FAIL: немає $tool" >&2; done
    echo 'Полагодити автоматично: ./bdo platform --fix' >&2
    if [ "$IS_WSL" = 1 ]; then
        echo 'Ставити треба ВСЕРЕДИНІ WSL2, не через winget.' >&2
    fi
    exit 1
fi

for index in "${!OPTIONAL_NAMES[@]}"; do
    tool="${OPTIONAL_NAMES[$index]}"
    case " $missing_optional " in
    *" $tool "*) echo "WARN: немає $tool · ${OPTIONAL_COST[$index]} (./bdo platform --fix)" >&2 ;;
    esac
done

php_version="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
php -r 'exit(PHP_VERSION_ID >= 80300 ? 0 : 1);' 2>/dev/null || { echo "FAIL: потрібен PHP 8.3+, знайдено ${php_version:-невідому версію}." >&2; exit 1; }
echo "PHP: $php_version"

# Локальна Ollama · єдиний рантайм моделей. Тут це WARN, а не FAIL: набір
# уміє показувати стан і плани без моделі, а от мовчки дізнатись про недоступний
# endpoint уже на пачці · не можна.
ollama_url="${OLLAMA_URL:-http://127.0.0.1:11434}"
if curl -fsS -m 3 "$ollama_url/api/tags" >/dev/null 2>&1; then
    echo "Ollama: $ollama_url"
else
    echo "WARN: Ollama не відповідає на $ollama_url · переклад не запуститься." >&2
    echo '      Перевірити детально: ./bdo runtime' >&2
fi

echo 'Platform preflight: OK'
