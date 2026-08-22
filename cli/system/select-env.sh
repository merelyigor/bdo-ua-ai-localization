#!/usr/bin/env bash
# Єдине місце, де вирішується, у ЯКЕ середовище йде цей запуск.
#
# Ціль задає ОДНА константа в `.env`:
#
#   BDO_ENV=PROD    production API
#   BDO_ENV=DEV     середовище розробки самого проєкту
#
# Далі `.env` тримає ЛИШЕ КЛЮЧІ · те, що є секретом і в кожного своє:
#
#   BDO_API_KEY_PROD=...
#   BDO_API_KEY_DEV=...      (потрібен лише тим, хто розробляє сам проєкт)
#
# Чому база НЕ в `.env`. Адреса production API · публічна константа, яка не
# змінюється: тримати її в конфізі кожного користувача означає розмножити
# незмінне значення по копіях, де воно тихо розійдеться від описки або старого
# `.env`, і жодна перевірка цього не побачить. Тому вона тут, у коді, в одному
# місці. У `.env` лишається тільки те, що справді різне: ключі.
#
# Ціль перемикається ОДНИМ рядком (`BDO_ENV`), а не правкою URL · саме через це
# попередня форма з єдиним `BDO_API_BASE` була незручною: щоб піти в прод, треба
# було редагувати адресу, хоча адреси незмінні.
#
# DEV-база свідомо НЕ має дефолта в коді: це приватна інфраструктура власника, а
# репозиторій публічний (§2 · приватні URL не потрапляють у tracked files). Тому
# `BDO_ENV=DEV` вимагає `BDO_API_BASE_DEV` у приватному `.env`.
#
# Перебивання, коли потрібно (self-hosting, дзеркало, локальний стенд):
#   BDO_API_BASE_PROD=...    замінити адресу production
#   BDO_API_BASE=...         задати адресу напряму, незалежно від BDO_ENV
#
# Експортує: BDO_ENV (PROD|DEV), BDO_API_ENV (prod|local · внутрішня назва для
# скриптів стану), BDO_API_BASE, BDO_API_KEY.
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Публічна адреса Agent API. Єдине місце, де вона записана.
readonly BDO_API_BASE_PROD_DEFAULT='https://bdo-ua.com.ua/api/agent/v1'

# Файл із ключами лежить поруч із набором скриптів; TRANSLATE_ENV_FILE дозволяє
# тримати його поза репозиторієм. Без цієї перевірки відсутній .env давав голе
# «No such file or directory» без підказки, що робити.
ENV_FILE="${TRANSLATE_ENV_FILE:-$SCRIPT_DIR/.env}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Немає файлу з ключами: $ENV_FILE" >&2
    echo "Скопіюй .env.example у .env і впиши BDO_ENV та ключ." >&2
    exit 1
fi
# Префікс із оточення має бути видимий ДО читання файла: інакше не відрізнити
# «власник задав ціль командою» від «ціль прийшла з файла».
_env_from_shell="${BDO_API_ENV:-}"
# shellcheck disable=SC1090
source "$ENV_FILE"

# Нормалізація людського написання у два внутрішні значення. `local` і
# `localhost` приймаються, бо так називалась ціль до цієї зміни, і стара звичка
# не має ламати запуск.
_normalize_env() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        prod|production) printf 'PROD' ;;
        dev|local|localhost|development) printf 'DEV' ;;
        *) return 1 ;;
    esac
}

if [ -z "${BDO_ENV:-}" ]; then
    echo "У $ENV_FILE не задано BDO_ENV. Дозволено PROD або DEV." >&2
    echo "Зразок · .env.example" >&2
    exit 1
fi
if ! _resolved="$(_normalize_env "$BDO_ENV")"; then
    echo "BDO_ENV має бути PROD або DEV, а в $ENV_FILE стоїть '$BDO_ENV'." >&2
    exit 1
fi
BDO_ENV="$_resolved"
unset _resolved

# Успадковані імена з першої версії набору. Приймаються як DEV-аліаси, щоб
# старий `.env` не зламався; нові імена мають пріоритет.
: "${BDO_API_BASE_DEV:=${BDO_API_BASE_LOCALHOST:-}}"
: "${BDO_API_KEY_DEV:=${BDO_API_KEY_LOCALHOST:-}}"

# База: явне перебивання -> перебивання для цього середовища -> дефолт у коді.
if [ -n "${BDO_API_BASE:-}" ]; then
    :
elif [ "$BDO_ENV" = PROD ]; then
    BDO_API_BASE="${BDO_API_BASE_PROD:-$BDO_API_BASE_PROD_DEFAULT}"
else
    BDO_API_BASE="${BDO_API_BASE_DEV:-}"
    if [ -z "$BDO_API_BASE" ]; then
        echo "BDO_ENV=DEV, але BDO_API_BASE_DEV не заданий у $ENV_FILE." >&2
        echo "DEV · приватне середовище розробки проєкту, тому його адреса живе лише" >&2
        echo "у вашому .env і не входить у публічний репозиторій. Задайте її або" >&2
        echo "поставте BDO_ENV=PROD." >&2
        exit 1
    fi
fi

# Ключ: свій для середовища -> спільний скорочений запис.
if [ "$BDO_ENV" = PROD ]; then
    BDO_API_KEY="${BDO_API_KEY_PROD:-${BDO_API_KEY:-}}"
    _key_name='BDO_API_KEY_PROD'
else
    BDO_API_KEY="${BDO_API_KEY_DEV:-${BDO_API_KEY:-}}"
    _key_name='BDO_API_KEY_DEV'
fi
if [ -z "$BDO_API_KEY" ]; then
    echo "Немає ключа для BDO_ENV=$BDO_ENV: задайте $_key_name у $ENV_FILE." >&2
    exit 1
fi
unset _key_name

# Розбіжність файла й префікса · помилка, а не тихе перемикання. Саме цей клас
# помилок робив прогін половинчастим: частина пачок в одному середовищі,
# частина в іншому, і жоден вивід про це не попереджав.
if [ -n "$_env_from_shell" ]; then
    if ! _shell_target="$(_normalize_env "$_env_from_shell")"; then
        echo "Невідоме BDO_API_ENV='$_env_from_shell'. Дозволено: prod або dev." >&2
        exit 1
    fi
    if [ "$_shell_target" != "$BDO_ENV" ]; then
        echo "Конфлікт цілі: у $ENV_FILE BDO_ENV=$BDO_ENV, а в команді BDO_API_ENV=$_env_from_shell." >&2
        echo "Ціль задається одним місцем · файлом. Прибери префікс або зміни BDO_ENV." >&2
        exit 1
    fi
    unset _shell_target
fi
unset _env_from_shell

# Внутрішня назва для скриптів стану (`cli/run/run-start.sh`, `cli/batch/batch-commit.sh`,
# журнали записів). Навмисно лишається `local`/`prod`: це формат, у якому вже
# записані зафіксовані цілі прогонів і рядки `write-log.jsonl`.
case "$BDO_ENV" in
    PROD) BDO_API_ENV=prod ;;
    *)    BDO_API_ENV=local ;;
esac

export BDO_ENV BDO_API_ENV BDO_API_BASE BDO_API_KEY
echo "Ціль: $BDO_ENV ($BDO_API_BASE)" >&2
