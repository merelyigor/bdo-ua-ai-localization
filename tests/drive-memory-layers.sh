#!/usr/bin/env bash
# Регресія №2: у режимі improve памʼяттю є лише manual-шар. Machine-текст
# (RU-похідний) не має права «закрити» рядок, який цей режим має покращити.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HASH="$(printf 'improve-memory-row' | shasum -a 256 | awk '{print $1}')"

make_batch() { # $1 state-dir; $2 mode; $3 memory_layers
    local state="$1" rows="$1/rows.json" batch
    mkdir -p "$state"
    php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [[
        "identity_hash" => $argv[2],
        "source_hash" => hash("sha256", "Ancient Sword"),
        "source_text" => "Ancient Sword",
    ]]]], JSON_THROW_ON_ERROR));' "$rows" "$HASH"
    BDO_STATE_DIR="$state" bash "$ROOT/cli/batch/batch-new.sh" "$rows" >/dev/null
    batch="$(BDO_STATE_DIR="$state" bash "$ROOT/cli/batch/batch-dir.sh")"
    php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])
        ->updateManifest(function ($m) use ($argv) {
            $m["mode"] = $argv[3]; $m["channel"] = "machine"; $m["memory_layers"] = $argv[4];
            return $m;
        }, "test_spec");' "$ROOT/lib/autoload.php" "$state" "$2" "$3"
    php -r 'file_put_contents($argv[1], json_encode(["data" => ["memory" => [
        $argv[2] => ["source_text" => "Ancient Sword", "variants" => [
            ["layer" => "machine", "text" => "Стародавній меч"],
        ]],
    ]]], JSON_THROW_ON_ERROR));' "$batch/memory.json" "$HASH"
    BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR="$state" bash "$ROOT/cli/run/run-drive.sh" > "$state/drive.json"
    printf '%s\n' "$batch"
}

count_ready() { php -r '$a=json_decode((string)file_get_contents($argv[1]),true)?:[];echo count($a);' "$1"; }
rows_left() { php -r 'echo count(json_decode((string)file_get_contents($argv[1]),true)["data"]["rows"]??[]);' "$1"; }

# improve + memory_layers=manual: machine-памʼять відфільтрована, рядок іде моделі.
TMP_IMPROVE="$(mktemp -d)"; trap 'rm -rf "$TMP_IMPROVE" "$TMP_PATCH"' EXIT
BATCH="$(make_batch "$TMP_IMPROVE/state" improve manual)"
test "$(count_ready "$BATCH/memory-candidate.json")" = 0 \
    || { echo 'FAIL: improve закрив рядок machine-памʼяттю'; exit 1; }
test "$(rows_left "$BATCH/to-translate.json")" = 1 \
    || { echo 'FAIL: improve не лишив рядок моделі'; exit 1; }
jq -e '.next.kind == "child" and .next.role == "translation-worker"' "$TMP_IMPROVE/state/drive.json" >/dev/null
jq -e '.role == "translation-worker"' "$TMP_IMPROVE/state/next-child.json" >/dev/null

# patch + memory_layers=all: та сама памʼять закриває рядок без моделі.
TMP_PATCH="$(mktemp -d)"
BATCH="$(make_batch "$TMP_PATCH/state" patch all)"
test "$(count_ready "$BATCH/memory-candidate.json")" = 1 \
    || { echo 'FAIL: patch не застосував machine-памʼять'; exit 1; }
test "$(rows_left "$BATCH/to-translate.json")" = 0 \
    || { echo 'FAIL: patch відправив закритий памʼяттю рядок моделі'; exit 1; }
jq -e '.next.kind == "continue" and .state == "awaiting_worker"' "$TMP_PATCH/state/drive.json" >/dev/null \
    || { echo 'FAIL: patch викликав worker для закритої памʼяттю пачки'; exit 1; }
test "$(count_ready "$BATCH/candidate.json")" = 1 \
    || { echo 'FAIL: memory-candidate не став кандидатом без worker'; exit 1; }
BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR="$TMP_PATCH/state" bash "$ROOT/cli/run/run-drive.sh" > "$TMP_PATCH/state/drive-next.json"
jq -e '.next.kind == "child" and .next.role == "translation-qa"' "$TMP_PATCH/state/drive-next.json" >/dev/null \
    || { echo 'FAIL: закрита памʼяттю пачка не перейшла до QA'; exit 1; }

echo 'drive memory layers: OK'
