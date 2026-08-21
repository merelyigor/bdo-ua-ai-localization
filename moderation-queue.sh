#!/usr/bin/env bash
# Черга модерації перекладів: подивитись і розібрати пачками через API.
#
#   ./moderation-queue.sh                          # показати чергу (20 перших)
#   ./moderation-queue.sh --limit 100              # більше за раз (стеля 100)
#   ./moderation-queue.sh --row <identity_hash>    # лише пропозиції цього рядка
#   ./bdo moderation --approve 12,15,18       # схвалити перелічені
#   ./moderation-queue.sh --reject 12,15 --reason "калька"
#   ./bdo moderation --approve-batch 20       # схвалити перші N з черги
#   ./bdo moderation --approve-batch 20 --dry # показати, кого б схвалив
#
# Навіщо: прогін пачками відправляє в чергу десятки рядків, і розбирати їх у
# адмінці кліками неможливо. Скрипт ходить у ті самі маршрути, що й UI-модератор
# (claim+decide workflow, той самий audit trail), тому «швидко» тут не означає
# «в обхід».
#
# Ключу потрібна здатність `translations:review`, а його власнику - право
# модерувати. Здатність сама нічого не дозволяє: якщо власник ключа не модератор,
# API поверне 403 навіть із увімкненою галочкою.
#
# `--approve-batch` навмисно вимагає ЧИСЛА, а не працює «до кінця»: масове
# схвалення наосліп - єдина операція тут, яку неможливо відкотити одним рухом.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/select-env.sh"

API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"
LIMIT=20
ROW=""
APPROVE_IDS=""
REJECT_IDS=""
REASON=""
BATCH=0
DRY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --limit) LIMIT="${2:?--limit потребує число}"; shift 2 ;;
        --row) ROW="${2:?--row потребує identity_hash}"; shift 2 ;;
        --approve) APPROVE_IDS="${2:?--approve потребує перелік id через кому}"; shift 2 ;;
        --reject) REJECT_IDS="${2:?--reject потребує перелік id через кому}"; shift 2 ;;
        --reason) REASON="${2:?--reason потребує текст}"; shift 2 ;;
        --approve-batch) BATCH="${2:?--approve-batch потребує число}"; shift 2 ;;
        --dry) DRY=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Невідомий аргумент: $1" >&2; exit 1 ;;
    esac
done

if [ -n "$REJECT_IDS" ] && [ -z "$REASON" ]; then
    echo "Для --reject потрібна --reason: без неї автор не дізнається, що не так." >&2
    exit 1
fi
case "$LIMIT" in ''|*[!0-9]*) echo "--limit має бути числом." >&2; exit 1 ;; esac
case "$BATCH" in ''|*[!0-9]*) echo "--approve-batch має бути числом." >&2; exit 1 ;; esac

# Порожня відповідь тут звичайна, а не виняткова: маршрут зʼявився 2026-08-21,
# і на середовищі без свіжого деплою curl мовчки віддає нуль байтів. Без цієї
# перевірки далі падав PHP із JsonException і стектрейсом, з якого причину не
# видно взагалі (перевірено на проді до деплою).
fetch_queue() {
    local query="per_page=$1" body
    [ -n "$ROW" ] && query="$query&identity_hash=$ROW"
    body="$(curl -fsS -H "X-API-Key: $KEY" "$API/translations/proposals?$query" || true)"
    if [ -z "$body" ]; then
        echo "API не віддав чергу: $API/translations/proposals" >&2
        echo "Причини за ймовірністю: маршрут ще не задеплоєний; у ключа немає" >&2
        echo "здатності translations:review; власник ключа не має права модерувати." >&2
        exit 1
    fi
    printf '%s' "$body"
}

# Рішення по одній пропозиції. Помилка на одному рядку не валить решту пачки:
# вона друкується й лічиться, бо через 158 рядків прикро зупинитись на 3-му.
decide_one() {
    local id="$1" action="$2" body="{}"
    [ -n "$REASON" ] && body="$(php -r 'echo json_encode(["reason" => $argv[1]], JSON_UNESCAPED_UNICODE);' "$REASON")"

    if curl -fsS -X POST -H "X-API-Key: $KEY" -H 'Content-Type: application/json' \
            -d "$body" "$API/translations/proposals/$id/$action" >/dev/null 2>&1; then
        printf '  %-8s #%s\n' "$action" "$id"
        return 0
    fi
    printf '  ПОМИЛКА  #%s (%s)\n' "$id" "$action" >&2
    return 1
}

decide_list() {
    local ids="$1" action="$2" ok=0 fail=0
    echo "$ids" | tr ',' '\n' | while read -r id; do
        [ -n "$id" ] || continue
        if [ "$DRY" = 1 ]; then printf '  [суха] %-8s #%s\n' "$action" "$id"; continue; fi
        if decide_one "$id" "$action"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    done
}

if [ -n "$APPROVE_IDS" ]; then
    echo "Схвалення:"; decide_list "$APPROVE_IDS" approve; exit 0
fi
if [ -n "$REJECT_IDS" ]; then
    echo "Відхилення (причина: $REASON):"; decide_list "$REJECT_IDS" reject; exit 0
fi

if [ "$BATCH" -gt 0 ]; then
    QUEUE_JSON="$(fetch_queue "$BATCH")"
    IDS="$(printf '%s' "$QUEUE_JSON" | php -r '
        $d = json_decode((string) file_get_contents("php://stdin"), true, 512, JSON_THROW_ON_ERROR);
        echo implode(",", array_column($d["data"]["proposals"] ?? [], "id"));
    ')"
    if [ -z "$IDS" ]; then echo "Черга порожня - схвалювати нема чого."; exit 0; fi
    COUNT="$(echo "$IDS" | tr ',' '\n' | grep -c .)"
    echo "Схвалюю $COUNT пропозицій із черги$([ "$DRY" = 1 ] && echo ' (суха)')":
    decide_list "$IDS" approve
    exit 0
fi

# Спершу у змінну, потім у php: `fetch_queue | php` ховає код виходу за пайпом,
# і навіть з `pipefail` php встигав упасти на порожньому вході раніше, ніж
# спрацьовував наш зрозумілий вихід.
QUEUE_JSON="$(fetch_queue "$LIMIT")"
printf '%s' "$QUEUE_JSON" | php -r '
$d = json_decode((string) file_get_contents("php://stdin"), true, 512, JSON_THROW_ON_ERROR);
$rows = $d["data"]["proposals"] ?? [];
$meta = $d["meta"] ?? [];
printf("Чекають на рішення: %d (показано %d)%s", $meta["total_matching"] ?? 0, count($rows), PHP_EOL);
echo str_repeat("=", 78), PHP_EOL;
foreach ($rows as $r) {
    printf("#%-6s %s%s", $r["id"], $r["identity_hash"] ?? "?", PHP_EOL);
    printf("   було:  %s%s", $r["source_text"] ?? "", PHP_EOL);
    printf("   стало: %s%s", $r["text"] ?? "", PHP_EOL);
}
if ($rows !== []) {
    echo str_repeat("=", 78), PHP_EOL;
    echo "Схвалити всі показані: ./bdo moderation --approve ",
         implode(",", array_column($rows, "id")), PHP_EOL;
}
'
