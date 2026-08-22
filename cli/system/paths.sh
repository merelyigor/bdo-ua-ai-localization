#!/usr/bin/env bash
# Єдина точка, де набір скриптів вирішує, ДЕ лежать промпти субагентів, конфіг
# OpenCode і проєкт, який цей набір обслуговує.
#
#   source "$SCRIPT_DIR/cli/system/paths.sh"   # у скрипті
#   ./cli/system/paths.sh                      # показати, що куди вирішилось
#
# Навіщо. Раніше кожен скрипт писав "$SCRIPT_DIR/../.opencode/...", тобто
# жорстко вимагав лежати підкаталогом одного конкретного проєкту. Перенести
# набір в окремий репозиторій було неможливо без правки шести скриптів. Тут ці
# шляхи розвʼязані: спочатку змінна оточення, потім автопошук у двох місцях -
# поруч із набором (окремий репозиторій) і на рівень вище (підкаталог проєкту).
# Той самий код працює в обох розкладках, і жодна зі змінних не обовʼязкова.
#
# Змінні (кожна перебиває автопошук):
#   TRANSLATE_AGENTS_DIR       каталог із translation-*.md (промпти субагентів)
#   TRANSLATE_OPENCODE_CONFIG  opencode.json з .agent[...].model
#   TRANSLATE_AGENT_VALIDATOR  validate-translation-agents.sh
#   TRANSLATE_PROJECT_ROOT     корінь обслуговуваного проєкту (API, docs, artisan)
#
# Джерела значень за силою: оточення процесу > `.env` > автопошук. `.env`
# читається саме тут, бо інакше рядок `TRANSLATE_PROJECT_ROOT=...` у ньому не
# діяв би: `cli/system/select-env.sh` бере з файла лише ключі API, і людина, яка задала
# змінну «як у прикладі», не мала б жодного натяку, чому нічого не змінилось.
#
# Порожня змінна - не аварія: скрипт, якому шлях справді потрібен, падає сам із
# назвою відсутнього шляху. Скриптам, що працюють лише з API, ці шляхи не треба.

TRANSLATE_HOME="${TRANSLATE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# З `.env` беремо ТІЛЬКИ TRANSLATE_*: ключі API - справа cli/system/select-env.sh, і
# сторонні присвоєння з файла тут нічого змінювати не мусять. Файл не
# виконується (`source`), а розбирається построково, тому команда в ньому не
# запуститься.
_translate_env_file="${TRANSLATE_ENV_FILE:-$TRANSLATE_HOME/.env}"
if [ -f "$_translate_env_file" ]; then
    while IFS= read -r _translate_line || [ -n "$_translate_line" ]; do
        case "$_translate_line" in
            TRANSLATE_*=*) ;;
            *) continue ;;
        esac
        _translate_key="${_translate_line%%=*}"
        _translate_val="${_translate_line#*=}"
        # Знімаємо оточуючі лапки, якщо їх поставили.
        case "$_translate_val" in
            \"*\") _translate_val="${_translate_val#\"}"; _translate_val="${_translate_val%\"}" ;;
            \'*\') _translate_val="${_translate_val#\'}"; _translate_val="${_translate_val%\'}" ;;
        esac
        if [ -z "${!_translate_key:-}" ]; then
            printf -v "$_translate_key" '%s' "$_translate_val"
        fi
    done < "$_translate_env_file"
    unset _translate_line _translate_key _translate_val
fi
unset _translate_env_file

if [ -z "${TRANSLATE_AGENTS_DIR:-}" ]; then
    TRANSLATE_AGENTS_DIR=""
    for _translate_candidate in \
        "$TRANSLATE_HOME/.opencode/agents" \
        "$TRANSLATE_HOME/../.opencode/agents"
    do
        if [ -d "$_translate_candidate" ]; then
            TRANSLATE_AGENTS_DIR="$(cd "$_translate_candidate" && pwd)"
            break
        fi
    done
    unset _translate_candidate
fi

if [ -z "${TRANSLATE_OPENCODE_CONFIG:-}" ]; then
    TRANSLATE_OPENCODE_CONFIG=""
    for _translate_candidate in \
        "$TRANSLATE_HOME/opencode.json" \
        "$TRANSLATE_HOME/../opencode.json"
    do
        if [ -f "$_translate_candidate" ]; then
            TRANSLATE_OPENCODE_CONFIG="$(cd "$(dirname "$_translate_candidate")" && pwd)/$(basename "$_translate_candidate")"
            break
        fi
    done
    unset _translate_candidate
fi

# Валідатор живе поруч із каталогом агентів: він частина того самого .opencode/.
if [ -z "${TRANSLATE_AGENT_VALIDATOR:-}" ]; then
    TRANSLATE_AGENT_VALIDATOR=""
    if [ -n "$TRANSLATE_AGENTS_DIR" ]; then
        _translate_candidate="$(dirname "$TRANSLATE_AGENTS_DIR")/validate-translation-agents.sh"
        if [ -f "$_translate_candidate" ]; then
            TRANSLATE_AGENT_VALIDATOR="$_translate_candidate"
        fi
        unset _translate_candidate
    fi
fi

# Обслуговуваний проєкт шукається за маркером `artisan`, а не за "рівнем вище":
# після переносу набору в окремий репозиторій рівень вище - це папка з усіма
# репозиторіями, і сліпий ".." вказував би в пусте місце.
if [ -z "${TRANSLATE_PROJECT_ROOT:-}" ]; then
    TRANSLATE_PROJECT_ROOT=""
    if [ -f "$TRANSLATE_HOME/../artisan" ]; then
        TRANSLATE_PROJECT_ROOT="$(cd "$TRANSLATE_HOME/.." && pwd)"
    fi
fi

export TRANSLATE_HOME TRANSLATE_AGENTS_DIR TRANSLATE_OPENCODE_CONFIG
export TRANSLATE_AGENT_VALIDATOR TRANSLATE_PROJECT_ROOT

# Перевірити один вирішений шлях перед використанням.
#   translate_require_path <змінна> <опис> <шлях>
translate_require_path() {
    if [ -n "${3:-}" ] && [ -e "$3" ]; then
        return 0
    fi
    if [ -z "${3:-}" ]; then
        printf 'Не знайдено %s: автопошук не дав результату.\n' "$2" >&2
    else
        printf 'Не знайдено %s: %s\n' "$2" "$3" >&2
    fi
    printf 'Задай %s або перевір розкладку: %s/cli/system/paths.sh\n' "$1" "$TRANSLATE_HOME" >&2
    return 1
}

# Прямий запуск - звіт про розкладку. Використовується при переносі набору.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    _translate_status=0
    printf '%-26s %s\n' 'TRANSLATE_HOME' "$TRANSLATE_HOME"
    for _translate_var in \
        TRANSLATE_AGENTS_DIR \
        TRANSLATE_OPENCODE_CONFIG \
        TRANSLATE_AGENT_VALIDATOR \
        TRANSLATE_PROJECT_ROOT
    do
        _translate_value="${!_translate_var}"
        if [ -z "$_translate_value" ]; then
            printf '%-26s НЕ ЗНАЙДЕНО\n' "$_translate_var"
            _translate_status=1
        elif [ -e "$_translate_value" ]; then
            printf '%-26s %s\n' "$_translate_var" "$_translate_value"
        else
            printf '%-26s %s (НЕМАЄ НА ДИСКУ)\n' "$_translate_var" "$_translate_value"
            _translate_status=1
        fi
    done
    if [ "$_translate_status" -ne 0 ]; then
        printf '\nЩось не вирішилось. Задай відповідну змінну в .env або в оточенні.\n' >&2
    fi
    exit "$_translate_status"
fi
