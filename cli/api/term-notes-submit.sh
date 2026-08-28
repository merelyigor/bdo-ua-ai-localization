#!/usr/bin/env bash
# Надіслати описи термінів як пропозиції · з повторною перевіркою перед записом.
#
#   ./term-notes-submit.sh
#
# Правило безпеки даних (AGENTS.md, дефект D18): пропозиція можлива ЛИШЕ коли
# API прямо каже, що опис порожній. Стан із черги для цього не годиться · між
# збиранням і надсиланням минають хвилини або дні, і людина могла вже написати
# опис. Тому кожен термін перечитується з API безпосередньо перед надсиланням:
#   опис є     · пропускаємо, чужу роботу не чіпаємо;
#   поля немає · пропускаємо ВГОЛОС, бо «невідомо» не дорівнює «порожньо»;
#   опису немає· надсилаємо.
#
# `ukrainian` НІКОЛИ не змінюється: у пропозицію йде рівно те значення, яке
# зараз затверджене на сервері. Ми доповнюємо опис, а не переклад.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
RESPONSE="$STATE_DIR/term-notes-response.json"
QUEUE="$STATE_DIR/term-notes-queue.json"
SENT="$STATE_DIR/proposed-term-notes.json"

test -s "$RESPONSE" || { echo 'Немає відповіді child · спочатку ./bdo terms describe і Task.' >&2; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cli/system/select-env.sh"

php -r '
$answer = json_decode((string) file_get_contents($argv[1]), true);
$items = $answer["items"] ?? $answer;
if (! is_array($items)) { fwrite(STDERR, "Відповідь child не є масивом.\n"); exit(1); }
$queue = json_decode((string) file_get_contents($argv[2]), true)["terms"] ?? [];
$byName = [];
foreach ($queue as $term) $byName[(string) ($term["canonical_source"] ?? "")] = $term;

$minConfidence = (int) (getenv("BDO_TERM_NOTES_MIN_CONFIDENCE") ?: 60);
$maxSend = (int) (getenv("BDO_TERM_NOTES_MAX_SEND") ?: 3);
$http = $argv[5];
$api = $argv[6];
$key = $argv[7];

$call = static function (string $url, ?string $body) use ($http, $key): ?array {
    $command = escapeshellarg($http)." -fsS -H ".escapeshellarg("X-API-Key: ".$key);
    if ($body !== null) {
        $command .= " -X POST -H ".escapeshellarg("Content-Type: application/json")." -d ".escapeshellarg($body);
    }
    $command .= " ".escapeshellarg($url)." 2>/dev/null";
    $lines = []; $status = 0;
    exec($command, $lines, $status);
    if ($status !== 0) return null;
    $data = json_decode(implode("\n", $lines), true);
    return is_array($data) ? $data : null;
};

$sentBefore = is_file($argv[3]) ? (json_decode((string) file_get_contents($argv[3]), true)["terms"] ?? []) : [];
$sent = $sentBefore;
$posted = 0; $lowConfidence = 0; $alreadyHas = 0; $unknown = 0; $empty = 0;

foreach ($items as $item) {
    if ($posted >= $maxSend) break;
    $name = trim((string) ($item["canonical_source"] ?? ""));
    $gist = trim((string) ($item["gist"] ?? ""));
    $definition = trim((string) ($item["definition"] ?? ""));
    $confidence = (int) ($item["confidence"] ?? 0);
    if ($name === "" || ! isset($byName[$name])) continue;
    if ($gist === "" && $definition === "") { $empty++; continue; }
    // Поріг · рішення власника (60). Самозвітна впевненість не є доказом
    // правильності, тому вона лише ВІДСІЮЄ явну невпевненість; справжні ворота
    // нижче · свіжий стан терміна й модерація.
    if ($confidence < $minConfidence) { $lowConfidence++; continue; }

    $fresh = $call($api."/glossary/terms?q=".rawurlencode($name)."&match=exact", null);
    $term = $fresh["data"]["terms"][$name] ?? null;
    if (! is_array($term) || ! isset($term["term_id"])) { $unknown++; continue; }
    if (! array_key_exists("definition", $term)) { $unknown++; continue; }
    if (is_string($term["definition"]) && trim($term["definition"]) !== "") { $alreadyHas++; continue; }
    $ukrainian = (string) ($term["ukrainian"] ?? "");
    if ($ukrainian === "") { $unknown++; continue; }

    $body = [
        "term_id" => (int) $term["term_id"],
        "canonical_source" => $name,
        // Рівно чинний відповідник: ми доповнюємо опис, а не переклад.
        "ukrainian" => $ukrainian,
        "source_identity" => [
            "identity_hash" => (string) $byName[$name]["identity_hash"],
            "source_snapshot_id" => (int) $byName[$name]["snapshot_id"],
        ],
        "provider" => "opencode",
        "model" => getenv("TRANSLATE_MODEL") ?: "unknown",
    ];
    if ($gist !== "") $body["gist"] = mb_substr($gist, 0, 200);
    if ($definition !== "") $body["definition"] = mb_substr($definition, 0, 4000);

    $result = $call($api."/glossary/proposals", json_encode($body, JSON_UNESCAPED_UNICODE));
    if ($result === null) { fprintf(STDERR, "  %s · сервер відхилив пропозицію\n", $name); continue; }
    $posted++;
    $sent[] = $name;
    fprintf(STDERR, "  %s · пропозицію надіслано (впевненість %d)\n", $name, $confidence);
}

file_put_contents($argv[3], json_encode(
    ["updated_at" => gmdate("c"), "terms" => array_values(array_unique($sent))],
    JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR,
));

// Кожна причина пропуску названа: мовчазний нуль читався б як «нічого не було».
printf(
    "Пропозицій надіслано: %d. Пропущено · низька впевненість %d, опис уже є %d, стан невідомий %d, порожня відповідь %d.\n",
    $posted, $lowConfidence, $alreadyHas, $unknown, $empty,
);
' "$RESPONSE" "$QUEUE" "$SENT" "$SCRIPT_DIR/lib/autoload.php" \
  "$SCRIPT_DIR/cli/api/http-request.sh" "$BDO_API_BASE" "$BDO_API_KEY"

rm -f "$RESPONSE" "$STATE_DIR/term-notes-payload.json"
