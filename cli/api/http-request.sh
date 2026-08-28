#!/usr/bin/env bash
# Єдиний HTTP-клієнт BDO API.
#
# Тимчасова втрата мережі, HTTP 408/429 і 5xx повторюються з backoff. Загальний
# бюджет повторів — 10 хвилин; після його вичерпання curl повертає помилку й
# поточний прогін зупиняється штатним error path виклику.
#
# ПОСТІЙНІ помилки (400, 401, 403, 404) не повторюються ніколи.
#
# Раніше тут стояв `--retry-all-errors`, і це суперечило заголовку: відсутній
# маршрут або хибний параметр крутились ті самі 570 секунд. 2026-08-28 два
# запити до ще не розгорнутого `/glossary/terms/list` виглядали як зависання
# на дві хвилини замість «HTTP 404 за 0.2 с». Повтор має сенс лише там, де
# наступна спроба може дати інший результат; 404 іншого результату не дасть.
set -euo pipefail

readonly TOTAL_BUDGET_SECONDS=600
readonly ATTEMPT_TIMEOUT_SECONDS=30
readonly CONNECT_TIMEOUT_SECONDS=10
# curl може почати останню спробу безпосередньо перед завершенням retry-вікна.
# Віднімаємо її max-time, щоб уся операція, а не лише очікування між спробами,
# вкладалась у жорстку межу 600 секунд.
readonly RETRY_WINDOW_SECONDS=$((TOTAL_BUDGET_SECONDS - ATTEMPT_TIMEOUT_SECONDS))

exec curl \
    --retry 1000 \
    --retry-max-time "$RETRY_WINDOW_SECONDS" \
    --max-time "$ATTEMPT_TIMEOUT_SECONDS" \
    --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
    "$@"
