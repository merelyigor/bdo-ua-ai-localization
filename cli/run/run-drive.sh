#!/usr/bin/env bash
# Детермінований OpenCode-only driver поточної пачки.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
B="$($SCRIPT_DIR/cli/batch/batch-dir.sh)"

field() { php -r '$m=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);echo $m[$argv[2]]??"";' "$B/manifest.json" "$1"; }
transition() { php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])->transition($argv[3]);' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$1"; }
complete() {
    local sum; sum="$(shasum -a 256 "$2" | awk '{print $1}')"
    php -r 'require $argv[1];Bdo\Translate\Batch\Workspace::requireCurrent($argv[2])->completeStep($argv[3],basename($argv[4]),$argv[5]);' "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR" "$1" "$2" "$sum"
}
emit() {
    php -r '$n=json_decode($argv[3],true,512,JSON_THROW_ON_ERROR);echo json_encode(["ok"=>$argv[1]==="1","state"=>$argv[2],"next"=>$n],JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),"\n";' "$1" "$2" "$3"
}
child() {
    emit 1 "$1" "$(php -r 'echo json_encode(["kind"=>"child","role"=>$argv[1],"payload_path"=>$argv[2],"response_path"=>$argv[3]]);' "$2" "$3" "$4")"
}

state="$(field state)"
case "$state" in
selected)
    if [ "${BDO_PIPELINE_OFFLINE:-0}" != 1 ]; then "$SCRIPT_DIR/cli/prepare/memory-lookup.sh" "$B/rows.json" >/dev/null 2>&1 || true; fi
    rows="$B/rows.json"
    if [ -s "$B/memory.json" ]; then
        "$SCRIPT_DIR/cli/prepare/memory-apply.sh" "$B/rows.json" "$B/memory.json" >/dev/null 2>&1 || true
        test -s "$B/to-translate.json" && rows="$B/to-translate.json"
    fi
    if [ "${BDO_PIPELINE_OFFLINE:-0}" != 1 ]; then "$SCRIPT_DIR/cli/prepare/glossary-gaps.sh" "$B/rows.json" >/dev/null 2>&1 || true; fi
    count="$(php -r 'echo count(json_decode(file_get_contents($argv[1]),true)["data"]["rows"]??[]);' "$rows")"
    if [ "$count" -gt 0 ]; then
        "$SCRIPT_DIR/cli/prepare/build-schema.sh" "$rows" >/dev/null
        args=(); test "$(field mode)" = improve && args+=(--with-current)
        test "${BDO_PIPELINE_OFFLINE:-0}" = 1 && args+=(--no-context)
        "$SCRIPT_DIR/cli/prepare/worker-payload.sh" "$rows" "${args[@]}" > "$B/worker-payload.json"
    else
        echo '[]' > "$B/worker-payload.json"; echo '[]' > "$B/candidate.json"
    fi
    complete prepared "$B/worker-payload.json"; transition prepared; transition awaiting_worker
    child awaiting_worker translation-worker "$B/worker-payload.json" "$B/candidate.json"
    ;;
awaiting_worker)
    if [ ! -s "$B/candidate.json" ]; then child awaiting_worker translation-worker "$B/worker-payload.json" "$B/candidate.json"; exit 0; fi
    model_rows="$B/rows.json"; test -s "$B/to-translate.json" && model_rows="$B/to-translate.json"
    if ! "$SCRIPT_DIR/cli/quality/build-items.sh" "$model_rows" "$B/candidate.json" "$B/model-items.json" "" --require-all >/dev/null 2>&1; then
        mv "$B/candidate.json" "$B/candidate.invalid.$(date +%s).json"
        child awaiting_worker translation-worker "$B/worker-payload.json" "$B/candidate.json"
        exit 0
    fi
    complete worker "$B/candidate.json"; transition candidate_valid
    if [ -s "$B/twins.json" ] && [ -s "$B/memory-candidate.json" ]; then
        "$SCRIPT_DIR/cli/prepare/memory-expand.sh" "$B/candidate.json" "$B/twins.json" "$B/memory-candidate.json" > "$B/full.json" 2>/dev/null
    else cp "$B/candidate.json" "$B/full.json"; fi
    "$SCRIPT_DIR/cli/quality/normalize-candidate.sh" "$B/full.json" > "$B/clean.json" 2>/dev/null
    "$SCRIPT_DIR/cli/quality/build-items.sh" "$B/rows.json" "$B/clean.json" "$B/items.json" "" --require-all >/dev/null
    "$SCRIPT_DIR/cli/quality/check-russianisms.sh" "$B/clean.json" "$B/rows.json" >/dev/null 2>&1 || true
    validate=""; if [ "${BDO_PIPELINE_OFFLINE:-0}" != 1 ]; then validate="$($SCRIPT_DIR/cli/api/validate.sh "$B/items.json" 2>&1 || true)"; fi
    validate_file="$(printf '%s\n' "$validate" | grep -oE '/[^ ]*/output/validate_[0-9_]+\.json' | tail -1 || true)"
    test -f "$validate_file" && printf '%s\n' "$validate_file" > "$B/validate-path" || true
    complete deterministic "$B/clean.json"; transition deterministic_valid
    "$SCRIPT_DIR/cli/prepare/build-schema.sh" --qa "$B/rows.json" >/dev/null
    "$SCRIPT_DIR/cli/prepare/qa-payload.sh" "$B/rows.json" "$B/clean.json" > "$B/qa-payload.json"
    transition awaiting_qa; child awaiting_qa translation-qa "$B/qa-payload.json" "$B/verdicts.json"
    ;;
awaiting_qa)
    if [ ! -s "$B/verdicts.json" ]; then child awaiting_qa translation-qa "$B/qa-payload.json" "$B/verdicts.json"; exit 0; fi
    if ! php -r 'require $argv[1];Bdo\Translate\Quality\VerdictSet::fromFile($argv[2]);' "$SCRIPT_DIR/lib/autoload.php" "$B/verdicts.json" 2>/dev/null; then
        mv "$B/verdicts.json" "$B/verdicts.invalid.$(date +%s).json"
        child awaiting_qa translation-qa "$B/qa-payload.json" "$B/verdicts.json"
        exit 0
    fi
    complete qa "$B/verdicts.json"; transition qa_valid
    vf=""; test -f "$B/validate-path" && vf="$(cat "$B/validate-path")"
    BDO_HEAL_MAX_ATTEMPTS="${BDO_HEAL_MAX_ATTEMPTS:-3}" "$SCRIPT_DIR/cli/heal/heal-plan.sh" "$B/rows.json" "$B/clean.json" "$B/verdicts.json" "$vf" > "$B/heal-report.txt" 2>&1 || true
    repairs="$(php -r '$a=is_file($argv[1])?json_decode(file_get_contents($argv[1]),true):[];echo is_array($a)?count($a):0;' "$B/heal-repair-payload.json")"
    if [ "$repairs" -gt 0 ]; then transition healing; child healing translation-repair "$B/heal-repair-payload.json" "$B/fixes.json"
    else cp "$B/heal-merged.json" "$B/final-candidate.json"; cp "$B/verdicts.json" "$B/final-verdicts.json"; transition ready_to_commit; emit 1 ready_to_commit '{"kind":"continue"}'; fi
    ;;
healing)
    if [ ! -s "$B/fixes.json" ]; then child healing translation-repair "$B/heal-repair-payload.json" "$B/fixes.json"; exit 0; fi
    if ! "$SCRIPT_DIR/cli/quality/merge-items.sh" "$B/heal-merged.json" "$B/fixes.json" "$B/healed.json" >/dev/null 2>&1; then
        mv "$B/fixes.json" "$B/fixes.invalid.$(date +%s).json"
        child healing translation-repair "$B/heal-repair-payload.json" "$B/fixes.json"
        exit 0
    fi
    "$SCRIPT_DIR/cli/prepare/qa-payload.sh" "$B/heal-repair-subset.json" "$B/fixes.json" > "$B/control-qa-payload.json"
    transition awaiting_control_qa; child awaiting_control_qa translation-qa "$B/control-qa-payload.json" "$B/verdicts-control.json"
    ;;
awaiting_control_qa)
    if [ ! -s "$B/verdicts-control.json" ]; then child awaiting_control_qa translation-qa "$B/control-qa-payload.json" "$B/verdicts-control.json"; exit 0; fi
    php -r '$a=json_decode(file_get_contents($argv[1]),true);$b=json_decode(file_get_contents($argv[2]),true);$x=[];foreach($a as $v)$x[$v["identity_hash"]]=$v;foreach($b as $v)$x[$v["identity_hash"]]=$v;file_put_contents($argv[3],json_encode(array_values($x),JSON_UNESCAPED_UNICODE|JSON_THROW_ON_ERROR));' "$B/verdicts.json" "$B/verdicts-control.json" "$B/final-verdicts.json"
    cp "$B/healed.json" "$B/final-candidate.json"; transition ready_to_commit; emit 1 ready_to_commit '{"kind":"continue"}'
    ;;
ready_to_commit|committing)
    source "$SCRIPT_DIR/cli/system/select-env.sh" >/dev/null
    "$SCRIPT_DIR/cli/quality/build-items.sh" "$B/rows.json" "$B/final-candidate.json" "$B/final-items.json" "" --require-all >/dev/null
    key="$(php -r 'require $argv[1];$x=json_decode(file_get_contents($argv[5]),true,512,JSON_THROW_ON_ERROR);echo Bdo\Translate\Api\IdempotencyKey::forBatch($argv[2],$argv[3],$argv[4],$x);' "$SCRIPT_DIR/lib/autoload.php" "$BDO_ENV" "$(field channel)" "$(basename "$B")" "$B/final-items.json")"
    test "$state" = committing || transition committing
    if "$SCRIPT_DIR/cli/batch/batch-commit.sh" "$B/rows.json" "$B/final-candidate.json" "$B/final-verdicts.json" --channel "$(field channel)" --idempotency-key-prefix "$key" --write > "$B/commit-report.txt" 2>&1; then
        complete commit "$B/commit-report.txt"; transition committed; transition verified; "$SCRIPT_DIR/cli/prepare/build-schema.sh" --clear >/dev/null
        emit 1 verified '{"kind":"complete"}'
    else emit 0 committing '{"kind":"retry","reason":"api_write_failed"}'; exit 1; fi
    ;;
verified) emit 1 verified '{"kind":"complete"}' ;;
*) emit 0 "$state" "$(php -r 'echo json_encode(["kind"=>"blocked","reason"=>$argv[1]]);' "$state")"; exit 1 ;;
esac
