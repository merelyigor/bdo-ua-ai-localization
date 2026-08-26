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

# 3. Карантин читається однією командою.
#
# Реєстру `run-seen.json` більше немає (перевірено на бойовому API 2026-08-26:
# фільтр `missing=` точний), тому повертати рядки в чергу не треба · сервер і
# далі їх віддає. Лишається одне: карантин мусить бути ЧИТАБЕЛЬНИМ, інакше він
# знову стане файлом, у який ніхто не дивиться.
mkdir -p "$TMP/state"
HASH_A="$(printf a | shasum -a 256 | awk '{print $1}')"
HASH_B="$(printf b | shasum -a 256 | awk '{print $1}')"
printf '%s\n' \
    "{\"identity_hash\":\"$HASH_A\",\"reason\":\"api_source_equivalent\",\"channel\":\"proposal\",\"candidate\":\"Elion\"}" \
    "{\"identity_hash\":\"$HASH_B\",\"reason\":\"api_source_equivalent\",\"channel\":\"machine\",\"candidate\":\"Kamasylvia\"}" \
    > "$TMP/state/quarantine.jsonl"

report="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/audit/quarantine-report.sh")"
printf '%s' "$report" | grep -q 'api_source_equivalent        2' || fail "зведення не порахувало причини: $report"
printf '%s' "$report" | grep -q 'machine  *1' || fail "зведення не розділило канали: $report"

listing="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/audit/quarantine-report.sh" --list 1)"
printf '%s' "$listing" | grep -q 'Kamasylvia' || fail "--list не показав кандидата: $listing"

BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/audit/quarantine-report.sh" --clear >/dev/null
test ! -s "$TMP/state/quarantine.jsonl" || fail '--clear не очистив карантин'

# Прапорця `--requeue` більше немає: реєстр, який він розблоковував, прибрано.
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/audit/quarantine-report.sh" --requeue >/dev/null 2>&1 \
    && fail 'знятий прапорець --requeue досі приймається'

echo 'quarantine recovery: OK'
