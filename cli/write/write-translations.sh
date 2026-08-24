#!/usr/bin/env bash
# Записати переклади через POST /translations.
# Контракт доступу: API_WRITE_CONTRACT.md.
#
# Використання:
#   ./write-translations.sh <items.json> [provider] [model]
#   ./write-translations.sh --channel proposal <items.json>
#   ./write-translations.sh --idempotency-key <stable-key> <items.json>
#
# Канали (власник обирає явно):
#   machine  - layer=machine, mode=direct. ШІ-шар, як і раніше (типово).
#   manual   - layer=manual, mode=proposal, auto_approve=true. Те саме, що ручна
#              правка на сайті: сервер схвалює лише за дозволом API-ключа;
#              інакше рядок лишається пропозицією на модерацію.
#   proposal - те саме, але auto_approve=false: рядок лишається в черзі
#              навіть для ключа з правом схвалення. Це заміна файлового карантину - недосконалий переклад
#              краще показати в адмінці, ніж лишити у state/quarantine.jsonl.
#
# Формат items.json:
#   [{"identity_hash": "...", "source_hash": "...", "text": "переклад"}, ...]
#
# Вихід: ./output/write_YYYYMMDD_HHMMSS.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$SCRIPT_DIR/cli/system/select-env.sh"

CHANNEL=machine
IDEMPOTENCY_KEY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --channel)
            CHANNEL="${2:?--channel потребує machine|manual|proposal}"
            shift 2
            ;;
        --idempotency-key)
            IDEMPOTENCY_KEY="${2:?--idempotency-key потребує непорожній ключ}"
            shift 2
            ;;
        *) break ;;
    esac
done
case "$CHANNEL" in
    machine) LAYER=machine; MODE=direct;  AUTO_APPROVE=true ;;
    manual)  LAYER=manual;  MODE=proposal; AUTO_APPROVE=true ;;
    proposal) LAYER=manual; MODE=proposal; AUTO_APPROVE=false ;;
    *) echo "Дозволено --channel machine|manual|proposal, отримано '$CHANNEL'." >&2; exit 1 ;;
esac

INPUT="${1:?Потрібен файл items.json}"
PROVIDER="${2:-local-agent}"
MODEL="${3:-agent-local}"
API="${BDO_API_BASE:?}"
KEY="${BDO_API_KEY:?}"

mkdir -p "$SCRIPT_DIR/output"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT="$SCRIPT_DIR/output/write_${TIMESTAMP}.json"

# Прямий запис у machine-шар навмисно доступний не кожному ключу. Перевіряємо
# контракт до побудови payload, щоб скрипт не витрачав квоту запитом, який
# сервер гарантовано відхилить.
ME=$("$SCRIPT_DIR/cli/api/http-request.sh" -fsS -H "X-API-Key: $KEY" "$API/me")
test "$CHANNEL" = machine || ME='{"data":{"user":{"role":"admin"},"effective_abilities":["translations:write-machine"]}}'
php -r '
$me = json_decode($argv[1], true);
$role = $me["data"]["user"]["role"] ?? null;
$abilities = $me["data"]["effective_abilities"] ?? [];
if (!in_array($role, ["admin", "super_admin"], true)
    || !in_array("translations:write-machine", $abilities, true)) {
    fwrite(STDERR, "Цей ключ не має доступу до machine + direct. Потрібні роль admin/super_admin і translations:write-machine у /me.\n");
    exit(1);
}
' "$ME"

# Формуємо payload
php -r '
require $argv[3];
use Bdo\Translate\Api\WritePayload;

$items = json_decode((string) file_get_contents($argv[1]), true);
if (!is_array($items)) $items = [];
try {
    $payload = WritePayload::build($items, $argv[4], $argv[5], $argv[6], $argv[7], $argv[8] === "true");
} catch (RuntimeException $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(1);
}
file_put_contents($argv[2], json_encode($payload, JSON_UNESCAPED_UNICODE));
echo "Підготовлено " . count($items) . " елементів\n";
' "$INPUT" "$OUT" "$SCRIPT_DIR/lib/autoload.php" "$PROVIDER" "$MODEL" "$LAYER" "$MODE" "$AUTO_APPROVE"

# Без явного ключа ручний запуск лишається безпечним від випадкового replay.
# Рушій завжди подає стабільний ключ, похідний від manifest та items.
if [ -z "$IDEMPOTENCY_KEY" ]; then
    IDEMPOTENCY_KEY=$(php -r 'echo bin2hex(random_bytes(16));')
fi

echo "Канал: $CHANNEL (layer=$LAYER, mode=$MODE, auto_approve=$AUTO_APPROVE)"
echo "Записую з Idempotency-Key=$IDEMPOTENCY_KEY..."
RESPONSE=$("$SCRIPT_DIR/cli/api/http-request.sh" -fsS -X POST \
    -H "X-API-Key: $KEY" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: $IDEMPOTENCY_KEY" \
    --data @"$OUT" \
    "$API/translations")

echo "$RESPONSE" > "$OUT"

echo ""
php -r '
require $argv[2];
use Bdo\Translate\Api\Response;

$response = Response::fromFile($argv[1], "POST /translations");
$meta = $response->meta();
$rejected = (int) ($meta["rejected"] ?? 0);

printf("Записано: %d  Пропущено: %d  Відкинуто: %d\n",
    $meta["written"] ?? 0, $meta["skipped"] ?? 0, $rejected);
printf("Лишилось у квоті: %s\n", $meta["rows_remaining_today"] ?? "?");

foreach ($response->results() as $r) {
    $status = (string) ($r["status"] ?? "");
    if (in_array($status, ["ok", "repaired", "unchanged"], true)) continue;
    printf("  [%s] %s: %s\n", $r["index"] ?? "?", $status, mb_substr((string) ($r["message"] ?? ""), 0, 100));
    if (!empty($r["code"])) printf("         code=%s\n", $r["code"]);
}

if (getenv("FAIL_ON_REJECTED") === "1" && $rejected > 0) exit(2);
' "$OUT" "$SCRIPT_DIR/lib/autoload.php"

# Незнищенний слід запису. Файл-квитанція в output/ живе доти, доки його не
# приберуть: на прогоні 2026-08-16 диригент стер її власним `rm` разом із
# робочими файлами, і перевірити, що саме записано, стало неможливо. Цей журнал
# доповнюється одним рядком і не входить у жодне автоматичне прибирання.
php -r '
require $argv[1];
use Bdo\Translate\Api\Response;
$response = Response::fromFile($argv[2], "POST /translations");
$meta = $response->meta();
$line = json_encode([
    "at" => $argv[3],
    "env" => $argv[4],
    "channel" => $argv[5],
    "layer" => $meta["layer"] ?? null,
    "mode" => $meta["mode"] ?? null,
    "auto_approve" => $meta["auto_approve"] ?? null,
    "items" => $meta["items"] ?? null,
    "written" => $meta["written"] ?? null,
    "rejected" => $meta["rejected"] ?? null,
    "receipt" => basename($argv[2]),
    "idempotency_key_sha256" => hash("sha256", $argv[7]),
], JSON_UNESCAPED_UNICODE);
file_put_contents($argv[6], $line . "\n", FILE_APPEND);
' "$SCRIPT_DIR/lib/autoload.php" "$OUT" "$TIMESTAMP" "$BDO_API_ENV" "$CHANNEL" "${BDO_STATE_DIR:-$SCRIPT_DIR/state}/write-log.jsonl" "$IDEMPOTENCY_KEY"

# Те, що сервер відхилив, не має зникати. На прогоні 2026-08-16 шість рядків
# отримали save_failed («зайве \n») і не потрапили нікуди: ні в шар, ні в
# модерацію, ні в карантин - їх просто не стало. Карантин тут і є тим місцем,
# де видно роботу, яку не вдалося закрити.
php -r '
require $argv[1];
use Bdo\Translate\Api\Response;
$response = Response::fromFile($argv[2], "POST /translations");
$items = json_decode((string) file_get_contents($argv[3]), true) ?: [];
$stamp = date("c");
$lost = 0;
$fh = fopen($argv[4], "a");
foreach ($response->results() as $r) {
    if (in_array($r["status"] ?? "", ["ok", "repaired", "unchanged", "skipped"], true)) continue;
    $index = $r["index"] ?? null;
    fwrite($fh, json_encode([
        "identity_hash" => $r["identity_hash"] ?? ($items[$index]["identity_hash"] ?? null),
        "reason" => "api_" . ($r["code"] ?? "rejected"),
        "detail" => mb_substr((string) ($r["message"] ?? ""), 0, 200),
        "candidate" => $items[$index]["text"] ?? null,
        "at" => $stamp, "env" => $argv[5], "channel" => $argv[6],
    ], JSON_UNESCAPED_UNICODE) . "\n");
    $lost++;
}
fclose($fh);
if ($lost > 0) printf("У КАРАНТИН: %d рядків, які API відхилив.\n", $lost);
' "$SCRIPT_DIR/lib/autoload.php" "$OUT" "$INPUT" "${BDO_STATE_DIR:-$SCRIPT_DIR/state}/quarantine.jsonl" "$BDO_API_ENV" "$CHANNEL"

echo ""
echo "Деталі: $OUT"
echo "Журнал: ${BDO_STATE_DIR:-$SCRIPT_DIR/state}/write-log.jsonl"
