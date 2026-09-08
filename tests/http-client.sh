#!/usr/bin/env bash
# Перевіряє сумісний HTTP-контракт і байтовий вивід PHP-клієнта на локальному сервері.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-http-client.XXXXXX")"
PORT=$((25000 + RANDOM % 1000))
SERVER=''

cleanup() {
    [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/router.php" <<'PHP'
<?php
$scenario = (string) ($_GET['case'] ?? 'raw');
$countFile = (string) getenv('HTTP_CLIENT_COUNTS');
file_put_contents($countFile, $scenario."\n", FILE_APPEND | LOCK_EX);
$seenFile = (string) getenv('HTTP_CLIENT_SEEN');
if (isset($_SERVER['HTTP_X_API_KEY'])) {
    file_put_contents($seenFile, $_SERVER['HTTP_X_API_KEY']);
}
$count = 0;
foreach (file($countFile, FILE_IGNORE_NEW_LINES) ?: [] as $entry) {
    $count += $entry === $scenario ? 1 : 0;
}
if ($scenario === '404') {
    http_response_code(404);
    echo 'not-found';
    return;
}
if ($scenario === '501') {
    http_response_code(501);
    echo 'not-implemented';
    return;
}
if ($scenario === '503' && $count === 1) {
    http_response_code(503);
    header('Retry-After: 0');
    echo 'temporary';
    return;
}
if ($scenario === 'redirect') {
    http_response_code(302);
    header('Location: /?case=raw');
    return;
}
if ($scenario === 'timeout' && $count === 1) {
    sleep(2);
}
if ($scenario === 'echo') {
    echo (string) file_get_contents('php://input');
    return;
}
http_response_code(200);
echo "raw".chr(0)."line\n".chr(255);
PHP

: > "$TMP/counts"
: > "$TMP/seen-key"
HTTP_CLIENT_COUNTS="$TMP/counts" HTTP_CLIENT_SEEN="$TMP/seen-key" \
    php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$socket = @fsockopen("127.0.0.1", (int) $argv[1], $errno, $error, 0.2); if (is_resource($socket)) { fclose($socket); exit(0); } exit(1);' "$PORT" \
        && break
    sleep 0.1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }

run_bounded() {
    local output="$1" meta="$2"
    shift 2
    local started=$SECONDS pid watchdog code elapsed
    "$@" >"$output" 2>"$output.err" &
    pid=$!
    (sleep 2; kill "$pid" 2>/dev/null || true) &
    watchdog=$!
    set +e
    wait "$pid"
    code=$?
    set -e
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    elapsed=$((SECONDS - started))
    printf '%s %s\n' "$elapsed" "$code" >"$meta"
}

URL="http://127.0.0.1:$PORT/?case="
printf 'raw\0line\n\377' > "$TMP/expected-body"

run_bounded "$TMP/dead.out" "$TMP/dead.meta" \
    "$ROOT/cli/api/http-request.sh" -sS -X POST -H 'X-API-Key: test' \
    --data '{"x":1}' 'http://127.0.0.1:1/glossary/terms/resolve'
read -r dead_seconds dead_code <"$TMP/dead.meta"
test "$dead_code" -eq 7 || { echo "FAIL: dead port code=$dead_code time=${dead_seconds}s" >&2; exit 1; }
test "$dead_seconds" -lt 2 || { echo "FAIL: dead port time=${dead_seconds}s" >&2; exit 1; }

: > "$TMP/counts"
run_bounded "$TMP/501.out" "$TMP/501.meta" "$ROOT/cli/api/http-request.sh" -sS "${URL}501"
read -r not_implemented_seconds not_implemented_code <"$TMP/501.meta"
test "$not_implemented_code" -eq 0 || { echo "FAIL: 501 code=$not_implemented_code" >&2; exit 1; }
test "$not_implemented_seconds" -lt 2 || { echo "FAIL: 501 повторився за ${not_implemented_seconds}s" >&2; exit 1; }
test "$(grep -c '^501$' "$TMP/counts" || true)" -eq 1 || { echo 'FAIL: 501 повторився' >&2; exit 1; }

: > "$TMP/counts"
"$ROOT/cli/api/http-request.sh" -sS "${URL}503" >"$TMP/503.out"
grep -Fq raw "$TMP/503.out" || { echo 'FAIL: 503 не завершився повтором' >&2; exit 1; }
test "$(grep -c '^503$' "$TMP/counts" || true)" -gt 1 || { echo 'FAIL: 503 не повторився' >&2; exit 1; }

"$ROOT/cli/api/http-request.sh" -sS -H 'X-API-Key: test-key' "${URL}raw" >"$TMP/body"
cmp -s "$TMP/expected-body" "$TMP/body" || { echo 'FAIL: 200 тіло змінилось побайтово' >&2; exit 1; }
grep -Fxq test-key "$TMP/seen-key" || { echo 'FAIL: X-API-Key не дійшов до сервера' >&2; exit 1; }

"$ROOT/cli/api/http-request.sh" -sS -o "$TMP/output-file" "${URL}raw" >"$TMP/output-stdout"
test ! -s "$TMP/output-stdout" || { echo 'FAIL: -o продублював тіло у stdout' >&2; exit 1; }
cmp -s "$TMP/expected-body" "$TMP/output-file" || { echo 'FAIL: -o змінив тіло або файл' >&2; exit 1; }

write_out="$("$ROOT/cli/api/http-request.sh" -sS -o /dev/null -w '%{http_code}' "${URL}raw")"
test "$write_out" = 200 || { echo "FAIL: -w дав '$write_out'" >&2; exit 1; }

printf 'payload\0bytes\n' > "$TMP/request-body"
"$ROOT/cli/api/http-request.sh" -sS -X POST -H 'Content-Type: application/octet-stream' \
    --data-binary "@$TMP/request-body" "${URL}echo" >"$TMP/echo"
cmp -s "$TMP/request-body" "$TMP/echo" || { echo 'FAIL: --data-binary змінив запит або відповідь' >&2; exit 1; }

: > "$TMP/counts"
"$ROOT/cli/api/http-request.sh" -sS -m 1 "${URL}timeout" >"$TMP/timeout"
grep -Fq raw "$TMP/timeout" || { echo 'FAIL: таймаут спроби не відновився повтором' >&2; exit 1; }
test "$(grep -c '^timeout$' "$TMP/counts" || true)" -gt 1 || { echo 'FAIL: таймаут не мав повторної спроби' >&2; exit 1; }

"$ROOT/cli/api/http-request.sh" -sS -L "${URL}redirect" >"$TMP/redirect-body"
redirect_body="$(od -An -t x1 "$TMP/redirect-body" | tr -d ' \n')"
test "$redirect_body" = '726177006c696e650aff' || { echo 'FAIL: перенаправлення не дійшло до цілі' >&2; exit 1; }

set +e
"$ROOT/cli/api/http-request.sh" -sS --unknown-flag "${URL}raw" >"$TMP/unknown.out" 2>"$TMP/unknown.err"
unknown_code=$?
"$ROOT/cli/api/http-request.sh" -sS -H 'X-API-Key: super-secret-key' 'http://[bad' >"$TMP/bad.out" 2>"$TMP/bad.err"
bad_code=$?
set -e
test "$unknown_code" -eq 2 || { echo "FAIL: unknown flag code=$unknown_code" >&2; exit 1; }
grep -Fq 'невідомий прапорець' "$TMP/unknown.err" || { echo 'FAIL: unknown flag не названий' >&2; exit 1; }
test "$bad_code" -ne 0 || { echo 'FAIL: помилковий URL прийнятий' >&2; exit 1; }
if grep -Fq 'super-secret-key' "$TMP/bad.err"; then
    echo 'FAIL: X-API-Key потрапив у stderr' >&2
    exit 1
fi

set +e
php -d disable_functions=curl_init "$ROOT/cli/api/http-client.php" "${URL}raw" >"$TMP/no-curl.out" 2>"$TMP/no-curl.err"
no_curl_code=$?
set -e
test "$no_curl_code" -ne 0 || { echo 'FAIL: вимкнений ext-curl прийнятий' >&2; exit 1; }
grep -Fq 'ext-curl' "$TMP/no-curl.err" || { echo 'FAIL: вимкнений ext-curl не названий' >&2; exit 1; }

echo "http client: dead port=${dead_seconds}s, 501=${not_implemented_seconds}s, 503 retry, byte body, -o, -w, headers/data, timeout, redirect, ext-curl guard: OK"
