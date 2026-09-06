#!/usr/bin/env bash
# Значок є ПУЛЬТОМ інтерфейсу: він лишається відкритим, поки живий сервер, і
# гасить сервер, коли його закривають. Обидва боки · вимога власника
# 2026-09-06, і обидва перевіряються тут на справжньому процесі, а не читанням
# тексту скрипта.
#
# Три речі, і третя найважливіша:
#   1. значок сам піднімає сервер, коли його немає;
#   2. значок ПЕРЕХОПЛЮЄ сервер, піднятий не ним (термінал, `make web`), і
#      НЕ ЗАКРИВАЄТЬСЯ при цьому · саме це було зламано: гілка перехоплення
#      питала вікном, а кнопкою за замовчуванням стояла та, що робила `exit 0`;
#   3. сигнал завершення (його шле macOS на «Завершити» в Dock і Cmd+Q)
#      зупиняє сервер, а не лишає його жити без значка.
#
# ІЗОЛЯЦІЯ ОБОВʼЯЗКОВА. `mac-app.sh` кличе справжній `./bdo web --stop`, тому
# без власної теки стану й власного порту тест убив би ЖИВИЙ інтерфейс
# власника. `open` теж підмінено · інакше кожен запуск відкривав би вкладку.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

test "$(uname -s)" = Darwin || { printf 'mac app quit: SKIP · не macOS\n'; exit 0; }
command -v php >/dev/null 2>&1 || fail 'немає php'

TMP="$(mktemp -d)"
APP_PID=''
cleanup() {
    test -z "$APP_PID" || kill -KILL "$APP_PID" 2>/dev/null || true
    BDO_STATE_DIR="$TMP/state" "$ROOT/bdo" web --stop >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/state" "$TMP/bin"
# Підмінений `open`: значок відкриває браузер, тесту це не потрібно.
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/open"
chmod +x "$TMP/bin/open"

export PATH="$TMP/bin:$PATH"
export BDO_STATE_DIR="$TMP/state"
export BDO_WEB_DEFAULT_PORT=$(( 46000 + RANDOM % 3000 ))

# `--status` виходить НУЛЕМ і тоді, коли сервера немає («Сервер не запущено»),
# тому питаємо те саме, що питає значок · посилання у виводі.
running() {
    "$ROOT/bdo" web --status 2>/dev/null \
        | grep -qE 'http://127\.0\.0\.1:[0-9]+/\?t='
}

wait_for() {   # <секунди> <«є»|«немає»>
    local limit="$1" want="$2" i=0
    while [ "$i" -lt $(( limit * 4 )) ]; do
        if running; then test "$want" = 'немає' || return 0
        else test "$want" = 'є' || return 0; fi
        sleep 0.25
        i=$(( i + 1 ))
    done
    return 1
}

alive() { kill -0 "$APP_PID" 2>/dev/null; }

# --- 1. Значок піднімає сервер сам ------------------------------------------
running && fail 'пісочниця вже має сервер · ізоляція не спрацювала'
bash "$ROOT/cli/system/mac-app.sh" >"$TMP/app.log" 2>&1 &
APP_PID=$!
wait_for 40 'є' || fail "значок не підняв сервер: $(cat "$TMP/app.log")"
alive || fail 'значок зник одразу після старту · у Dock не буде чого закривати'

# --- 3. Завершення гасить сервер --------------------------------------------
kill -TERM "$APP_PID"
wait_for 20 'немає' || fail 'закриття значка НЕ зупинило інтерфейс'
wait "$APP_PID" 2>/dev/null || true
APP_PID=''

# --- 2. Перехоплення чужого сервера -----------------------------------------
# Найважливіша частина: сервер підняв НЕ значок.
"$ROOT/bdo" web --background --no-open >/dev/null 2>&1 \
    || fail 'не вдалося підняти сервер окремо від значка'
wait_for 30 'є' || fail 'окремо піднятий сервер не відповідає'

bash "$ROOT/cli/system/mac-app.sh" >"$TMP/app2.log" 2>&1 &
APP_PID=$!
sleep 3
alive || fail "значок закрився замість перехопити чужий сервер: $(cat "$TMP/app2.log")"
running || fail 'значок зупинив чужий сервер замість перехопити його'

kill -TERM "$APP_PID"
wait_for 20 'немає' || fail 'перехоплений сервер пережив закриття значка'
wait "$APP_PID" 2>/dev/null || true
APP_PID=''

printf 'mac app quit: OK · значок піднімає, перехоплює чуже й гасить сервер при закритті.\n'
