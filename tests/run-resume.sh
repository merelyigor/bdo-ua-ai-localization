#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HASH="$(printf resume-row | shasum -a 256 | awk '{print $1}')"

php -r 'file_put_contents($argv[1],json_encode(["data"=>["rows"=>[[
    "identity_hash"=>$argv[2],"source_hash"=>hash("sha256","Sword"),"source_text"=>"Sword"]]]],JSON_THROW_ON_ERROR));' \
    "$TMP/rows.json" "$HASH"
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/batch/batch-new.sh" "$TMP/rows.json" >/dev/null
BATCH="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/batch/batch-dir.sh")"

result="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/run/run-mode.sh" patch 20 3)"
jq -e --arg batch "$BATCH" '.ok == true and .resume == true and .mode == "patch" and .patch == "3" and .state == "selected" and .batch_dir == $batch' <<< "$result" >/dev/null
jq -e '.mode == "patch" and .patch == "3" and .channel == "machine"' "$BATCH/manifest.json" >/dev/null \
    || { echo 'FAIL: interrupted batch spec was not recovered'; exit 1; }
test "$(find "$TMP/state/batches" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 \
    || { echo 'FAIL: mode start created a second batch instead of resume'; exit 1; }

echo 'run resume: OK'
