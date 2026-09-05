#!/usr/bin/env bash
# Локальний інтерфейс у браузері: одна команда, вільний порт, посилання в терміналі.
#
#   ./web.sh                 # запустити й тримати; Ctrl-C зупиняє
#   ./web.sh --background    # запустити й відпустити термінал
#   ./web.sh --status        # чи працює, на якому порту, чи відповідає
#   ./web.sh --stop          # зупинити фоновий сервер
#   ./web.sh --no-open       # не відкривати браузер самому
#
# Навіщо. Власник просив рівно це: «запускаю команду в терміналі і воно
# доступно по 127.0.0.1:вільний порт та показує посилання» (2026-09-04).
# Сервер лише ЧИТАЄ `state/**`, тому прогін, запущений із термінала, видно в
# браузері так само, як запущений кнопкою · джерело правди одне.
#
# ПОРТ ВИБИРАЄ ЯДРО, А НЕ СКАНУВАННЯ. Спершу пробуємо 7654 (або `BDO_WEB_PORT`).
# Якщо він зайнятий · передаємо `:0`, і PHP друкує обраний порт сам. Перевірка
# «а чи вільно тут» окремим сокетом має щілину: між перевіркою й запуском порт
# займає інший процес, і власник отримує посилання в нікуди. Заміряно на
# PHP 8.5.4: `:0` дає порт у рядку `Development Server (http://127.0.0.1:62458)
# started`, а зайнятий порт · `Failed to listen … (Address already in use)`
# і код 1.
#
# ЯВНИЙ `BDO_WEB_PORT` НЕ ПЕРЕЇЖДЖАЄ. Якщо власник назвав порт, у нього була
# причина (закладка в браузері), і тихий переїзд на інший порт зробив би цю
# закладку мертвою без жодного слова.
#
# ПОСИЛАННЯ ДРУКУЄМО ЛИШЕ ПІСЛЯ ЖИВОЇ ВІДПОВІДІ. Порожній вивід не є
# відповіддю (§12): сервер може стартувати й одразу впасти на помилці в
# маршрутизаторі, і надруковане наперед посилання було б брехнею. Тому перед
# друком робимо справжній запит на `/api/health`.
#
# PHP_CLI_SERVER_WORKERS робить вбудований сервер багатопроцесним · без цього
# одне відкрите SSE-зʼєднання блокує всі інші запити (заміряно: 2.6 с проти
# 0.02 с). Змінна документована як експериментальна й діє лише на POSIX;
# на Windows конвеєр однаково живе у WSL2.
#
# ЗУПИНКА ЦІЛИТЬСЯ В ТИХ, ХТО ТРИМАЄ ПОРТ, І БІЛЬШЕ НІ В КОГО.
#
# Два уроки, обидва з живих прогонів, і вони тягнуть у різні боки.
#
# 1. Мало вбити майстра. `PHP_CLI_SERVER_WORKERS` створює воркери на ТОМУ
#    САМОМУ сокеті, тому після смерті майстра порт лишається зайнятим і
#    сторінка далі відповідає старим токеном, поки команда каже «зупинено»
#    (D65).
# 2. Не можна вбивати групу процесів. Дія «почати прогін» породжує роботу з
#    цього ж сервера, і при `kill -- -PGID` вона гине разом із ним: 2026-09-05
#    перезапуск сервера вбив живу пачку на кроці `awaiting_worker` (D68) ·
#    рівно те, що обіцяно навпаки («сервер можна перезапустити, робота триває»).
#
# Тому ціль зупинки визначає СОКЕТ: власники слухаючого порту (`lsof -ti`) плюс
# записаний pid. Прогін порту не тримає, отже переживає зупинку за побудовою.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
ROUTER="$SCRIPT_DIR/cli/system/web-router.php"
PAGE="$SCRIPT_DIR/web/index.html"
INFO="$STATE_DIR/web.json"
# Токен переживає зупинку: інакше кожен `--stop` робив би закладку мертвою.
TOKEN_FILE="$STATE_DIR/web-token"
LOG="$STATE_DIR/web.log"
WORKERS="${BDO_WEB_WORKERS:-4}"
# Типовий порт має шов лише для тестів: перевірка «типовий зайнятий -> беремо
# вільний» мусить бути детермінованою, а займати справжній 7654 власника під
# час прогону тестів не можна.
DEFAULT_PORT="${BDO_WEB_DEFAULT_PORT:-7654}"

die() { printf 'web: %s\n' "$1" >&2; exit 1; }

mkdir -p "$STATE_DIR"
test -f "$ROUTER" || die "немає маршрутизатора: $ROUTER"
test -f "$PAGE" || die "немає сторінки: $PAGE"
command -v php >/dev/null 2>&1 || die 'немає php'

# --- дрібні помічники -------------------------------------------------------

info_field() {
    test -s "$INFO" || return 1
    php -r '
        $d = json_decode((string) file_get_contents($argv[1]), true);
        if (! is_array($d) || ! isset($d[$argv[2]])) { exit(1); }
        echo $d[$argv[2]];
    ' "$INFO" "$1"
}

# Чи відповідає сервер на цьому порту НАШИМ токеном. Код HTTP, а не «щось є».
health_code() {
    local port="$1" token="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -s -o /dev/null -m 3 -w '%{http_code}' \
            "http://127.0.0.1:${port}/api/health?t=${token}" 2>/dev/null || echo 000
        return 0
    fi
    php -r '
        $ctx = stream_context_create(["http" => ["timeout" => 3, "ignore_errors" => true]]);
        $body = @file_get_contents("http://127.0.0.1:".$argv[1]."/api/health?t=".$argv[2], false, $ctx);
        if ($body === false) { echo "000"; exit(0); }
        foreach ($http_response_header ?? [] as $line) {
            if (preg_match("~^HTTP/\S+\s+(\d{3})~", $line, $m)) { echo $m[1]; exit(0); }
        }
        echo "000";
    ' "$port" "$token"
}

# Чи слухає хтось цей порт. Саме це, а не «процес зник», є доказом зупинки:
# воркери переживають смерть майстра й тримають сокет далі.
port_busy() {
    local port="$1"
    php -r '
        $s = @stream_socket_client("tcp://127.0.0.1:".$argv[1], $errno, $err, 0.4);
        if ($s === false) { exit(1); }
        fclose($s);
        exit(0);
    ' "$port"
}

# Хто саме слухає цей порт. Це і є вичерпний перелік процесів сервера: майстер
# і воркери ділять один сокет, а більше його ніхто не тримає.
port_owners() {
    local port="$1"
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -ti "tcp:${port}" -sTCP:LISTEN 2>/dev/null || true
}

# Зупинити сервер і ДОВЕСТИ, що порт звільнився.
stop_server() {
    local pid="$1" port="${2:-}" waited=0 owner children
    # Спершу ті, хто тримає порт · разом, поки живий майстер їх не відновив.
    if [ -n "$port" ]; then
        for owner in $(port_owners "$port"); do
            kill "$owner" 2>/dev/null || true
        done
    fi
    if [ -n "$pid" ]; then
        # Прямі діти записаного процесу · це воркери (їх не буде в lsof лише
        # на системі без lsof). Онуків не чіпаємо: там живе робота.
        children="$(ps -o pid=,ppid= -ax 2>/dev/null | awk -v p="$pid" '$2 == p { print $1 }' || true)"
        for owner in $children; do
            kill "$owner" 2>/dev/null || true
        done
        kill "$pid" 2>/dev/null || true
    fi
    test -n "$port" || return 0
    while [ "$waited" -lt 20 ]; do
        port_busy "$port" || return 0
        sleep 0.1
        waited=$((waited + 1))
    done
    # Не здаємось мовчки: добиваємо власників порту жорстко й перевіряємо ще раз.
    for owner in $(port_owners "$port"); do
        kill -9 "$owner" 2>/dev/null || true
    done
    sleep 0.3
    port_busy "$port" || return 0

    return 1
}

open_browser() {
    local url="$1"
    if command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 || true
    elif grep -qi microsoft /proc/version 2>/dev/null && command -v explorer.exe >/dev/null 2>&1; then
        # WSL2: браузер живе на самому Windows, а loopback пробрасується.
        explorer.exe "$url" >/dev/null 2>&1 || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || true
    else
        printf 'web: браузер сам не відкриється · немає open/xdg-open. Відкрий посилання вручну.\n' >&2
    fi
}

# --- --status / --stop ------------------------------------------------------

case "${1:-}" in
    --status)
        test -s "$INFO" || { echo 'Сервер не запущено (немає state/web.json).'; exit 0; }
        pid="$(info_field pid || true)"
        port="$(info_field port || true)"
        token="$(info_field token || true)"
        test -n "$pid" && test -n "$port" || die "пошкоджений $INFO · зупини через --stop і запусти заново"
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "Записаний процес $pid не живий · сервер упав або його вбили. Прибери запис: ./bdo web --stop"
            exit 1
        fi
        code="$(health_code "$port" "$token")"
        printf 'Сервер працює: pid %s, порт %s, /api/health -> %s\n' "$pid" "$port" "$code"
        printf 'Інтерфейс: http://127.0.0.1:%s/?t=%s\n' "$port" "$token"
        test "$code" = 200 || die 'процес живий, але не відповідає 200 · дивись state/web.log'
        exit 0
        ;;
    --stop)
        test -s "$INFO" || { echo 'Зупиняти нічого: сервер не запущено.'; exit 0; }
        pid="$(info_field pid || true)"
        port="$(info_field port || true)"
        if stop_server "$pid" "$port"; then
            rm -f "$INFO"
            printf 'Сервер зупинено, порт %s вільний.\n' "${port:-?}"
            exit 0
        fi
        # Запис НЕ прибираємо: інакше наступний запуск вважав би, що чисто, а
        # порт лишався б зайнятим · саме так і виглядає тихий збій.
        die "порт ${port} досі зайнятий після зупинки · подивись, хто його тримає (lsof -i tcp:${port})"
        ;;
esac

# --- запуск -----------------------------------------------------------------

BACKGROUND=0
OPEN=1
while [ $# -gt 0 ]; do
    case "$1" in
        --background) BACKGROUND=1; shift ;;
        --no-open) OPEN=0; shift ;;
        *) die "дозволено лише --background, --no-open, --status і --stop, отримано «${1}»" ;;
    esac
done

# Чи стоїть уже НАШ сервер на цьому порту. Питаємо сам сервер (`/api/ping`),
# а не файл: `state/web.json` може зникнути (аварія, ручне прибирання), і тоді
# другий запуск підіймав ДРУГИЙ сервер на іншому порту · два різні посилання,
# два токени, і власник не знає, яке з них живе.
ours_on_port() {
    local port="$1" body
    if command -v curl >/dev/null 2>&1; then
        body="$(curl -s -m 2 "http://127.0.0.1:${port}/api/ping" 2>/dev/null || true)"
    else
        body="$(php -r '
            $ctx = stream_context_create(["http" => ["timeout" => 2, "ignore_errors" => true]]);
            echo (string) @file_get_contents("http://127.0.0.1:".$argv[1]."/api/ping", false, $ctx);
        ' "$port")"
    fi
    case "$body" in
        *'"bdo":true'*) return 0 ;;
        *) return 1 ;;
    esac
}

# Уже запущений сервер не дублюємо: два сервери на одному стані · два різні
# посилання й два токени, і власник не знатиме, яке з них живе.
if [ -s "$INFO" ]; then
    old_pid="$(info_field pid || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        old_port="$(info_field port || true)"
        old_token="$(info_field token || true)"
        printf 'Сервер уже працює: http://127.0.0.1:%s/?t=%s\n' "$old_port" "$old_token"
        printf 'Зупинити: ./bdo web --stop\n'
        exit 0
    fi
    rm -f "$INFO"
fi

# ТОКЕН СТАБІЛЬНИЙ МІЖ ПЕРЕЗАПУСКАМИ.
#
# Новий токен на кожен запуск виглядав охайно, але ламав звичайну роботу:
# відкрита вкладка власника після перезапуску сервера отримувала 403 на кожен
# запит даних, а закладка в браузері ставала мертвою назавжди (D75). Токен
# лежить у `state/web.json` із правами 0600 · це той самий локальний секрет,
# що й був, просто він переживає рестарт.
# Токен живе в ОКРЕМОМУ файлі, а не в записі про запущений сервер: `--stop`
# прибирає запис, і разом із ним зникав би токен · тобто після кожної зупинки
# закладка ставала мертвою. Один файл · одне значення.
if [ -n "${BDO_WEB_TOKEN:-}" ]; then
    TOKEN="$BDO_WEB_TOKEN"
elif [ -s "$TOKEN_FILE" ]; then
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
elif command -v openssl >/dev/null 2>&1; then
    TOKEN="$(openssl rand -hex 16)"
else
    TOKEN="$(php -r 'echo bin2hex(random_bytes(16));')"
fi
case "$TOKEN" in
    ''|*[!0-9a-fA-F]*) die 'токен мусить бути шістнадцятковим рядком · перевір BDO_WEB_TOKEN або state/web-token' ;;
esac
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE" 2>/dev/null || true
PREVIOUS_TOKEN="$TOKEN"

EXPLICIT_PORT=0
PORT="$DEFAULT_PORT"
if [ -n "${BDO_WEB_PORT:-}" ]; then
    case "$BDO_WEB_PORT" in
        ''|*[!0-9]*) die "BDO_WEB_PORT мусить бути числом, отримано «${BDO_WEB_PORT}»" ;;
    esac
    PORT="$BDO_WEB_PORT"
    EXPLICIT_PORT=1
fi

# Порт зайнятий НАШИМ сервером · не піднімаємо другий, а віддаємо посилання на
# той, що вже працює. Саме цей випадок дає «два сервери на одному стані», коли
# запис у `state/web.json` загубився.
if ours_on_port "$PORT"; then
    if [ -n "$PREVIOUS_TOKEN" ]; then
        printf 'Сервер уже працює на порту %s: http://127.0.0.1:%s/?t=%s\n' "$PORT" "$PORT" "$PREVIOUS_TOKEN"
    else
        printf 'На порту %s уже працює bdo, але запису state/web.json немає.\n' "$PORT" >&2
        printf 'Зупини його й запусти заново: ./bdo web --stop && ./bdo web\n' >&2
        exit 1
    fi
    printf 'Зупинити: ./bdo web --stop\n'
    exit 0
fi

SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        stop_server "$SERVER_PID" "${BOUND_PORT:-}" || true
    fi
    if [ "$BACKGROUND" != 1 ]; then
        rm -f "$INFO"
    fi
}

# Запустити сервер на заданому порту й дочекатися його ВЛАСНОГО рядка про
# старт. Код 0 · слухає (порт друкує в $BOUND_PORT), 1 · порт зайнятий.
BOUND_PORT=""
start_server() {
    local want="$1" line=""
    : >"$LOG"
    PHP_CLI_SERVER_WORKERS="$WORKERS" BDO_WEB_TOKEN="$TOKEN" BDO_STATE_DIR="$STATE_DIR" \
        php -S "127.0.0.1:${want}" -t "$SCRIPT_DIR/web" "$ROUTER" >>"$LOG" 2>&1 &
    SERVER_PID=$!
    local waited=0
    while [ "$waited" -lt 60 ]; do
        if grep -q 'Failed to listen' "$LOG" 2>/dev/null; then
            wait "$SERVER_PID" 2>/dev/null || true
            SERVER_PID=""
            return 1
        fi
        line="$(sed -n 's~.*Development Server (http://127\.0\.0\.1:\([0-9]*\)).*~\1~p' "$LOG" 2>/dev/null | head -1)"
        if [ -n "$line" ]; then
            BOUND_PORT="$line"
            return 0
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            die "сервер упав одразу після запуску · дивись $LOG"
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    die "сервер не сказав, що слухає, за 6 с · дивись $LOG"
}

trap cleanup EXIT INT TERM

if ! start_server "$PORT"; then
    if [ "$EXPLICIT_PORT" = 1 ]; then
        die "порт ${PORT} зайнятий, а його задано явно через BDO_WEB_PORT · звільни порт або прибери змінну (тихо переїжджати не буду)"
    fi
    printf 'web: порт %s зайнятий · беру вільний у системи\n' "$PORT" >&2
    start_server 0 || die 'вільного порту не знайшлось навіть у системи'
fi
PORT="$BOUND_PORT"
URL="http://127.0.0.1:${PORT}/?t=${TOKEN}"

# Жива перевірка ПЕРЕД друком посилання.
CODE=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    CODE="$(health_code "$PORT" "$TOKEN")"
    test "$CODE" = 200 && break
    sleep 0.2
done
test "$CODE" = 200 || die "сервер слухає порт ${PORT}, але /api/health відповів ${CODE} · дивись $LOG"

php -r '
    file_put_contents($argv[1], json_encode([
        "pid" => (int) $argv[2],
        "port" => (int) $argv[3],
        "token" => $argv[4],
        "started_at" => gmdate("c"),
        "workers" => (int) $argv[5],
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)."\n");
    chmod($argv[1], 0600);
' "$INFO" "$SERVER_PID" "$PORT" "$TOKEN" "$WORKERS"

TARGET="$(cat "$STATE_DIR/run-target" 2>/dev/null || echo '—')"
cat <<INFO_TXT

  Інтерфейс:  ${URL}
  Порт:       ${PORT}$([ "$PORT" = "$DEFAULT_PORT" ] && echo '' || echo ' (типовий був зайнятий)')
  Ціль:       $(printf '%s' "$TARGET" | tr '[:lower:]' '[:upper:]')
  Журнал:     ${LOG}
INFO_TXT

if [ "$OPEN" = 1 ]; then
    open_browser "$URL"
fi

if [ "$BACKGROUND" = 1 ]; then
    printf '  Зупинити:   ./bdo web --stop\n\n'
    trap - EXIT INT TERM
    exit 0
fi

printf '  Зупинити:   Ctrl-C\n\n'
tail -f "$LOG" &
TAIL_PID=$!
cleanup_fg() {
    kill "$TAIL_PID" 2>/dev/null || true
    cleanup
}
trap cleanup_fg EXIT INT TERM
wait "$SERVER_PID" 2>/dev/null || true
