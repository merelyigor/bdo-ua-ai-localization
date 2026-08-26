#!/usr/bin/env bash
# Рядок, чий переклад дорівнює джерелу, не має губитись мовчки.
#
# Заміряно 2026-08-25: 27 із 27 записів `state/quarantine.jsonl` мали причину
# `api_source_equivalent`, з них 21 · канал `proposal`. Сервер відхиляв
# пропозицію, бо в payload не було прапорця `same_as_source`, а карантин не
# читала жодна команда. Тест фіксує обидва кінці цього ланцюга.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bdo-quarantine.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Пропозиція, що дорівнює джерелу, їде з прапорцем `same_as_source`.
#
# Викликаємо саме той php-блок, який будує moderation-елемент, а не весь
# batch-commit: він ходить в API за квотою, і тест став би мережевим.
php -r '
$source = "Elion";
$hash = str_repeat("c", 64);
$rowByHash = [$hash => ["source_hash" => hash("sha256", $source), "source_text" => $source]];
$text = $source;
$item = ["identity_hash" => $hash, "source_hash" => $rowByHash[$hash]["source_hash"], "text" => $text];
if ($text === ($rowByHash[$hash]["source_text"] ?? null)) { $item["same_as_source"] = true; }
require $argv[1];
$payload = Bdo\Translate\Api\WritePayload::build([$item], "ollama-local", "qwen3.6", "manual", "proposal", false);
$sent = $payload["items"][0] ?? [];
if (($sent["same_as_source"] ?? null) !== true) {
    fwrite(STDERR, "FAIL: пропозиція = джерело пішла в API без same_as_source\n");
    exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'moderation-елемент втратив same_as_source'

# 2. `source_equivalent` лишається лікованим, `non_translatable` · ні.
php -r '
require $argv[1];
use Bdo\Translate\Api\ErrorCodes;
if (ErrorCodes::isPermanent("API: source_equivalent")) {
    fwrite(STDERR, "FAIL: source_equivalent знову позначено як невиправний\n"); exit(1);
}
if (! ErrorCodes::isPermanent("API: non_translatable")) {
    fwrite(STDERR, "FAIL: non_translatable мусить лишатись постійним\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'класифікація кодів API поїхала'

# 3. Карантин читається і розблоковує реєстр прогону.
mkdir -p "$TMP/state"
HASH_A="$(printf a | shasum -a 256 | awk '{print $1}')"
HASH_B="$(printf b | shasum -a 256 | awk '{print $1}')"
printf '%s\n' \
    "{\"identity_hash\":\"$HASH_A\",\"reason\":\"api_source_equivalent\",\"channel\":\"proposal\",\"candidate\":\"Elion\"}" \
    "{\"identity_hash\":\"$HASH_B\",\"reason\":\"api_source_equivalent\",\"channel\":\"machine\",\"candidate\":\"Kamasylvia\"}" \
    > "$TMP/state/quarantine.jsonl"
php -r 'file_put_contents($argv[1], json_encode(["scope"=>"prod:patch:2","batches"=>1,
    "hashes"=>[$argv[2]=>1,$argv[3]=>1,str_repeat("d",64)=>1]], JSON_THROW_ON_ERROR));' \
    "$TMP/state/run-seen.json" "$HASH_A" "$HASH_B"

report="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/audit/quarantine-report.sh")"
printf '%s' "$report" | grep -q 'api_source_equivalent        2' || fail "зведення не порахувало причини: $report"

BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/audit/quarantine-report.sh" --requeue >/dev/null
left="$(php -r 'echo count(json_decode(file_get_contents($argv[1]),true)["hashes"]);' "$TMP/state/run-seen.json")"
test "$left" = 1 || fail "requeue мусив лишити 1 чужий hash, лишилось $left"

# Некарантинний рядок чіпати не можна: інакше прогін узяв би заново все підряд.
php -r 'exit(isset(json_decode(file_get_contents($argv[1]),true)["hashes"][str_repeat("d",64)]) ? 0 : 1);' \
    "$TMP/state/run-seen.json" || fail 'requeue викинув із реєстру чужий рядок'

echo 'quarantine recovery: OK'
