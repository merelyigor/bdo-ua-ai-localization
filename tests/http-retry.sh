#!/usr/bin/env bash
# Перевіряє рішення RetryPolicy живими HTTP-відповідями, а не прапорцями клієнта.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-http-retry.XXXXXX")"
PORT=$((24000 + RANDOM % 1000))
SERVER=''

cleanup() {
    [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

cat > "$TMP/router.php" <<'PHP'
<?php
$scenario = (string) ($_GET['case'] ?? '200');
$countFile = (string) getenv('HTTP_RETRY_COUNTS');
file_put_contents($countFile, $scenario."\n", FILE_APPEND | LOCK_EX);
$count = 0;
foreach (file($countFile, FILE_IGNORE_NEW_LINES) ?: [] as $entry) {
    $count += $entry === $scenario ? 1 : 0;
}
if ($scenario === '404') {
    http_response_code(404);
    echo 'not-found';
    return;
}
if (($scenario === '429' || $scenario === '503') && $count === 1) {
    http_response_code((int) $scenario);
    header('Retry-After: 0');
    echo 'temporary';
    return;
}
if ($scenario === 'timeout' && $count === 1) {
    sleep(2);
}
http_response_code(200);
echo 'ok';
PHP

: > "$TMP/counts"
HTTP_RETRY_COUNTS="$TMP/counts" php -S "127.0.0.1:$PORT" "$TMP/router.php" >"$TMP/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 40); do
    php -r '$socket = @fsockopen("127.0.0.1", (int) $argv[1], $errno, $error, 0.2); if (is_resource($socket)) { fclose($socket); exit(0); } exit(1);' "$PORT" \
        && break
    sleep 0.1
done
kill -0 "$SERVER" 2>/dev/null || { cat "$TMP/server.log" >&2; exit 1; }

count() { grep -c "^$1$" "$TMP/counts" || true; }
URL="http://127.0.0.1:$PORT/?case="

: > "$TMP/counts"
set +e
"$ROOT/cli/api/http-request.sh" -fsS "${URL}404" >"$TMP/404.out" 2>"$TMP/404.err"
code=$?
set -e
test "$code" -eq 22 || { echo "FAIL: 404 code=$code" >&2; exit 1; }
test "$(count 404)" -eq 1 || { echo 'FAIL: 404 повторився' >&2; exit 1; }

for scenario in 429 503; do
    : > "$TMP/counts"
    "$ROOT/cli/api/http-request.sh" -sS "${URL}${scenario}" >"$TMP/$scenario.out"
    grep -Fxq ok "$TMP/$scenario.out" || { echo "FAIL: $scenario не завершився успішно" >&2; exit 1; }
    test "$(count "$scenario")" -gt 1 || { echo "FAIL: $scenario не повторився" >&2; exit 1; }
done

: > "$TMP/counts"
"$ROOT/cli/api/http-request.sh" -sS -m 1 "${URL}timeout" >"$TMP/timeout.out"
grep -Fxq ok "$TMP/timeout.out" || { echo 'FAIL: timeout не відновився повтором' >&2; exit 1; }
test "$(count timeout)" -gt 1 || { echo 'FAIL: timeout не мав другої спроби' >&2; exit 1; }

echo 'http retry: 404 одна спроба; 429/503 і timeout повторені: OK'
