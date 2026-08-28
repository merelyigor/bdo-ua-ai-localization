#!/usr/bin/env bash
# Підготувати завдання для child `translation-glossary`: описати терміни з черги.
#
#   ./term-notes-describe.sh          # payload + envelope для наступного Task
#
# Черга наповнюється сама під час прогону (`cli/api/term-notes-queue.sh`) і
# містить ЛИШЕ терміни з доведено порожнім описом · тобто такі, де опис не може
# нічого перезаписати. Тут ми беремо найчастіші й будуємо для них payload.
#
# Виводить той самий envelope, що й `run drive`, тому диригент обробляє його
# звичайним CHILD-КОНТРАКТОМ і нічого нового вчити не мусить.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
QUEUE="$STATE_DIR/term-notes-queue.json"
PAYLOAD="$STATE_DIR/term-notes-payload.json"
RESPONSE="$STATE_DIR/term-notes-response.json"

emit() { php -r 'echo json_encode(json_decode($argv[1], true, 512, JSON_THROW_ON_ERROR), JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES), "\n";' "$1"; }

if [ ! -s "$QUEUE" ]; then
    emit '{"ok":true,"next":{"kind":"complete","reason":"queue_empty"}}'
    exit 0
fi

rm -f "$RESPONSE"
php -r '
$queue = json_decode((string) file_get_contents($argv[1]), true)["terms"] ?? [];
$done = is_file($argv[3]) ? (json_decode((string) file_get_contents($argv[3]), true)["terms"] ?? []) : [];
$limit = (int) (getenv("BDO_TERM_NOTES_BATCH") ?: 10);

// Найчастіші спершу: опис до терміна, який трапляється в тисячах рядків,
// вартий більше за опис до одноразової назви.
usort($queue, static fn (array $a, array $b): int => ($b["seen"] ?? 0) <=> ($a["seen"] ?? 0));
$items = [];
foreach ($queue as $term) {
    if (count($items) >= $limit) break;
    $name = (string) ($term["canonical_source"] ?? "");
    // Уже пропонували · вдруге не йдемо, навіть якщо модератор ще не вирішив.
    if ($name === "" || in_array($name, $done, true)) continue;
    // Без identity й snapshot пропозицію не прийме сервер · такий термін
    // дочекається пачки, де він трапиться з рядком.
    if (! isset($term["identity_hash"], $term["snapshot_id"])) continue;
    $items[] = [
        "canonical_source" => $name,
        "ukrainian" => (string) ($term["ukrainian"] ?? ""),
        "entity_type" => $term["entity_type"] ?? null,
        "samples" => array_slice($term["samples"] ?? [], 0, 3),
    ];
}
file_put_contents($argv[2], json_encode(["items" => $items], JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
fprintf(STDERR, "Опис термінів: у завданні %d із %d у черзі\n", count($items), count($queue));
echo count($items), "\n";
' "$QUEUE" "$PAYLOAD" "$STATE_DIR/proposed-term-notes.json" > "$STATE_DIR/.term-notes-count"

COUNT="$(cat "$STATE_DIR/.term-notes-count")"
rm -f "$STATE_DIR/.term-notes-count"
if [ "${COUNT:-0}" -eq 0 ]; then
    emit '{"ok":true,"next":{"kind":"complete","reason":"nothing_to_describe"}}'
    exit 0
fi

php -r 'echo json_encode([
    "kind" => "child",
    "role" => "translation-glossary",
    "payload_path" => $argv[1],
    "response_path" => $argv[2],
    "prompt" => "payload:".$argv[1],
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);' "$PAYLOAD" "$RESPONSE" > "$STATE_DIR/next-child.json"
php -r 'echo json_encode(["ok" => true, "next" => json_decode((string) file_get_contents($argv[1]), true)],
    JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), "\n";' "$STATE_DIR/next-child.json"
