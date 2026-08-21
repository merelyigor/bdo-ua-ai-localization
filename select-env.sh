#!/usr/bin/env bash
# Єдине місце, де вирішується, у ЯКЕ середовище йде цей запуск.
#
# Ціль задає ОДНА константа в `.env`:
#
#   BDO_ENV=DEV     локальний API, читання і запис
#   BDO_ENV=PROD    production API, читання і запис
#
# Поруч із нею · один ключ і один URL, які до цієї цілі й належать:
#
#   BDO_API_BASE=https://.../api/agent/v1
#   BDO_API_KEY=...
#
# Навіщо саме так. Раніше в `.env` лежали дві пари (`_LOCALHOST` і `_PROD`), а
# ціль обиралась префіксом `BDO_API_ENV=` перед кожною командою. Це означало, що
# кожен промпт мусив ПОЯСНЮВАТИ агентові, куди він зараз пише, і будь-яка
# забута команда їхала в інше середовище, ніж решта прогону. Тепер ціль
# оголошена один раз у файлі, і агент її не обирає · він її читає.
#
# Тому розбіжність між `.env` і змінною оточення тут не «перемога сильнішого», а
# помилка: якщо `BDO_ENV=DEV`, а хтось поставив префікс `BDO_API_ENV=prod`, ми
# падаємо з обома значеннями у тексті. Свідоме перемикання · це правка `.env`.
#
# Експортує: BDO_ENV (PROD|DEV), BDO_API_ENV (prod|local · внутрішня назва для
# скриптів стану), BDO_API_BASE, BDO_API_KEY.
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Файл із ключами лежить поруч із набором скриптів; TRANSLATE_ENV_FILE дозволяє
# тримати його поза репозиторієм. Без цієї перевірки відсутній .env давав голе
# «No such file or directory» без підказки, що робити.
ENV_FILE="${TRANSLATE_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Немає файлу з ключами: $ENV_FILE" >&2
    echo "Скопіюй .env.example у .env і впиши BDO_ENV, BDO_API_BASE, BDO_API_KEY." >&2
    exit 1
fi
# Префікс із оточення має бути видимий ДО читання файла: інакше не відрізнити
# «власник задав ціль командою» від «ціль прийшла з файла».
_env_from_shell="${BDO_API_ENV:-}"
# shellcheck disable=SC1090
source "$ENV_FILE"

# Нормалізація людського написання в два внутрішні значення. `local` і
# `localhost` приймаються, бо так називалась ціль до цієї зміни, і стара звичка
# не має ламати запуск.
_normalize_env() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        prod|production) printf 'PROD' ;;
        dev|local|localhost|development) printf 'DEV' ;;
        *) return 1 ;;
    esac
}

if [ -n "${BDO_ENV:-}" ]; then
    # --- Штатна форма: одна ціль, один ключ ---------------------------------
    if ! _resolved="$(_normalize_env "$BDO_ENV")"; then
        echo "BDO_ENV має бути PROD або DEV, а в $ENV_FILE стоїть '$BDO_ENV'." >&2
        exit 1
    fi
    BDO_ENV="$_resolved"
    BDO_API_BASE="${BDO_API_BASE:?BDO_API_BASE не заданий у $ENV_FILE}"
    BDO_API_KEY="${BDO_API_KEY:?BDO_API_KEY не заданий у $ENV_FILE}"
else
    # --- Сумісність зі старою формою: дві пари + префікс --------------------
    # Лишається робочою, щоб наявний `.env` не зламався в день переходу, але
    # кажемо про це один раз і прямо: одна ціль у файлі надійніша за префікс.
    _legacy_target="${_env_from_shell:-${BDO_API_ENV:-local}}"
    if ! _resolved="$(_normalize_env "$_legacy_target")"; then
        echo "Невідоме BDO_API_ENV='$_legacy_target'. Дозволено: prod або dev." >&2
        exit 1
    fi
    BDO_ENV="$_resolved"
    if [ "$BDO_ENV" = PROD ]; then
        BDO_API_BASE="${BDO_API_BASE_PROD:?BDO_API_BASE_PROD не заданий}"
        BDO_API_KEY="${BDO_API_KEY_PROD:?BDO_API_KEY_PROD не заданий}"
    else
        BDO_API_BASE="${BDO_API_BASE_LOCALHOST:?BDO_API_BASE_LOCALHOST не заданий}"
        BDO_API_KEY="${BDO_API_KEY_LOCALHOST:?BDO_API_KEY_LOCALHOST не заданий}"
    fi
    echo "Стара форма .env (дві пари ключів). Перейди на BDO_ENV + BDO_API_BASE + BDO_API_KEY · зразок у .env.example." >&2
    _env_from_shell=""
    unset _legacy_target
fi
unset _resolved

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

# Внутрішня назва для скриптів стану (`run-start.sh`, `batch-commit.sh`,
# журнали записів). Навмисно лишається `local`/`prod`: це формат, у якому вже
# записані зафіксовані цілі прогонів і рядки `write-log.jsonl`.
case "$BDO_ENV" in
    PROD) BDO_API_ENV=prod ;;
    *)    BDO_API_ENV=local ;;
esac

export BDO_ENV BDO_API_ENV BDO_API_BASE BDO_API_KEY
echo "Ціль: $BDO_ENV ($BDO_API_BASE)" >&2
