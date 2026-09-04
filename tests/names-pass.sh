#!/usr/bin/env bash
# Один короткий прохід по НАЗВАХ перед записом (пункт C плану QA_SCOPE_AND_ROLES).
#
# Фінальна валідація відхиляє рядок кодом `glossary_violation` і каже точно,
# чого бракує (`details.glossary[].expected`). Досі такий рядок ішов у
# модерацію, де сервер відмовляв тим самим правилом (D56), і повертався в
# наступну пачку (D58). Тут рушій дає repair один прохід із єдиним наказом
# «ужий «X» для «Y»» і повертає пачку до запису; другого проходу не буває.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"; mkdir -p "$STATE"

# 1. Машина станів знає прохід і дорогу назад.
php -r 'require $argv[1];
    use Bdo\Translate\Pipeline\StateMachine;
    StateMachine::assertTransition("ready_to_commit", "names_pass");
    StateMachine::assertTransition("names_pass", "ready_to_commit");
    StateMachine::assertTransition("retry_scheduled", "names_pass");
    try { StateMachine::assertTransition("committing", "names_pass"); fwrite(STDERR, "committing -> names_pass дозволено\n"); exit(1); } catch (RuntimeException) {}' \
    "$ROOT/lib/autoload.php" || fail 'машина станів не знає проходу по назвах або дозволяє його з committing'

H1="$(printf 1 | shasum -a 256 | awk '{print $1}')"
H2="$(printf 2 | shasum -a 256 | awk '{print $1}')"
php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [
    ["identity_hash" => $argv[2], "source_hash" => hash("sha256", "Move"), "source_text" => "Move",
     "glossary" => ["terms" => [["canonical_source" => "Move", "ukrainian" => "Переміщення", "severity" => "mandatory"]]]],
    ["identity_hash" => $argv[3], "source_hash" => hash("sha256", "Iron Sword"), "source_text" => "Iron Sword"],
]]], JSON_THROW_ON_ERROR));' "$STATE/rows.json" "$H1" "$H2"

# Відповідь validate: перший рядок без затвердженої назви, другий чистий.
php -r 'file_put_contents($argv[1], json_encode(["success" => true, "data" => ["results" => [
    ["index" => 0, "identity_hash" => $argv[2], "status" => "rejected", "code" => "glossary_violation",
     "message" => "Текст розходиться з глосарієм: не видно узгодженої назви «Переміщення».",
     "details" => ["glossary" => [["termId" => 79353, "canonical" => "Move", "expected" => "Переміщення", "issue" => "missing_translation", "severity" => "mandatory"]]]],
    ["index" => 1, "identity_hash" => $argv[3], "status" => "ok"],
]], "meta" => ["items" => 2, "rejected" => 1]], JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE));' "$STATE/validate.json" "$H1" "$H2"

# 2. Сам payload: лише рядок із наказом, наказ · єдиний дефект.
php -r 'file_put_contents($argv[1], json_encode([["identity_hash" => $argv[2], "text" => "Рух"], ["identity_hash" => $argv[3], "text" => "Залізний меч"]], JSON_THROW_ON_ERROR));' \
    "$STATE/final-candidate.json" "$H1" "$H2"
payload="$(bash "$ROOT/cli/prepare/names-payload.sh" "$STATE/rows.json" "$STATE/final-candidate.json" "$STATE/validate.json" 2>/dev/null)"
test "$(jq 'length' <<<"$payload")" = 1 || fail "у payload мусив бути 1 рядок: $payload"
jq -e --arg h "$H1" '.[0].identity_hash == $h and .[0].current == "Рух" and .[0].defects == ["ужий «Переміщення» для «Move»"]' <<<"$payload" >/dev/null \
    || fail "payload не несе єдиного наказу: $payload"

# 3. Рушій: із ready_to_commit пачка іде в names_pass до repair, і лише раз.
cat > "$TMP/.env" <<ENV
BDO_ENV=DEV
BDO_API_BASE_DEV=http://127.0.0.1:1
BDO_API_KEY_DEV=test
ENV
BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-new.sh" "$STATE/rows.json" >/dev/null
B="$(BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-dir.sh")"
php -r '$m=json_decode(file_get_contents($argv[1]),true);$m["state"]="ready_to_commit";$m["mode"]="patch";$m["channel"]="machine";
    file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));' "$B/manifest.json"
cp "$STATE/final-candidate.json" "$B/final-candidate.json"
php -r 'file_put_contents($argv[1], json_encode([
    ["identity_hash" => $argv[2], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
    ["identity_hash" => $argv[3], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""]], JSON_THROW_ON_ERROR));' \
    "$B/final-verdicts.json" "$H1" "$H2"
drive() { TRANSLATE_ENV_FILE="$TMP/.env" BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 BDO_FINAL_VALIDATE_STUB="$STATE/validate.json" \
    BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null | tail -1; }

out="$(drive)"
jq -e '.state == "names_pass" and .next.kind == "child" and .next.role == "translation-repair"' <<<"$out" >/dev/null \
    || fail "пачка не пішла в прохід по назвах: $out"
test "$(jq 'length' "$B/names-payload.json")" = 1 || fail 'payload проходу має не 1 рядок'
grep -q '"child_dispatch:translation-repair:1"' "$B/journal.jsonl" || fail 'журнал не бачить проходу по назвах'
# Схема під ПІДМНОЖИНУ: один рядок, а не вся пачка.
test "$(jq '.properties.items.items.properties.identity_hash.enum | length' "$STATE/current-response-schema.json")" = 1 \
    || fail 'схема repair побудована не під підмножину проходу'

# 4. Відповідь repair зливається у фінальний текст, пачка повертається до запису.
php -r 'file_put_contents($argv[1], json_encode([["identity_hash" => $argv[2], "text" => "Переміщення"]], JSON_THROW_ON_ERROR));' "$B/names-fixes.json" "$H1"
out="$(drive)"
jq -e '.state == "ready_to_commit" and .next.reason == "names_fixed"' <<<"$out" >/dev/null \
    || fail "після відповіді repair пачка не повернулась до запису: $out"
jq -e --arg h "$H1" '.[] | select(.identity_hash == $h) | .text == "Переміщення"' "$B/final-candidate.json" >/dev/null \
    || fail 'виправлена назва не потрапила у фінальний кандидат'
jq -e --arg h "$H2" '.[] | select(.identity_hash == $h) | .text == "Залізний меч"' "$B/final-candidate.json" >/dev/null \
    || fail 'чистий рядок зіпсовано злиттям'
jq -e '.steps.names.artifact == "final-candidate.json"' "$B/manifest.json" >/dev/null || fail 'manifest не записав крок names'

# 5. Другого проходу не буває: та сама відмова validate більше не веде в names_pass.
#    Пачка йде на запис, а запис у 127.0.0.1:1 законно падає · нас цікавить лише
#    те, що repair не викликано вдруге. Голе `x="$(cmd)"` під set -e тут
#    зʼїло б цю відмову мовчки (§12), тому код виходу приймається явно.
out="$(drive)" || true
jq -e '.state != "names_pass" and (.next.role // "") != "translation-repair"' <<<"$out" >/dev/null \
    || fail "прохід по назвах повторився: $out"

# 6. Вимикач і межа: без validate або з BDO_NAMES_PASS=off проходу немає · це у коді, не в промпті.
grep -Fq 'BDO_NAMES_PASS:-on' "$ROOT/cli/run/run-drive.sh" || fail 'немає вимикача проходу по назвах'
grep -Fq 'names-pass.done' "$ROOT/cli/run/run-drive.sh" || fail 'немає межі «один прохід на пачку»'
# Репарувальник мусить знати, що означає наказ · це виміряний дефект промпта, а не смак.
grep -Fq 'Дефект виду «ужий «X» для «Y»» означає' "$ROOT/roles/translation-repair.md" \
    || fail 'промпт repair не пояснює наказ «ужий»'

echo 'names pass: OK · один прохід по назвах перед записом, без повтору.'
