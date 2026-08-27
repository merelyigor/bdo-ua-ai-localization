#!/usr/bin/env bash
# Регресія №2: у режимі improve памʼяттю є лише manual-шар. Machine-текст
# (RU-похідний) не має права «закрити» рядок, який цей режим має покращити.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HASH="$(printf 'improve-memory-row' | shasum -a 256 | awk '{print $1}')"

make_batch() { # $1 state-dir; $2 mode; $3 memory_layers; $4 memory scenario
    local state="$1" rows="$1/rows.json" batch
    local scenario="${4:-translated-machine}"
    mkdir -p "$state"
    php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [[
        "identity_hash" => $argv[2],
        "source_hash" => hash("sha256", "Ancient Sword"),
        "source_text" => "Ancient Sword",
        "constraints" => ["non_translatable" => $argv[3] === "non-translatable"],
    ]]]], JSON_THROW_ON_ERROR));' "$rows" "$HASH" "$scenario"
    BDO_STATE_DIR="$state" bash "$ROOT/cli/batch/batch-new.sh" "$rows" >/dev/null
    batch="$(BDO_STATE_DIR="$state" bash "$ROOT/cli/batch/batch-dir.sh")"
    php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])
        ->updateManifest(function ($m) use ($argv) {
            $m["mode"] = $argv[3]; $m["channel"] = "machine"; $m["memory_layers"] = $argv[4];
            return $m;
        }, "test_spec");' "$ROOT/lib/autoload.php" "$state" "$2" "$3"
    php -r '$variants = match ($argv[3]) {
        "source-machine" => [["layer" => "machine", "text" => "Ancient Sword"]],
        "fallback" => [
            ["layer" => "machine", "text" => "Ancient Sword"],
            ["layer" => "machine", "text" => "Стародавній меч"],
        ],
        "source-manual" => [["layer" => "manual", "text" => "Ancient Sword"]],
        "non-translatable" => [["layer" => "machine", "text" => "Ancient Sword"]],
        default => [["layer" => "machine", "text" => "Стародавній меч"]],
    };
    file_put_contents($argv[1], json_encode(["data" => ["memory" => [
        $argv[2] => ["source_text" => "Ancient Sword", "variants" => $variants],
    ]]], JSON_THROW_ON_ERROR));' "$batch/memory.json" "$HASH" "$scenario"
    BDO_PIPELINE_OFFLINE=1 BDO_STATE_DIR="$state" bash "$ROOT/cli/run/run-drive.sh" > "$state/drive.json"
    printf '%s\n' "$batch"
}

count_ready() { php -r '$a=json_decode((string)file_get_contents($argv[1]),true)?:[];echo count($a);' "$1"; }
rows_left() { php -r 'echo count(json_decode((string)file_get_contents($argv[1]),true)["data"]["rows"]??[]);' "$1"; }

# improve + memory_layers=manual: machine-памʼять відфільтрована, рядок іде моделі.
TMP_IMPROVE="$(mktemp -d)"
TMP_PATCH="$(mktemp -d)"
TMP_SOURCE="$(mktemp -d)"
TMP_FALLBACK="$(mktemp -d)"
TMP_MANUAL="$(mktemp -d)"
TMP_NONTRANSLATABLE="$(mktemp -d)"
trap 'rm -rf "$TMP_IMPROVE" "$TMP_PATCH" "$TMP_SOURCE" "$TMP_FALLBACK" "$TMP_MANUAL" "$TMP_NONTRANSLATABLE"' EXIT
BATCH="$(make_batch "$TMP_IMPROVE/state" improve manual)"
test "$(count_ready "$BATCH/memory-candidate.json")" = 0 \
    || { echo 'FAIL: improve закрив рядок machine-памʼяттю'; exit 1; }
test "$(rows_left "$BATCH/to-translate.json")" = 1 \
    || { echo 'FAIL: improve не лишив рядок моделі'; exit 1; }
jq -e '.next.kind == "child" and .next.role == "translation-worker"' "$TMP_IMPROVE/state/drive.json" >/dev/null
jq -e '.role == "translation-worker"' "$TMP_IMPROVE/state/next-child.json" >/dev/null
# Готовий рядок для Task лежить в envelope. Складання `payload:` + шлях було
# кроком висновку, і саме на ньому модель зривалась двічі: переписувала весь
# payload у аргумент (151 139 байтів) або оголошувала, що посилання «не працює».
jq -e '.prompt == ("payload:" + .payload_path)' "$TMP_IMPROVE/state/next-child.json" >/dev/null \
    || { echo 'FAIL: envelope не містить готового prompt для Task'; exit 1; }
jq -e '.next.prompt == ("payload:" + .next.payload_path)' "$TMP_IMPROVE/state/drive.json" >/dev/null \
    || { echo 'FAIL: run drive не показує готовий prompt диригенту'; exit 1; }
# Кожен диспетчер видно в журналі й у лічильнику manifest. До 2026-08-28 журнал
# писав лише стани, тому `translation-repair` у ньому не було взагалі, і
# вартість пачки за журналом виходила неповною.
grep -q '"child_dispatch:translation-worker' "$BATCH/journal.jsonl" \
    || { echo 'FAIL: журнал не бачить диспетчера дитячого виклику'; exit 1; }
jq -e '.children["translation-worker"].calls == 1 and .children["translation-worker"].items == 1' "$BATCH/manifest.json" >/dev/null \
    || { echo 'FAIL: manifest не рахує дитячі виклики й рядки'; exit 1; }

# patch + memory_layers=all: та сама памʼять закриває рядок без моделі.
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

# Source-equal machine memory не є перекладом: рядок обовʼязково йде worker.
BATCH="$(make_batch "$TMP_SOURCE/state" patch all source-machine)"
test "$(count_ready "$BATCH/memory-candidate.json")" = 0
test "$(rows_left "$BATCH/to-translate.json")" = 1
jq -e '.next.kind == "child" and .next.role == "translation-worker"' "$TMP_SOURCE/state/drive.json" >/dev/null \
    || { echo 'FAIL: source-equal machine memory пропустила worker'; exit 1; }

# Непридатний перший варіант не ховає наступний коректний варіант памʼяті.
BATCH="$(make_batch "$TMP_FALLBACK/state" patch all fallback)"
test "$(count_ready "$BATCH/memory-candidate.json")" = 1
jq -e '.[0].text == "Стародавній меч"' "$BATCH/memory-candidate.json" >/dev/null \
    || { echo 'FAIL: не вибрано наступний придатний memory-варіант'; exit 1; }

# Manual є рішенням власника, а non_translatable має лишатися дослівним.
BATCH="$(make_batch "$TMP_MANUAL/state" patch all source-manual)"
test "$(count_ready "$BATCH/memory-candidate.json")" = 1 \
    || { echo 'FAIL: source-equal manual memory втратила авторитет'; exit 1; }
BATCH="$(make_batch "$TMP_NONTRANSLATABLE/state" patch all non-translatable)"
test "$(count_ready "$BATCH/memory-candidate.json")" = 1 \
    || { echo 'FAIL: non_translatable source-equal memory відхилено'; exit 1; }

echo 'drive memory layers: OK'
