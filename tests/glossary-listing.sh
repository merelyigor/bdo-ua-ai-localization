#!/usr/bin/env bash
# Обхід глосарію сторінками: без запобіжників курсорна пагінація тихо
# зациклюється або тихо обривається, і обидва випадки виглядають однаково ·
# «стільки термінів і є». Тому перевіряємо не лише щасливий шлях.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Заглушка HTTP: віддає дві сторінки, потім кінець.
cat > "$TMP/http-ok.sh" <<'SH'
#!/usr/bin/env bash
url="${!#}"
case "$url" in
  *cursor=2*) printf '{"data":{"terms":[{"term_id":3,"canonical_source":"Week","ukrainian":"Місяць"}]},"meta":{"has_more":false,"next_cursor":null}}' ;;
  *) printf '{"data":{"terms":[{"term_id":1,"canonical_source":"Iron Sword","ukrainian":"Залізний меч"},{"term_id":2,"canonical_source":"GO","ukrainian":"ВПЕ"}]},"meta":{"has_more":true,"next_cursor":"2"}}' ;;
esac
SH
# Заглушка, що завжди повертає той самий курсор · сервер не рухається вперед.
cat > "$TMP/http-loop.sh" <<'SH'
#!/usr/bin/env bash
printf '{"data":{"terms":[{"term_id":1,"canonical_source":"A B","ukrainian":"А Б"}]},"meta":{"has_more":true,"next_cursor":"same"}}'
SH
# Заглушка недоступного endpoint.
cat > "$TMP/http-404.sh" <<'SH'
#!/usr/bin/env bash
exit 22
SH
chmod +x "$TMP"/http-*.sh

out="$(BDO_HTTP_CLIENT="$TMP/http-ok.sh" bash "$ROOT/cli/api/glossary-list.sh" 2>/dev/null)"
printf '%s' "$out" | jq -e '.terms | length == 3' >/dev/null || fail "обхід зібрав не всі сторінки: $out"
printf '%s' "$out" | jq -e '[.terms[].canonical_source] == ["Iron Sword","GO","Week"]' >/dev/null \
    || fail 'порядок або вміст сторінок зіпсовано'

set +e
BDO_HTTP_CLIENT="$TMP/http-loop.sh" bash "$ROOT/cli/api/glossary-list.sh" >/dev/null 2>"$TMP/loop.err"
code=$?
set -e
test "$code" -ne 0 || fail 'зациклена пагінація не зупинила обхід'
grep -q 'зациклилась' "$TMP/loop.err" || fail "причина зациклення не названа: $(cat "$TMP/loop.err")"

set +e
BDO_HTTP_CLIENT="$TMP/http-404.sh" bash "$ROOT/cli/api/glossary-list.sh" >"$TMP/empty.json" 2>"$TMP/err.txt"
code=$?
set -e
test "$code" -ne 0 || fail 'недоступний перелік віддав успіх'
test ! -s "$TMP/empty.json" || fail 'при помилці виведено масив, який прочитають як повний глосарій'
grep -q 'недоступний' "$TMP/err.txt" || fail 'причина недоступності не названа'

# Те, що клієнт не повторює постійних помилок, перевіряє tests/http-retry.sh:
# там видно РЕАЛЬНІ аргументи curl, а не згадку прапорця в коментарі.

echo 'glossary listing: OK'
