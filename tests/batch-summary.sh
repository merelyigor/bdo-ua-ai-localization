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

echo 'batch summary: OK'
