#!/usr/bin/env bash
# Чи може агент перевіряти сторінку в БРАУЗЕРІ ВЛАСНИКА · відповідь одним екраном.
#
#   ./bdo browser
#
# Навіщо. Візуальна перевірка знайшла три дефекти поспіль, яких не бачили ні
# тести, ні знімок DOM (D83, D93, D100), тому браузер власника є робочим
# інструментом, а не зручністю (§16). Але під'єднання до нього має ЧОТИРИ
# передумови, і коли бракує однієї, симптом однаковий: «інструментів немає».
# Перша ж сесія втратила на це десяток спроб · `curl` до `/json/version`
# віддавав 404, і причина була не в конфігу, а в самому Chrome.
#
# ЧОМУ `curl` ДО 9222 НЕ ПРАЦЮЄ Й НЕ МАЄ. Chrome 144+ (у власника 152) вмикає
# сервер зневадження через `chrome://inspect/#remote-debugging`, але HTTP-шлях
# `/json/*` лишає вимкненим: керування йде WebSocket-ом і вимагає ЯВНОГО
# дозволу «request full control» у самому браузері. Тому єдиний робочий шлях ·
# MCP `chrome-devtools` із `--autoConnect`, який це вміє. Порт, що слухає, тут
# є ОЗНАКОЮ ввімкненого сервера, а не каналом доступу.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SCRIPT_DIR
cd "$SCRIPT_DIR"

readonly PORT="${BDO_CDP_PORT:-9222}"
ok=0
bad=0

say() {   # <ознака> <текст>
    case "$1" in
        ok)   printf '  \033[32m+\033[0m %s\n' "$2"; ok=$((ok + 1)) ;;
        bad)  printf '  \033[31m-\033[0m %s\n' "$2"; bad=$((bad + 1)) ;;
        note) printf '    %s\n' "$2" ;;
    esac
}

printf 'Браузер власника як поверхня перевірки (§16)\n\n'

# 1. Конфіг MCP у ПРОЄКТІ. Без нього наступна сесія не побачить інструментів
#    узагалі, і жодні наступні умови не мають значення.
if [ -f .mcp.json ] && grep -Fq 'chrome-devtools-mcp' .mcp.json; then
    if grep -Fq -- '--autoConnect' .mcp.json; then
        say ok '.mcp.json: chrome-devtools із --autoConnect'
    else
        say bad '.mcp.json є, але без --autoConnect · MCP підійме СВІЙ Chrome із чистим профілем'
    fi
else
    say bad 'немає .mcp.json із chrome-devtools · агент не дістане браузер власника'
    say note 'лагодиться в репозиторії, не на машині'
fi

# 2. Сам сервер. `npx` тягне пакет на першому запуску, тому питаємо ЛОКАЛЬНИЙ
#    кеш: якщо його немає, перший виклик у сесії просто довго висітиме.
if command -v npx >/dev/null 2>&1; then
    say ok "npx є: $(command -v npx)"
else
    say bad 'немає npx · MCP-сервер не запуститься'
fi

# 3. Chrome і його версія. `--autoConnect` вимагає 144+.
chrome='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
if [ -x "$chrome" ]; then
    ver="$("$chrome" --version 2>/dev/null | sed -n 's/[^0-9]*\([0-9]\{1,4\}\).*/\1/p')"
    if [ -n "$ver" ] && [ "$ver" -ge 144 ]; then
        say ok "Chrome $ver · autoConnect підтримується"
    else
        say bad "Chrome ${ver:-невідомо} · autoConnect потребує 144+"
    fi
else
    say note 'Chrome не за типовим шляхом · перевір вручну (не помилка на Linux)'
fi

# 4. Сервер зневадження ВВІМКНЕНО. Це єдина умова, яку виконує ЛЮДИНА, і
#    єдина, яку не видно з конфігу: галочка живе в самому браузері.
if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    say ok "порт $PORT слухає · remote debugging увімкнено в Chrome"
    # HTTP-шлях перевіряємо НЕ щоб ним користуватись, а щоб наступна сесія не
    # витрачала спроби на `curl`, який тут завжди дає 404.
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://localhost:${PORT}/json/version" 2>/dev/null || echo 000)"
    if [ "$code" = 200 ]; then
        say note "HTTP /json/version віддає 200 · можна й --browserUrl http://127.0.0.1:$PORT"
    else
        say note "HTTP /json/version -> $code · це НОРМА для Chrome 144+; керування лише через MCP"
    fi
else
    say bad "порт $PORT не слухає · remote debugging вимкнено"
    say note 'власник: chrome://inspect/#remote-debugging -> «Allow remote debugging for this browser instance»'
fi

# 5. Що показувати в браузері. Без піднятого інтерфейсу перевіряти нема чого.
url="$(./bdo web --status 2>/dev/null | sed -n 's~.*\(http://127\.0\.0\.1:[0-9]*/?t=[0-9a-f]*\).*~\1~p' | head -1)"
if [ -n "$url" ]; then
    say ok 'інтерфейс піднятий'
    say note "$url"
else
    say bad 'інтерфейс не працює · відкривати в браузері нема чого'
    say note 'підіймається самим набором: ./bdo web --background'
fi

printf '\nГотово: %d, бракує: %d\n' "$ok" "$bad"
if [ "$bad" -gt 0 ]; then
    printf 'Перевіряти у вкладці власника ПОКИ НЕ МОЖНА · скажи це прямо й попроси те, чого бракує (§16.3).\n'
    exit 1
fi
printf 'Можна перевіряти у вкладці власника. Інструменти MCP зʼявляються після ПЕРЕЗАПУСКУ сесії агента.\n'
