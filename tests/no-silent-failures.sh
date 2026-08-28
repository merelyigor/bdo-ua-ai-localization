#!/usr/bin/env bash
# Жоден крок рушія не має права впасти БЕЗ тексту.
#
# 2026-08-25 диригент двадцять команд поспіль не міг ні продовжити пачку, ні
# почати нову. Причина була не в логіці флоу, а в мовчанні: `mode start` і
# `run drive` виходили з ненульовим кодом і порожнім stdout. Промпт диригента
# на порожній вивід зобовʼязаний зупинитись, тому сесія ходила по колу, і жодна
# з двадцяти команд не назвала причину.
#
# Тест закриває саме цей клас: два найчастіші виходи мусять друкувати JSON.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-silence.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

json_field() {
    php -r '$d=json_decode(stream_get_contents(STDIN),true);echo is_array($d)?($d[$argv[1]]??""):"";' "$1"
}

# 1. `run drive` без поточної пачки.
out="$(BDO_STATE_DIR="$TMP/state" bash cli/run/run-drive.sh 2>/dev/null || true)"
test -n "$out" || { echo 'FAIL: run drive без пачки нічого не надрукував' >&2; exit 1; }
state="$(printf '%s' "$out" | json_field state)"
test "$state" = no_batch || { echo "FAIL: очікували state=no_batch, отримали '$state' у: $out" >&2; exit 1; }
printf '%s' "$out" | grep -Fq 'mode start' \
    || { echo 'FAIL: envelope no_batch не підказує, як почати пачку' >&2; exit 1; }

# 2. `mode start` із розміром поза дозволеним діапазоном.
#
# Перевірка розміру в `fetch-rows.sh` спрацьовує ДО мережі, тому тест офлайновий
# і не залежить ні від ключа, ні від доступності API.
cat > "$TMP/.env" <<'ENV'
BDO_ENV=DEV
BDO_API_KEY_DEV=test-key-not-a-secret
BDO_API_BASE_DEV=http://127.0.0.1:9/api/agent/v1
ENV
out="$(TRANSLATE_ENV_FILE="$TMP/.env" BDO_STATE_DIR="$TMP/state" bash cli/run/run-mode.sh patch 15 2 2>/dev/null | tail -1 || true)"
reason="$(printf '%s' "$out" | json_field reason)"
test "$reason" = fetch_failed || { echo "FAIL: очікували reason=fetch_failed, отримали '$reason' у: $out" >&2; exit 1; }
printf '%s' "$out" | grep -Fq 'detail' \
    || { echo 'FAIL: fetch_failed не передає detail, причина знову невидима' >&2; exit 1; }

# 3. `./bdo batch check` без аргументу відповідає на питання, а не сипле bash.
#
# 2026-08-28 диригент виконав документовану команду під час розбору й отримав
# `batch-assert.sh: line 15: 1: Потрібен rows.json` · номер рядка чужого скрипта
# замість «файли пачки свої / пачки немає». Причина мусить бути читабельною
# навіть у діагностичній команді, інакше агент переказує власнику «сталася
# помилка».
out="$(BDO_STATE_DIR="$TMP/state" bash cli/batch/batch-assert.sh 2>&1 || true)"
printf '%s' "$out" | grep -Fq 'ПОМИЛКА: пачку не розпочато' \
    || { echo "FAIL: batch check без пачки не назвав причину: $out" >&2; exit 1; }
printf '%s' "$out" | grep -Fqv 'line ' \
    || { echo "FAIL: у виводі лишилось сире посилання на рядок скрипта: $out" >&2; exit 1; }


echo 'no silent failures: OK'
