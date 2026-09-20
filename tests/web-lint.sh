#!/usr/bin/env bash
# JAVASCRIPT СТОРІНКИ ПЕРЕВІРЯЄТЬСЯ ЯК МОВА, А НЕ ЛИШЕ ВИКОНУЄТЬСЯ.
#
# До 2026-09-21 ~2 250 рядків коду сторінки не перевіряло НІЩО. Синтаксичну
# поломку опосередковано ловили node-тести, які цей код виконують, а звернення
# до неоголошеної змінної, друкарська помилка в імені поля чи мертвий код
# проїжджали мовчки · на першому ж прогоні лінтер знайшов мертву функцію на
# 20 рядків, яку ніхто не викликав.
#
# ВБУДОВАНІ СКРИПТИ ПЕРЕВІРЯЮТЬСЯ ТЕЖ. Половина коду сторінки живе всередині
# `web/*.html`, і перевірка самих лише `.js` накривала б менше половини.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v node >/dev/null 2>&1 \
    || { echo 'web lint: ПРОПУЩЕНО · немає node, JavaScript сторінки не перевірено'; exit 77; }
test -x node_modules/.bin/eslint \
    || { echo 'web lint: ПРОПУЩЕНО · лінтер не встановлено (npm ci), JavaScript сторінки не перевірено'; exit 77; }

ESLINT='node_modules/.bin/eslint'

# 1. Окремі файли скриптів.
"$ESLINT" web || fail 'лінтер знайшов помилки у файлах скриптів сторінки'

# 2. Вбудовані скрипти кожної сторінки · через той самий конфіг і той самий
#    лінтер, лише вміст подається потоком.
pages=0
for page in web/*.html; do
    test -f "$page" || continue
    inline="$(php -r '
        $html = (string) file_get_contents($argv[1]);
        $open = strpos($html, "<script>");
        if ($open === false) { return; }
        $close = strpos($html, "</script>", $open);
        if ($close === false) { fwrite(STDERR, "незакритий <script>\n"); exit(1); }
        echo substr($html, $open + 8, $close - $open - 8);
    ' "$page")" || fail "не вдалося дістати вбудований скрипт: $page"
    test -n "$inline" || continue
    printf '%s' "$inline" | "$ESLINT" --stdin --stdin-filename "${page%.html}.inline.js" \
        || fail "лінтер знайшов помилки у вбудованому скрипті: $page"
    pages=$((pages + 1))
done
test "$pages" -gt 0 || fail 'жодного вбудованого скрипта не перевірено · перевірка нічого не доводить'

# 3. ЛІНТЕР МУСИТЬ УМІТИ ЧЕРВОНІТИ. Без цього зелений результат нічого не
#    означає: він однаковий і для справного коду, і для вимкненої перевірки.
probe="$(mktemp -d)/probe.js"
mkdir -p web/tmp-lint-probe
trap 'rm -rf web/tmp-lint-probe' EXIT
printf 'var ok = 1;\nконсольВигадана(ok);\n' > web/tmp-lint-probe/probe.js
if "$ESLINT" web/tmp-lint-probe/probe.js >/dev/null 2>&1; then
    fail 'лінтер пропустив звернення до неоголошеного імені · перевірка фіктивна'
fi
rm -rf web/tmp-lint-probe "$probe"

echo "web lint: OK · скрипти сторінки й вбудовані скрипти $pages сторінок чисті, детектор неоголошених імен перевірений."
