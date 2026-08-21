#!/usr/bin/env bash
# Спільний вибір середовища для всіх API-скриптів.
# Використання: BDO_API_ENV=local|prod ./test-api.sh
set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Файл із ключами лежить поруч із набором скриптів; TRANSLATE_ENV_FILE дозволяє
# тримати його поза репозиторієм. Без цієї перевірки відсутній .env давав голе
# «No such file or directory» без підказки, що робити.
ENV_FILE="${TRANSLATE_ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Немає файлу з ключами: $ENV_FILE" >&2
    echo "Скопіюй .env.example у .env і впиши ключі, або задай TRANSLATE_ENV_FILE." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

BDO_API_ENV="${BDO_API_ENV:-local}"
case "$BDO_API_ENV" in
    local|localhost)
        BDO_API_ENV="local"
        BDO_API_BASE="${BDO_API_BASE_LOCALHOST:?BDO_API_BASE_LOCALHOST не заданий}"
        BDO_API_KEY="${BDO_API_KEY_LOCALHOST:?BDO_API_KEY_LOCALHOST не заданий}"
        ;;
    prod|production)
        BDO_API_ENV="prod"
        BDO_API_BASE="${BDO_API_BASE_PROD:?BDO_API_BASE_PROD не заданий}"
        BDO_API_KEY="${BDO_API_KEY_PROD:?BDO_API_KEY_PROD не заданий}"
        ;;
    *)
        echo "Невідоме BDO_API_ENV='$BDO_API_ENV'. Дозволено: local або prod." >&2
        exit 1
        ;;
esac

export BDO_API_ENV BDO_API_BASE BDO_API_KEY
echo "API environment: $BDO_API_ENV ($BDO_API_BASE)" >&2
