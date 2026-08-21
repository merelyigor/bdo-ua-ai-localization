#!/usr/bin/env bash
# Перевірити immutable identity канонічної назви через POST /glossary/terms/resolve.
#
#   ./glossary-resolve.sh "Agris Gold Coin"
#   ./glossary-resolve.sh "Agris Gold Coin" <identity_hash>
#
# Другий аргумент потрібен, коли однакову назву мають кілька сутностей: тоді
# resolve без identity повертає blocked_identity. Хеш беруть із того самого
# rows.json, а не звідкись іще.
#
# Чому скрипт, а не curl руками: субагент не знає базового URL і вигадує його.
# Реальний випадок - виклик пішов на http://localhost/glossary/terms/resolve і
# впав. Тут URL і ключ підставляє select-env.sh, а не модель.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/select-env.sh"

CANONICAL="${1:?Потрібен canonical_source, точно як в English source}"
IDENTITY_HASH="${2:-}"

if [ -n "$IDENTITY_HASH" ] && [[ ! "$IDENTITY_HASH" =~ ^[0-9a-f]{64}$ ]]; then
    echo "identity_hash має бути 64 малих hex-символи." >&2
    exit 1
fi

PAYLOAD="$(php -r '
$body = ["canonical_source" => $argv[1]];
if ($argv[2] !== "") $body["source_identity"] = ["identity_hash" => $argv[2]];
echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
' "$CANONICAL" "$IDENTITY_HASH")"

RESPONSE="$(curl -sS -X POST \
    -H "X-API-Key: $BDO_API_KEY" \
    -H "Content-Type: application/json" \
    --data "$PAYLOAD" \
    "$BDO_API_BASE/glossary/terms/resolve")"

php -r '
require $argv[3];
$d = Bdo\Translate\Api\Response::fromJson($argv[1], "glossary/terms/resolve")->raw();
if (!is_array($d)) { fwrite(STDERR, "Некоректна відповідь API:\n" . $argv[1] . "\n"); exit(1); }
$res = $d["data"]["resolution"] ?? [];
$status = $res["status"] ?? ($d["error"]["code"] ?? "?");
$c = $res["candidate"] ?? [];
printf("canonical_source: %s\n", $argv[2]);
printf("status: %s\n", $status);
foreach (["term_id", "entity_type", "category", "external_id"] as $k) {
    if (isset($c[$k])) printf("%s: %s\n", $k, $c[$k]);
}
if (isset($c["source_identity"])) {
    printf("source_identity: %s\n", json_encode($c["source_identity"], JSON_UNESCAPED_UNICODE));
}
$msg = $d["error"]["message"] ?? ($res["message"] ?? null);
if ($msg) printf("message: %s\n", $msg);
if ($status === "ready") {
    echo "\nВИРОК: identity підтверджена. Подавай proposal із цим term_id і цією source_identity.\n";
} elseif ($status === "blocked_identity") {
    echo "\nВИРОК: identity не підтверджена. Повтори з identity_hash того рядка,\n";
    echo "для якого перекладаєш. Вибирати сутність навмання заборонено.\n";
} else {
    echo "\nВИРОК: несподіваний статус, не вигадуй entity - покажи це власнику.\n";
}
' "$RESPONSE" "$CANONICAL" "$SCRIPT_DIR/lib/autoload.php"
