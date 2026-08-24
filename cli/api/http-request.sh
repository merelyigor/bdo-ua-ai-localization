#!/usr/bin/env bash
# Єдиний HTTP-клієнт BDO API.
#
# Тимчасова втрата мережі, HTTP 408/429 і 5xx повторюються з backoff. Загальний
# бюджет повторів — 10 хвилин; після його вичерпання curl повертає помилку й
# поточний прогін зупиняється штатним error path виклику.
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
    --retry-all-errors \
    --retry-max-time "$RETRY_WINDOW_SECONDS" \
    --max-time "$ATTEMPT_TIMEOUT_SECONDS" \
    --connect-timeout "$CONNECT_TIMEOUT_SECONDS" \
    "$@"
