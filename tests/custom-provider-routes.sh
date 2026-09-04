#!/usr/bin/env bash
# Маршрут провайдера з ВЛАСНИМ endpoint мусить бути оголошений у конфізі
# OpenCode, і `.env.example` мусить лишатись копійовним.
#
# Клас дефекту той самий, що в `local-model-routes.sh`, але ширший за Ollama.
# OpenCode знає моделі `opencode/*` і `openai/*` зі своєї auth, тому їх у
# конфізі оголошувати не треба. А провайдер із `options.baseURL` · шлюз
# OmniRoute, локальний llama.cpp, будь-який сумісний endpoint · каталогу не
# має: неоголошений маршрут дає порожню дочірню сесію, нуль токенів і жодної
# помилки. До 2026-09-03 `./bdo models` друкував для таких маршрутів
# `ЗОВНІШНІЙ` і йшов далі, тобто сам звіт запевняв, що все гаразд.
#
# Друга перевірка · про `.env.example`. Це файл, який копіюють у `.env`, тому
# кожен його рядок поза коментарем є ЗНАЧЕННЯМ. 2026-09-03 там лежав рядок
# `TRANSLATE_MODEL=opencode/big-pickle, TRANSLATE_MODEL_COST=free.` · залишок
# речення, у якого загубився `#`. Копія такого шаблону задавала моделлю рядок
# зі комою й крапкою, і жоден gate цього не бачив.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TEMPLATE="$ROOT/.opencode/templates/translation-models.json"

# 1. `.env.example` не містить дубльованих присвоєнь одного ключа: два різних
#    значення одного ключа означають, що копія шаблону поводиться не так, як
#    описано вище по файлу.
duplicates="$(grep -E '^[A-Z_][A-Z0-9_]*=' "$ROOT/.env.example" | cut -d= -f1 | sort | uniq -d || true)"
test -z "$duplicates" || fail ".env.example двічі задає ключі: $(echo "$duplicates" | tr '\n' ' ')"

# 2. Значення моделі у шаблонах є ОДНИМ маршрутом `provider/model`, а не
#    уламком речення. Кома, пробіл або крапка тут · слід загубленого `#`.
for file in "$ROOT/.env.example" "$ROOT/.env.minimal.example"; do
    while IFS= read -r line; do
        value="${line#*=}"
        test -n "$value" || continue
        printf '%s' "$value" | grep -qE '^[^/[:space:],]+/[^[:space:],]+$' \
            || fail "$(basename "$file"): TRANSLATE_MODEL має бути один provider/model, маємо «$value»"
    done < <(grep -E '^TRANSLATE_MODEL=' "$file" || true)
done

# 3. Кожен маршрут кожного профілю або локальний, або належить провайдеру, який
#    цей набір уміє оголосити. Провайдер, про який не знає ні OpenCode, ні
#    `./bdo models --apply`, у профілі не має права зʼявитись.
routes="$(jq -r '[.profiles[] | (.routes, (.default_routes // {}))[][]] | unique[]' "$TEMPLATE")"
test -n "$routes" || fail "у шаблоні профілів немає жодного маршруту"
while IFS= read -r route; do
    printf '%s' "$route" | grep -qE '^[^/[:space:]]+/[^[:space:]]+$' \
        || fail "маршрут не у форматі provider/model: $route"
done <<< "$routes"

# 4. Головне: `sync-opencode-models.sh` мусить називати неоголошений маршрут
#    кастомного провайдера проблемою. Перевіряємо на ПІДРОБЛЕНОМУ конфізі, щоб
#    не залежати від того, що зараз стоїть у власника.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/opencode.jsonc" <<'JSON'
{
  "provider": {
    "custom-gateway": {
      "options": { "baseURL": "https://example.invalid/v1" },
      "models": {
        "auto/declared": { "name": "declared", "limit": { "context": 200000, "output": 64000 } },
        "auto/no-limit": { "name": "no-limit", "reasoning": true, "tool_call": true }
      }
    }
  }
}
JSON
HELPER="$ROOT/cli/runtime/custom-provider-models.php"
report="$(php "$HELPER" "$work/opencode.jsonc" \
    custom-gateway/auto/declared custom-gateway/auto/missing custom-gateway/auto/no-limit \
    opencode/big-pickle ollama-local/qwen3.6:35b-a3b-mtp-q4_K_M)"

# Оголошений маршрут кастомного провайдера мовчить.
printf '%s\n' "$report" | grep -q '^custom-gateway/auto/declared|' \
    && fail "оголошений маршрут кастомного провайдера позначено проблемою: $report"
# Неоголошений · називається. Це і є той дефект, що давав порожню сесію.
printf '%s\n' "$report" | grep -qx 'custom-gateway/auto/missing|missing' \
    || fail "неоголошений маршрут кастомного провайдера НЕ позначено проблемою: $report"
# Оголошення БЕЗ `limit.context` · окремий і найдорожчий випадок.
#
# 2026-09-04 маршрут диригента `auto/best-coding` був оголошений без межі:
# OpenCode не знав, коли стискати, сесія набрала 2,42 млн вхідних токенів за
# 11 пачок, і шлюз відмовив · `Input exceeds context window ... estimated
# 211204 input tokens, limit 200000`. Кожне «продовжуй» після цього давало ту
# саму помилку, а стара перевірка бачила лише НАЯВНІСТЬ ключа й друкувала OK.
printf '%s\n' "$report" | grep -qx 'custom-gateway/auto/no-limit|no-limit' \
    || fail "оголошення без limit.context НЕ позначено проблемою: $report"
# Провайдер без власного endpoint (каталог у OpenCode) і Ollama · не наша справа.
printf '%s\n' "$report" | grep -q 'opencode/big-pickle' \
    && fail "маршрут провайдера з каталогом OpenCode помилково вимагає оголошення"
printf '%s\n' "$report" | grep -q 'ollama-local/' \
    && fail "ollama має власну гілку перевірки й тут зʼявлятись не мусить"

# 5. `sync-opencode-models.sh` мусить користуватись САМЕ цим довідником, інакше
#    пункт 4 перевіряє код, якого робота не виконує.
grep -q 'custom-provider-models.php' "$ROOT/cli/runtime/sync-opencode-models.sh" \
    || fail "sync-opencode-models.sh не викликає custom-provider-models.php"
grep -q 'НЕ ОГОЛОШЕНА В КОНФІЗІ' "$ROOT/cli/runtime/sync-opencode-models.sh" \
    || fail "sync-opencode-models.sh не повідомляє про неоголошений маршрут"
grep -q 'БЕЗ МЕЖІ КОНТЕКСТУ' "$ROOT/cli/runtime/sync-opencode-models.sh" \
    || fail "sync-opencode-models.sh не повідомляє про оголошення без межі контексту"

echo "OK: маршрути кастомних провайдерів оголошуються, шаблони .env копійовні."
