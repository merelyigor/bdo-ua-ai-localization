#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HASH="$(printf summary-row | shasum -a 256 | awk '{print $1}')"

php -r 'file_put_contents($argv[1],json_encode(["data"=>["rows"=>[[
    "identity_hash"=>$argv[2],"source_hash"=>hash("sha256","Sword"),"source_text"=>"Sword"]]]],JSON_THROW_ON_ERROR));' \
    "$TMP/rows.json" "$HASH"
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/batch/batch-new.sh" "$TMP/rows.json" >/dev/null
BATCH="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/batch/batch-dir.sh")"
php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])->updateManifest(function($m){
    $m["state"]="verified";$m["mode"]="patch";$m["patch"]="3";$m["channel"]="machine";return $m;},"test_verified");' \
    "$ROOT/lib/autoload.php" "$TMP/state"
printf '%s\n' \
    'Пачка: 1 рядків | PASS 1, REVIEW 0, REJECT 0' \
    'До запису: 1 | у модерацію: 0 (з них нерозпізнані назви: 0) | у карантин (збої): 0 | квота: 100' \
    'Записано: 1  Пропущено: 0  Відкинуто: 0' \
    > "$BATCH/commit-report.txt"

first="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/run/run-drive.sh")"
jq -e '.next.kind == "complete" and .next.batch.rows == 1 and .next.batch.target_written == 1
    and .next.batch.moderation_written == 0 and .next.batch.quarantine == 0
    and .next.run.rows == 1 and .next.run.target_written == 1' <<< "$first" >/dev/null

second="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/run/run-drive.sh")"
jq -e '.next.run.rows == 1 and .next.run.target_written == 1' <<< "$second" >/dev/null \
    || { echo 'FAIL: repeated complete double-counted run totals'; exit 1; }

# Ціль прогону переживає кінець пачки й стискання сесії.
#
# 2026-08-28 власник сказав «треба доперекласти всі knowledge», диригент закрив
# пʼяту пачку, побачив `complete` і запитав «Продовжувати?», хоча в патчі
# лишався 141 рядок. Ціль жила лише в тексті чату, тому після стискання сесії
# продовжувати не було кому. Тепер вона лежить у `state/run-goal.json`, і
# конверт наприкінці пачки каже РІВНО наступний крок.
printf '{"mode":"patch","patch":"7","domain":"knowledge","channel":"machine","query":"patch=7&missing=machine&domain=knowledge"}\n' \
    > "$TMP/state/run-goal.json"

# Офлайн залишок невідомий · конверт мусить лишитись старим `complete`.
# «Невідомо» і «роботи немає» це різні стани: сплутати їх означає зупинити
# прогін саме тоді, коли робота ще є.
offline="$(BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/run/run-drive.sh")"
jq -e '.next.kind == "complete"' <<< "$offline" >/dev/null \
    || { echo 'FAIL: невідомий залишок змінив вирок'; exit 1; }

# Залишок є · диригент мусить отримати команду, а не питання.
export BDO_GOAL_REMAINING_STUB=141
withwork="$(BDO_STATE_DIR="$TMP/state" BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/run/run-drive.sh")"
jq -e '.next.kind == "continue_run" and .next.remaining == 141
    and (.next.command | test("mode start patch 50 7 knowledge"))' <<< "$withwork" >/dev/null \
    || { echo "FAIL: залишок 141 не дав continue_run: $withwork"; exit 1; }

# Залишку немає · ціль досягнута, і це теж сказано словом, а не мовчанням.
export BDO_GOAL_REMAINING_STUB=0
done_env="$(BDO_STATE_DIR="$TMP/state" BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/run/run-drive.sh")"
jq -e '.next.kind == "goal_complete"' <<< "$done_env" >/dev/null \
    || { echo "FAIL: нульовий залишок не дав goal_complete: $done_env"; exit 1; }
unset BDO_GOAL_REMAINING_STUB

# Категорія скінчилась · але ціль ширша за категорію.
#
# 2026-08-29 диригент закрив `entity`, отримав `goal_complete` і став чекати
# рішення власника, хоча в патчі лишалось десять категорій і власник просив
# «перекласти весь патч». Тепер рушій сам називає наступну категорію.
export BDO_GOAL_REMAINING_STUB=0
export BDO_NEXT_DOMAIN_STUB="premium_shop 436"
next="$(BDO_STATE_DIR="$TMP/state" BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/run/run-drive.sh")"
jq -e '.next.kind == "continue_run" and .next.goal.domain == "premium_shop"
    and .next.remaining == 436
    and (.next.command | test("mode start patch 50 7 premium_shop"))' <<< "$next" >/dev/null \
    || { echo "FAIL: вичерпана категорія не дала наступної: $next"; exit 1; }

# А коли роботи немає в ЖОДНІЙ категорії · ціль справді досягнута.
export BDO_NEXT_DOMAIN_STUB=""
done_all="$(BDO_STATE_DIR="$TMP/state" BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/run/run-drive.sh")"
jq -e '.next.kind == "goal_complete"' <<< "$done_all" >/dev/null \
    || { echo "FAIL: порожній патч не дав goal_complete: $done_all"; exit 1; }
unset BDO_GOAL_REMAINING_STUB BDO_NEXT_DOMAIN_STUB

echo 'batch summary: OK'
