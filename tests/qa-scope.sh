#!/usr/bin/env bash
# QA дивиться лише текст, який написала модель у ЦІЙ пачці (D57).
#
# Заміряно 2026-09-04 на пачці `20260904_120154`: `translation-worker:4`,
# `translation-qa:49`. Памʼять закрила 45 рядків із 50 і одразу віддала
# зекономлене QA: модель перевіряла текст, який уже проходив цей конвеєр і вже
# був прийнятий, а ремонтник потім переписував його. QA коштувала 60% часу
# прогону, сам переклад · 4%.
#
# Тест бере пачку на МЕЖІ: 50 рядків, 45 закриті памʼяттю, 5 · моделі, і падає,
# якщо QA отримала більше ніж 5 рядків або якщо рядок із памʼяті лишився без
# вердикту (тоді commit відправив би всю пачку в карантин як qa_incomplete).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"

# 50 рядків; памʼять знає перші 45.
php -r '
$rows = []; $memory = [];
for ($i = 1; $i <= 50; $i++) {
    $hash = hash("sha256", "row-$i"); $src = "Ancient Sword $i";
    $rows[] = ["identity_hash" => $hash, "source_hash" => hash("sha256", $src), "source_text" => $src];
    if ($i <= 45) $memory[$hash] = ["source_text" => $src, "variants" => [["layer" => "machine", "text" => "Стародавній меч $i"]]];
}
file_put_contents($argv[1], json_encode(["data" => ["rows" => $rows]], JSON_THROW_ON_ERROR));
file_put_contents($argv[2], json_encode(["data" => ["memory" => $memory]], JSON_THROW_ON_ERROR));
' "$STATE/rows.json" "$STATE/memory.json"

BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-new.sh" "$STATE/rows.json" >/dev/null
B="$(BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-dir.sh")"
php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])
    ->updateManifest(function ($m) { $m["mode"] = "patch"; $m["channel"] = "machine"; $m["memory_layers"] = "all"; return $m; }, "test_spec");' \
    "$ROOT/lib/autoload.php" "$STATE"
cp "$STATE/memory.json" "$B/memory.json"

drive() { BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null; }

# 1. Памʼять закриває 45, воркер отримує 5.
out="$(drive)"
jq -e '.next.kind == "child" and .next.role == "translation-worker"' <<<"$out" >/dev/null \
    || fail "перший крок не воркер: $out"
test "$(jq '.data.rows | length' "$B/to-translate.json")" = 5 || fail 'моделі мусило лишитись 5 рядків'
test "$(jq 'length' "$B/memory-candidate.json")" = 45 || fail 'памʼять мусила закрити 45 рядків'

# 2. Воркер відповідає на свої 5 · далі рушій готує QA.
jq '[.data.rows[] | {identity_hash, text: ("Переклад " + .source_text)}]' "$B/to-translate.json" > "$B/candidate.json"
out="$(drive)"
jq -e '.next.kind == "child" and .next.role == "translation-qa"' <<<"$out" >/dev/null \
    || fail "після воркера мусив бути QA: $out"

# 3. ГОЛОВНЕ: QA бачить рівно 5 рядків моделі, не 50.
qa_rows="$(jq '.items | length' "$B/qa-payload.json")"
test "$qa_rows" = 5 || fail "QA отримала $qa_rows рядків замість 5 · памʼять знову їде в модель"
grep -q '"child_dispatch:translation-qa:5"' "$B/journal.jsonl" || fail 'журнал не показує 5 рядків у QA'
# Схема QA теж під 5 рядків: інакше модель добивала б довжину дублікатами.
test "$(jq '.properties.items.items.properties.identity_hash.enum | length' "$STATE/current-qa-schema.json")" = 5 \
    || fail 'схема QA побудована не під підмножину'

# 4. Рядки з памʼяті мають готовий PASS · commit не побачить прогалини.
test "$(jq '[.[] | select(.status == "PASS")] | length' "$B/pre-verdicts.json")" = 45 \
    || fail 'рядки з памʼяті не отримали PASS від коду'

# 5. Після відповіді QA вердикти зливаються: 50 із 50, жодного qa_incomplete.
jq '[.items[] | {identity_hash, status: "PASS", severity: "none", issue: "", fix: ""}]' "$B/qa-payload.json" > "$B/verdicts.json"
out="$(drive)"
test "$(jq 'length' "$B/verdicts.json")" = 50 || fail "після злиття мусило бути 50 вердиктів, є $(jq 'length' "$B/verdicts.json")"

# 6. Дефект у тексті з памʼяті QA не потрібен, але й не ховається: механіка дає REJECT.
#    Пачка з 2 рядків, обидва з памʼяті, один із русизмом.
STATE2="$TMP/state2"; mkdir -p "$STATE2"
php -r '
$h1 = hash("sha256", "m1"); $h2 = hash("sha256", "m2");
file_put_contents($argv[1], json_encode(["data" => ["rows" => [
    ["identity_hash" => $h1, "source_hash" => hash("sha256", "Dark Sail"), "source_text" => "Dark Sail"],
    ["identity_hash" => $h2, "source_hash" => hash("sha256", "Iron Sword"), "source_text" => "Iron Sword"],
]]], JSON_THROW_ON_ERROR));
file_put_contents($argv[2], json_encode([
    ["identity_hash" => $h1, "text" => "Парус Тёмного"],
    ["identity_hash" => $h2, "text" => "Залізний меч"],
], JSON_THROW_ON_ERROR));' "$STATE2/rows.json" "$STATE2/memory-candidate.json"
left="$(bash "$ROOT/cli/quality/mechanical-split.sh" "$STATE2/rows.json" "$STATE2/memory-candidate.json" \
    "$STATE2/pre.json" "$STATE2/subset.json" --memory "$STATE2/memory-candidate.json" 2>/dev/null)"
test "$left" = 0 || fail "обидва рядки з памʼяті, а до QA їде $left"
jq -e '[.[] | .status] | sort == ["PASS","REJECT"]' "$STATE2/pre.json" >/dev/null \
    || fail "памʼять із русизмом мусила дістати REJECT, чиста · PASS: $(cat "$STATE2/pre.json")"

# 7. Рушій справді передає памʼять розділювачу.
grep -Fq -- '--memory "$B/memory-candidate.json"' "$ROOT/cli/run/run-drive.sh" \
    || fail 'dispatch_qa не передає memory-candidate розділювачу'

echo 'qa scope: OK · QA бачить лише текст моделі, памʼять отримує PASS від коду.'
