#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$HTTP_RETRY_ARGS"
printf '{"ok":true}'
SH
chmod +x "$TMP/curl"

export HTTP_RETRY_ARGS="$TMP/args"
PATH="$TMP:$PATH" "$ROOT/cli/api/http-request.sh" -fsS -X POST \
    -H 'X-API-Key: secret' --data '{}' 'https://example.test/api' > "$TMP/body"

grep -Fxq -- '--retry' "$TMP/args"
grep -Fxq -- '1000' "$TMP/args"
# Постійні помилки не повторюються: `--retry-all-errors` крутив 404 і 400 ті
# самі 570 секунд, і зникла різниця між «сервер тимчасово впав» і «такого
# маршруту немає». 2026-08-28 це двічі виглядало як зависання клієнта.
grep -Fxq -- '--retry-all-errors' "$TMP/args" && {
    echo 'FAIL: постійні HTTP-помилки знову повторюються' >&2; exit 1; }
grep -Fxq -- '--retry-max-time' "$TMP/args"
grep -Fxq -- '570' "$TMP/args"
grep -Fxq -- '--max-time' "$TMP/args"
grep -Fxq -- '30' "$TMP/args"
grep -Fxq -- '--connect-timeout' "$TMP/args"
grep -Fxq -- '10' "$TMP/args"
grep -Fxq -- 'https://example.test/api' "$TMP/args"
grep -Fxq -- '{"ok":true}' "$TMP/body"

echo 'OK: BDO API retry має backoff, 10-хвилинний бюджет, таймаути спроби й не повторює постійних помилок'
