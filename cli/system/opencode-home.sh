#!/usr/bin/env bash
# Знайти дані самого OpenCode: базу сесій і користувацький конфіг.
#
# Цей файл призначений для `source`, не для запуску. Експортує:
#   OPENCODE_DB       шлях до opencode.db (порожньо, якщо не знайдено)
#   OPENCODE_CONFIG   шлях до opencode.jsonc|json (порожньо, якщо не знайдено)
#   OPENCODE_TRIED    перелік перевірених шляхів для повідомлення про помилку
#
# Навіщо окремий резолвер, а не сталий `$HOME/.local/share/opencode`.
#
# На Windows підтримуваний режим · WSL-міст: OpenCode працює як native
# Windows-застосунок, а `./bdo` виконується всередині WSL2. Тоді `$HOME` тут це
# `/home/<user>` у Linux, а OpenCode пише свої дані в профіль Windows-користувача,
# тобто в інший бік межі. Через це `./bdo audit`, `./bdo audit-dump` і
# `./bdo models` шукали базу там, де її ніколи не буде, і падали з
# «Немає бази OpenCode» на здоровій системі. Аудит при цьому є ЄДИНИМ джерелом
# правди про субагентів, тому мовчазна деградація тут неприпустима.
#
# Розкладка OpenCode на Windows не є частиною контракту цього проєкту, тому шлях
# не вгадується з однієї константи: перевіряються всі відомі варіанти, а
# `BDO_OPENCODE_HOME` у `.env` дозволяє назвати домівку явно, наприклад
# `BDO_OPENCODE_HOME=/mnt/c/Users/mogil`.

# Домівка OpenCode: змінна оточення, потім `.env`, потім `$HOME`.
#
# `.env` читається grep-ом, а не `source`: аудит не має вимагати ні ключів API,
# ні зафіксованої цілі прогону, інакше діагностика стає недоступною саме тоді,
# коли вона потрібна.
_opencode_home() {
    if [ -n "${BDO_OPENCODE_HOME:-}" ]; then printf '%s\n' "$BDO_OPENCODE_HOME"; return; fi
    local root env_file value
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    env_file="${TRANSLATE_ENV_FILE:-$root/.env}"
    if [ -f "$env_file" ]; then
        value="$(sed -n 's/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}BDO_OPENCODE_HOME[[:space:]]*=[[:space:]]*//p' "$env_file" | tail -1)"
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value#\"}"; value="${value%\"}"
        value="${value#\'}"; value="${value%\'}"
        if [ -n "$value" ]; then printf '%s\n' "$value"; return; fi
    fi
    printf '%s\n' "$HOME"
}

OPENCODE_HOME="$(_opencode_home)"
OPENCODE_DB=""
OPENCODE_CONFIG=""
OPENCODE_TRIED=""

for _candidate in \
    "$OPENCODE_HOME/.local/share/opencode/opencode.db" \
    "$OPENCODE_HOME/AppData/Local/opencode/opencode.db" \
    "$OPENCODE_HOME/AppData/Roaming/opencode/opencode.db"; do
    OPENCODE_TRIED="$OPENCODE_TRIED$_candidate
"
    if [ -z "$OPENCODE_DB" ] && [ -f "$_candidate" ]; then OPENCODE_DB="$_candidate"; fi
done

for _candidate in \
    "$OPENCODE_HOME/.config/opencode/opencode.jsonc" \
    "$OPENCODE_HOME/.config/opencode/opencode.json" \
    "$OPENCODE_HOME/AppData/Roaming/opencode/opencode.jsonc" \
    "$OPENCODE_HOME/AppData/Roaming/opencode/opencode.json"; do
    if [ -z "$OPENCODE_CONFIG" ] && [ -f "$_candidate" ]; then OPENCODE_CONFIG="$_candidate"; fi
done
unset _candidate

export OPENCODE_HOME OPENCODE_DB OPENCODE_CONFIG OPENCODE_TRIED
