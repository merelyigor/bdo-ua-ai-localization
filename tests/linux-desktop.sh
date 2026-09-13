#!/usr/bin/env bash
# Linux `.desktop`: install, real Exec execution, web lifecycle and idempotency.
set -euo pipefail

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-linux-desktop.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

DATA_HOME="$TMP/дані з пробілом"
STATE_DIR="$TMP/state"
FAKE_BIN="$TMP/тестовий шлях/bin"
mkdir -p "$FAKE_BIN" "$TMP/work"
ln -s "$(command -v php)" "$FAKE_BIN/php"
export PATH="$FAKE_BIN:$PATH"
export XDG_DATA_HOME="$DATA_HOME"
export BDO_DESKTOP_TEST_LINUX=1
export BDO_STATE_DIR="$STATE_DIR"
TEST_PORT=$((41000 + RANDOM % 4000))
export BDO_WEB_PORT="$TEST_PORT"

DESKTOP="$DATA_HOME/applications/bdo-ua-localization.desktop"
set +e
noargs_out="$(./bdo desktop 2>&1)"
noargs_code=$?
set -e
test "$noargs_code" -eq 2 || fail "desktop без аргументів дав код $noargs_code"
grep -Fq -- '--install' <<<"$noargs_out" || fail 'desktop без аргументів не надрукував підказку'

./bdo desktop --install >/dev/null || fail 'desktop --install впав'
test -f "$DESKTOP" || fail 'desktop --install не створив canonical-файл'
grep -Fxq 'Type=Application' "$DESKTOP" || fail 'ярлик без Type=Application'
grep -Fxq 'Terminal=false' "$DESKTOP" || fail 'ярлик без Terminal=false'
grep -Fxq 'StartupNotify=false' "$DESKTOP" || fail 'ярлик без явного StartupNotify=false'
grep -Eq '^Icon=/.*bdo\.png$' "$DESKTOP" || fail 'Icon не має абсолютного шляху'
grep -Fq "$FAKE_BIN/php" "$DESKTOP" || fail 'Exec не зберіг фактичний php-шлях із пробілом'

exec_line="$(sed -n 's/^Exec=//p' "$DESKTOP")"
test "$(grep -c '^Exec=' "$DESKTOP")" -eq 1 || fail 'ярлик має не один Exec'

run_exec() {
    local line="$1"
    (
        cd "$TMP/work"
        set --
        eval "set -- $line"
        test "$#" -eq 3 || { printf 'FAIL: Exec розібрався у %s аргументів\n' "$#" >&2; exit 1; }
        BDO_STATE_DIR="$STATE_DIR" BDO_WEB_PORT="$TEST_PORT" "$@" --background --no-open
    )
}

cp "$DESKTOP" "$TMP/desktop.snapshot"

repeat_out="$(./bdo desktop --install)" || fail 'повторний --install впав'
test "$(find "$DATA_HOME/applications" -maxdepth 1 -type f -name '*.desktop' | wc -l | tr -d ' ')" -eq 1 || fail 'повторний --install створив дублікати'
grep -Fq 'перезаписано' <<<"$repeat_out" || fail 'повторний --install не повідомив про перезапис'

status_out="$(./bdo desktop --status)" || fail '--status після install впав'
grep -Fq "Ярлик встановлений: $DESKTOP" <<<"$status_out" || fail '--status не назвав встановлений файл'
grep -Fq "Exec: $exec_line" <<<"$status_out" || fail '--status не показав фактичний Exec'

./bdo desktop --uninstall >/dev/null || fail '--uninstall впав'
test ! -e "$DESKTOP" || fail '--uninstall не прибрав файл'
after_out="$(./bdo desktop --status)" || fail '--status після uninstall впав'
grep -Fq "Ярлик не встановлений: $DESKTOP" <<<"$after_out" || fail '--status після uninstall збрехав'
./bdo desktop --install >/dev/null || fail 'повторне встановлення після uninstall впало'

exec_out="$(run_exec "$exec_line")" || fail 'витягнутий Exec не запустив сервер'
grep -Eq '^Exec="/[^"]+" "/[^"].*cli/bdo\.php" web$' "$DESKTOP" || fail 'Exec не має абсолютних php/script шляхів'
grep -Fq 'Інтерфейс:  http://127.0.0.1:' <<<"$exec_out" || fail 'виконаний Exec не надрукував посилання'
test -s "$STATE_DIR/web.json" || fail 'виконаний Exec не записав web.json'
port="$(php -r '$d=json_decode(file_get_contents($argv[1]), true); echo (int) $d["port"];' "$STATE_DIR/web.json")"
token="$(php -r '$d=json_decode(file_get_contents($argv[1]), true); echo $d["token"];' "$STATE_DIR/web.json")"
test "$port" -gt 0 || fail 'виконаний Exec не отримав порт'
curl -fsS "http://127.0.0.1:$port/api/health?t=$token" >/dev/null || fail 'сервер із Exec не відповідає health'

second_out="$(run_exec "$exec_line")" || fail 'повторний Exec впав на вже живому сервері'
grep -Fq 'Сервер уже працює' <<<"$second_out" || fail 'повторний Exec не використав наявний сервер'
test "$token" = "$(php -r '$d=json_decode(file_get_contents($argv[1]), true); echo $d["token"];' "$STATE_DIR/web.json")" || fail 'токен змінився при повторному запуску'

stop_out="$(BDO_STATE_DIR="$STATE_DIR" php cli/bdo.php web --stop)" || fail 'web --stop впав'
grep -Fq 'порт ' <<<"$stop_out" || fail 'web --stop не сказав про порт'
if curl -fsS "http://127.0.0.1:$port/api/health?t=$token" >/dev/null 2>&1; then
    fail 'web --stop не звільнив порт'
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
    ./bdo desktop --install >/dev/null || fail 'повторне встановлення для validate впало'
    desktop-file-validate "$DESKTOP" || fail 'desktop-file-validate повернув ненульовий код'
    ./bdo desktop --uninstall >/dev/null || fail 'cleanup після validate впав'
    printf 'desktop-file-validate: код 0\n'
else
    printf 'desktop-file-validate: не перевірено · утиліта відсутня\n'
fi

FALLBACK_HOME="$TMP/home"
mkdir -p "$FALLBACK_HOME"
fallback_out="$(env -u XDG_DATA_HOME HOME="$FALLBACK_HOME" ./bdo desktop --install)" || fail 'fallback HOME для XDG_DATA_HOME впав'
FALLBACK_DESKTOP="$FALLBACK_HOME/.local/share/applications/bdo-ua-localization.desktop"
test -f "$FALLBACK_DESKTOP" || fail 'без XDG_DATA_HOME не використано HOME/.local/share'
grep -Fq "$FALLBACK_DESKTOP" <<<"$fallback_out" || fail 'fallback HOME не надрукував повний шлях'
env -u XDG_DATA_HOME HOME="$FALLBACK_HOME" ./bdo desktop --uninstall >/dev/null || fail 'cleanup fallback HOME впав'

printf 'Linux desktop: install, real Exec, stable web lifecycle, idempotency, uninstall, status: OK\n'
printf 'Desktop file (full):\n'
cat "$TMP/desktop.snapshot"
