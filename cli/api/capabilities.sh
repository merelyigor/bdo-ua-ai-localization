#!/usr/bin/env bash
if [ "${BDO_ORCHESTRATOR:-php}" != sh ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    exec php "$SCRIPT_DIR/cli/bdo.php" capabilities "$@"
fi
# ЩО ВМІЄ ЦЯ ЦІЛЬ · перевіряється запитом, а не переліком у коді.
#
# Поки живі два бекенди (старий Agent API BDO UA і хаб локалізацій), частина
# ендпоінтів є лише в одному з них: у хабі поки немає глосарія, контексту,
# памʼяті перекладів, патчів, машинної інструкції та черги модерації.
#
# ЧОМУ НЕ СПИСОК У КОДІ. Перелік того, чого «немає в хабі», застаріває в день,
# коли хаб щось додасть, і клієнт продовжить обходити вже наявну можливість.
# Тому джерело правди · ВІДПОВІДЬ: 404 означає «тут цієї можливості немає»,
# 200 · «є». Перелік нижче задає лише, ЩО саме питати, і це закритий набір
# ендпоінтів контракту, а не каталог винятків.
#
# Результат кешується на ціль (`state/api-capabilities.<ціль>.json`): питати
# шість ендпоінтів на кожну пачку означало б платити мережею за відповідь, яка
# змінюється раз на місяць. Кеш має TTL і скидається `--refresh`.
#
# Використання:
#   ./capabilities.sh                    показати таблицю для поточної цілі
#   ./capabilities.sh --has glossary     код 0 · можливість є, 1 · немає
#   ./capabilities.sh --fields a,b,c     лишити з переліку те, що ціль приймає
#   ./capabilities.sh --refresh          перепитати, не дивлячись у кеш
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh" >/dev/null

STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
CACHE="$STATE_DIR/api-capabilities.$BDO_API_ENV.json"
TTL_HOURS="${BDO_CAPABILITIES_TTL_HOURS:-24}"

# Ім'я -> шлях проби. Проба мусить бути ДЕШЕВОЮ й безпечною: лише GET, лише
# читання, мінімальна вибірка.
probe_path() {
    case "$1" in
        glossary)   printf 'glossary/terms/list?limit=1' ;;
        memory)     printf 'translations/memory' ;;
        patches)    printf 'patches' ;;
        guide)      printf 'guide' ;;
        proposals)  printf 'translations/proposals?limit=1' ;;
        *) return 1 ;;
    esac
}
# Контексту рядка (`rows/{hash}/context`) у цьому переліку НЕМАЄ навмисно:
# дешевої проби для нього не існує. Він вимагає справжнього identity_hash, а на
# вигаданий і старий API, і хаб однаково відповідають 404 · тобто «рядка немає»
# не відрізнити від «маршруту немає». Тому його відсутність ловиться на місці
# виклику: крок контексту й так не є ворітьми й працює без прикладів.
readonly NAMES='glossary memory patches guide proposals'

WANT=''
FIELDS=''
REFRESH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --has) WANT="${2:?--has потребує назву можливості}"; shift 2 ;;
        --fields) FIELDS="${2:?--fields потребує перелік через кому}"; shift 2 ;;
        --refresh) REFRESH=1; shift ;;
        *) echo "capabilities: невідомий аргумент «${1}»" >&2; exit 1 ;;
    esac
done

fresh_cache() {
    test "$REFRESH" = 0 || return 1
    test -s "$CACHE" || return 1
    php -r '
    $ttl = (int) $argv[2] * 3600;
    $age = time() - (int) @filemtime($argv[1]);
    exit($age >= 0 && $age < $ttl ? 0 : 1);
    ' "$CACHE" "$TTL_HOURS"
}

probe() {
    local name path code
    name="$1"
    path="$(probe_path "$name")"
    # `-f` тут НЕ ставимо: нас цікавить сам код, а не тіло. Повторів на 404
    # http-request.sh не робить, тому проба коштує один запит.
    code="$("$SCRIPT_DIR/cli/api/http-request.sh" -sS -o /dev/null -w '%{http_code}' \
        -H "X-API-Key: $BDO_API_KEY" "$BDO_API_BASE/$path" 2>/dev/null || printf '000')"
    case "$code" in
        # 405 · маршрут Є, просто цей метод не для GET (памʼять читається POST-ом).
        200|201|204|400|405|422) printf 'yes' ;;
        404|501) printf 'no' ;;
        # Мережа лягла або ключ не той · це НЕ «можливості немає». Мовчазне
        # «no» тут вимкнуло б глосарій на старому API через хвилинний збій.
        *) printf 'unknown' ;;
    esac
}

# ЯКІ ГРУПИ ПОЛІВ приймає ця ціль · зі слів самої цілі.
#
# Клієнт просить у `/rows` шість груп (`classification`, `glossary`, `tokens`,
# `constraints`, `reference`, `patch`). Хаб 2026-09-06 приймає лише три
# (`core`, `layers`, `coordinates`) і на зайву відповідає `invalid_request` ·
# тобто вибірка падає ЦІЛКОМ, хоча рядки віддати він може. Тому перелік
# береться з `/taxonomy.field_groups`, а не з коду: коли хаб додасть групу,
# клієнт почне її просити сам, без правки.
taxonomy_fields() {
    "$SCRIPT_DIR/cli/api/http-request.sh" -sS -H "X-API-Key: $BDO_API_KEY" \
        "$BDO_API_BASE/taxonomy" 2>/dev/null \
        | php -r '
        $d = json_decode((string) stream_get_contents(STDIN), true) ?: [];
        $groups = $d["data"]["field_groups"] ?? null;
        // Порожній перелік і ВІДСУТНІЙ перелік · різні речі. Старий API групи
        // не оголошує взагалі, і це означає «приймаю всі», а не «жодної».
        echo is_array($groups) ? implode(",", $groups) : "";
        ' || printf ''
}

build_cache() {
    local name value first=1 groups
    mkdir -p "$STATE_DIR"
    groups="$(taxonomy_fields)"
    {
        printf '{"target":"%s","base":"%s","at":"%s","field_groups":"%s","items":{' \
            "$BDO_API_ENV" "$BDO_API_BASE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$groups"
        for name in $NAMES; do
            value="$(probe "$name")"
            test "$first" = 1 || printf ','
            first=0
            printf '"%s":"%s"' "$name" "$value"
        done
        printf '}}\n'
    } > "$CACHE.tmp"
    mv "$CACHE.tmp" "$CACHE"
}

fresh_cache || build_cache

read_value() {
    php -r '
    $d = json_decode((string) @file_get_contents($argv[1]), true) ?: [];
    echo (string) ($d["items"][$argv[2]] ?? "unknown");
    ' "$CACHE" "$1"
}

if [ -n "$FIELDS" ]; then
    # Перетин бажаного з дозволеним. Ціль, яка груп не оголошує (старий API),
    # приймає все · тоді віддаємо перелік як є.
    php -r '
    $cache = json_decode((string) @file_get_contents($argv[1]), true) ?: [];
    $allowed = array_filter(explode(",", (string) ($cache["field_groups"] ?? "")));
    $want = array_values(array_filter(array_map("trim", explode(",", $argv[2]))));
    // Ціль, яка груп не оголошує (старий API), приймає все · перелік іде
    // ДОСЛІВНО. Саме дослівно: додати сюди навіть безпечну групу означало б
    // тихо змінити запит робочої системи заради сумісності з іншою.
    if ($allowed === []) { echo implode(",", $want); exit; }
    $kept = array_values(array_intersect($want, $allowed));
    // Ціль приймає ВСЕ, що ми просимо · віддаємо перелік дослівно. Додати сюди
    // навіть безпечну групу означало б тихо змінити запит робочої системи
    // заради сумісності з іншою.
    if (count($kept) === count($want)) { echo implode(",", $want); exit; }
    // Щось відпало. Тоді `core` обовʼязковий: без нього рядок приходить без
    // `source_text`, і перекладати нема чого.
    if (! in_array("core", $kept, true) && in_array("core", $allowed, true)) {
        array_unshift($kept, "core");
    }
    echo implode(",", $kept);
    ' "$CACHE" "$FIELDS"
    printf '\n'
    exit 0
fi

if [ -n "$WANT" ]; then
    probe_path "$WANT" >/dev/null 2>&1 || { echo "capabilities: невідома можливість «${WANT}»" >&2; exit 2; }
    # НЕВІДОМО трактуємо як «є»: інакше мережевий збій тихо вимкнув би глосарій
    # на старому API, і пачка поїхала б без термінів, нікого не попередивши.
    case "$(read_value "$WANT")" in
        no) exit 1 ;;
        *)  exit 0 ;;
    esac
fi

printf 'Ціль: %s (%s)\n' "$BDO_API_ENV" "$BDO_API_BASE"
printf 'Перевірено: %s · кеш %s год (%s)\n\n' \
    "$(php -r '$d=json_decode((string)@file_get_contents($argv[1]),true)?:[];echo $d["at"]??"?";' "$CACHE")" \
    "$TTL_HOURS" "$CACHE"
for name in $NAMES; do
    case "$(read_value "$name")" in
        yes)     printf '  %-10s є\n' "$name" ;;
        no)      printf '  %-10s немає в цій цілі · крок працює без неї\n' "$name" ;;
        *)       printf '  %-10s НЕВІДОМО · API не відповів; вважаємо, що є\n' "$name" ;;
    esac
done
