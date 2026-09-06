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
# Чому база production за замовчуванням НЕ в `.env`. Адреса production API · публічна константа, яка не
# змінюється: тримати її в конфізі кожного користувача означає розмножити
# незмінне значення по копіях, де воно тихо розійдеться від описки або старого
# `.env`, і жодна перевірка цього не побачить. Тому вона тут, у коді, в одному
# місці. У `.env` лишається тільки те, що справді різне: ключі.
#
# Ціль перемикається ОДНИМ рядком (`BDO_ENV`), а не правкою URL · саме через це
# попередня форма з єдиним `BDO_API_BASE` була незручною: щоб піти в прод, треба
# було редагувати адресу, хоча адреси незмінні.
#
# Для BDO UA DEV адресу задають через `BDO_API_BASE_DEV`. DEV/self-hosted адреси
# лишаються локальними й не повинні
# потрапляти в tracked files.
#
# Перебивання, коли потрібно (self-hosting, дзеркало, локальний стенд):
#   BDO_API_BASE_PROD=...    замінити адресу production
# Застарілий `BDO_API_BASE` не використовується: інакше DEV URL тихо перемагає
# `BDO_ENV=PROD`, що робить єдиний перемикач середовища неправдивим.
#
# ДРУГА ВІСЬ: ЯКИЙ САМЕ БЕКЕНД.
#
#   BDO_API_TARGET=legacy   Agent API проєкту BDO UA (типово)
#   BDO_API_TARGET=hub      Agent API хаба локалізацій (`/api/bdo/agent/v1`)
#
# Навіщо дві осі, а не одна. `BDO_ENV` каже КУДИ (прод чи розробка), а
# `BDO_API_TARGET` · ЯКИЙ бекенд. Це справді незалежні питання: хаб має і свій
# прод, і свою розробку, і жодне з чотирьох поєднань не є безглуздим.
#
# Ключі НЕ переносяться між бекендами (у старому вони з префіксом `bdo_`, у
# хабі · `hub_`, і видані окремо), тому кожен бекенд має свою пару:
#
#   BDO_API_KEY_PROD / BDO_API_KEY_DEV      ключі старого API
#   HUB_API_KEY_PROD / HUB_API_KEY_DEV      ключі хаба
#   HUB_API_BASE_PROD / HUB_API_BASE_DEV    адреси хаба (вбудованої немає)
#
# Чому в хаба немає вбудованої адреси, а в старого API є. Адреса BDO UA ·
# публічна константа, яка не змінюється. Хаб ЩЕ в розробці: його домен поки
# змінюється, і зашитий default тихо розійшовся б із дійсністю. Коли він
# стане сталим, він переїде сюди тим самим рядком.
#
# Експортує: BDO_ENV (PROD|DEV), BDO_API_TARGET (legacy|hub),
# BDO_API_ENV (prod|local|hub-prod|hub-local · внутрішня назва цілі, яка йде у
# `state/run-target` і `write-log.jsonl`), BDO_API_BASE, BDO_API_KEY.
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

# Бекенд · так само одне слово, і так само з поблажливістю до написання.
# `bdo` приймається як синонім `legacy`: саме так власник називає старий проєкт.
_normalize_target() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        ''|legacy|bdo|old) printf 'legacy' ;;
        hub|new) printf 'hub' ;;
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

# Бекенд · друга вісь, незалежна від середовища.
if ! _resolved_target="$(_normalize_target "${BDO_API_TARGET:-}")"; then
    echo "BDO_API_TARGET має бути legacy або hub, а в $ENV_FILE стоїть '${BDO_API_TARGET}'." >&2
    exit 1
fi
BDO_API_TARGET="$_resolved_target"
unset _resolved_target

# База й ключ визначаються ПАРОЮ «бекенд + середовище». Жодного змішування:
# ключ хаба не підходить старому API й навпаки, тому запасних варіантів на
# кшталт «якщо немає, візьми сусідній» тут немає навмисно · тихо піти не в той
# бекенд гірше, ніж зупинитись із назвою відсутньої змінної.
if [ "$BDO_API_TARGET" = hub ]; then
    if [ "$BDO_ENV" = PROD ]; then
        BDO_API_BASE="${HUB_API_BASE_PROD:-}"; _base_name='HUB_API_BASE_PROD'
        BDO_API_KEY="${HUB_API_KEY_PROD:-}";   _key_name='HUB_API_KEY_PROD'
    else
        BDO_API_BASE="${HUB_API_BASE_DEV:-}";  _base_name='HUB_API_BASE_DEV'
        BDO_API_KEY="${HUB_API_KEY_DEV:-}";    _key_name='HUB_API_KEY_DEV'
    fi
    if [ -z "$BDO_API_BASE" ]; then
        echo "BDO_API_TARGET=hub і BDO_ENV=$BDO_ENV, але $_base_name не заданий у $ENV_FILE." >&2
        echo "Хаб ще в розробці, тому вбудованої адреси в нього немає: у ній має бути" >&2
        echo "slug гри, наприклад https://<домен>/api/bdo/agent/v1." >&2
        exit 1
    fi
else
    if [ "$BDO_ENV" = PROD ]; then
        BDO_API_BASE="${BDO_API_BASE_PROD:-$BDO_API_BASE_PROD_DEFAULT}"
        BDO_API_KEY="${BDO_API_KEY_PROD:-${BDO_API_KEY:-}}"; _key_name='BDO_API_KEY_PROD'
    else
        BDO_API_BASE="${BDO_API_BASE_DEV:-}"
        BDO_API_KEY="${BDO_API_KEY_DEV:-${BDO_API_KEY:-}}";  _key_name='BDO_API_KEY_DEV'
        if [ -z "$BDO_API_BASE" ]; then
            echo "BDO_ENV=DEV, але BDO_API_BASE_DEV не заданий у $ENV_FILE." >&2
            echo "DEV · приватне середовище розробки проєкту, тому його адреса живе лише" >&2
            echo "у вашому .env і не входить у публічний репозиторій. Задайте її або" >&2
            echo "поставте BDO_ENV=PROD." >&2
            exit 1
        fi
    fi
fi
if [ -z "$BDO_API_KEY" ]; then
    echo "Немає ключа для BDO_API_TARGET=$BDO_API_TARGET і BDO_ENV=$BDO_ENV:" >&2
    echo "задайте $_key_name у $ENV_FILE." >&2
    exit 1
fi
unset _key_name
unset _base_name 2>/dev/null || true

# Розбіжність файла й префікса · помилка, а не тихе перемикання. Саме цей клас
# помилок робив прогін половинчастим: частина пачок в одному середовищі,
# частина в іншому, і жоден вивід про це не попереджав.

# Внутрішня назва для скриптів стану (`cli/run/run-start.sh`, `cli/batch/batch-commit.sh`,
# журнали записів). Навмисно лишається `local`/`prod`: це формат, у якому вже
# записані зафіксовані цілі прогонів і рядки `write-log.jsonl`.
case "$BDO_ENV" in
    PROD) BDO_API_ENV=prod ;;
    *)    BDO_API_ENV=local ;;
esac
# Бекенд входить у ту саму назву цілі, і це не косметика. Саме цим рядком
# `state/run-target` замикає прогін, `batch-commit.sh` звіряє кожну пачку, а
# `write-log.jsonl` назавжди фіксує, КУДИ саме поїхав рядок. Поки обидва API
# живі паралельно, питання «де цей переклад» без цього поля не має відповіді.
# Старі значення (`prod`, `local`) лишились незмінними, тому вже записані
# журнали й зафіксовані цілі читаються далі.
test "$BDO_API_TARGET" = hub && BDO_API_ENV="hub-$BDO_API_ENV"

if [ -n "$_env_from_shell" ]; then
    # Порівнюємо ПОВНУ назву цілі (`prod`, `local`, `hub-prod`, `hub-local`):
    # з появою другої осі окремої перевірки середовища вже мало, бо `prod` і
    # `hub-prod` є різними цілями при однаковому `BDO_ENV`.
    if [ "$_env_from_shell" != "$BDO_API_ENV" ]; then
        echo "Конфлікт цілі: файл $ENV_FILE дає '$BDO_API_ENV' (BDO_ENV=$BDO_ENV, BDO_API_TARGET=$BDO_API_TARGET)," >&2
        echo "а в команді BDO_API_ENV='$_env_from_shell'." >&2
        echo "Ціль задається одним місцем · файлом. Прибери префікс або зміни .env." >&2
        exit 1
    fi
fi
unset _env_from_shell

export BDO_ENV BDO_API_TARGET BDO_API_ENV BDO_API_BASE BDO_API_KEY
if [ "$BDO_API_TARGET" = hub ]; then
    echo "Ціль: ХАБ $BDO_ENV ($BDO_API_BASE)" >&2
else
    echo "Ціль: $BDO_ENV ($BDO_API_BASE)" >&2
fi

# ДРУГИЙ БЕКЕНД ІСНУЄ, І ПРО НЬОГО ТРЕБА ЗНАТИ.
#
# Змінні хаба живуть у `.env.example`, а у власника в `.env` їх немає взагалі ·
# і він не бачив, куди їх вписувати (сказав це 2026-09-06). Мовчання тут гірше
# за один рядок: можливість, про яку не сказано, дорівнює відсутній.
#
# Підказка друкується ЛИШЕ коли `BDO_API_TARGET` не заданий у файлі, тобто
# рівно раз для тих, хто про хаб ще не знає. Задав · більше не турбуємо.
if [ -z "${BDO_API_TARGET_FROM_FILE:-}" ] && ! grep -q '^[[:space:]]*BDO_API_TARGET=' "$ENV_FILE" 2>/dev/null; then
    echo "Є другий бекенд · хаб локалізацій. Щоб перемкнутись, додай у $ENV_FILE:" >&2
    echo "  BDO_API_TARGET=hub          (legacy · старий API BDO UA, типово)" >&2
    echo "  HUB_API_BASE_PROD=https://<домен>/api/bdo/agent/v1" >&2
    echo "  HUB_API_KEY_PROD=hub_..." >&2
    echo "  HUB_API_BASE_DEV / HUB_API_KEY_DEV · те саме для BDO_ENV=DEV" >&2
    echo "Що вміє вибрана ціль: ./bdo capabilities" >&2
fi
