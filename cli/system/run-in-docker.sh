#!/usr/bin/env bash
# Універсальний запуск скрипта: з хоста → через docker exec, з контейнера → напряму.
#
# Використання з хоста:
#   ./run-in-docker.sh <script.sh> [args...]
#
# Використання з контейнера:
#   bash <script.sh> [args...]
#
# Привʼязка до конкретного контейнера задається змінними, а не кодом · набір
# скриптів має працювати і з іншим проєктом:
#   TRANSLATE_DOCKER_CONTAINER  імʼя контейнера з PHP
#   TRANSLATE_DOCKER_WORKDIR    куди копіювати набір усередині контейнера
#   TRANSLATE_CONTAINER_MARKER  файл, наявність якого означає «ми вже в контейнері»
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

CONTAINER="${TRANSLATE_DOCKER_CONTAINER:-bdo_ua_translate-php-fpm}"
# Свідомо НЕ шлях усередині bind-mount проєкту: `docker cp` туди писав би прямо
# в робоче дерево проєкту на хості й відтворював би там каталог набору, який
# звідти навмисно прибрано. Скретч-каталог контейнера нікуди не «протікає».
WORK_DIR="${TRANSLATE_DOCKER_WORKDIR:-/tmp/bdo-ua-ai-localization}"
MARKER="${TRANSLATE_CONTAINER_MARKER:-/www/bdo_ua_translate/public/.env}"

# Якщо ми вже в контейнері — запускаємо напряму. Ключ не має fallback у коді:
# його передає .env або середовище виконання.
if [ -f "$MARKER" ]; then
    exec bash "$@"
fi

echo "Запуск у контейнері $CONTAINER..."
docker exec -i "$CONTAINER" mkdir -p "$WORK_DIR"
docker cp "$SCRIPT_DIR/." "$CONTAINER:$WORK_DIR/"
# `docker cp` переносить UID/GID хоста, і всередині контейнера (www-data, uid
# 1000) файли можуть виявитись недоступними · саме так падав `.env` з ключем.
# Право власності віддаємо тому, хто реально виконує скрипт.
docker exec -u root "$CONTAINER" chown -R "$(docker exec "$CONTAINER" id -u):$(docker exec "$CONTAINER" id -g)" "$WORK_DIR"
docker exec -i "$CONTAINER" bash -c 'cd "$1" && exec bash "${@:2}"' -- "$WORK_DIR" "$@"
