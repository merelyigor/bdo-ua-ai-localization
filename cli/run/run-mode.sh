#!/usr/bin/env bash
# Почати наступну пачку за preset режиму.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
MODE="${1:?patch|manual|proposal|improve}"
SIZE="${2:-15}"
source "$SCRIPT_DIR/cli/system/select-env.sh"
preset="$($SCRIPT_DIR/cli/run/run-spec.sh status "$MODE")"
query="$(php -r '$x=json_decode($argv[1],true);echo $x["preset"]["filter"]??"";' "$preset")"
channel="$(php -r '$x=json_decode($argv[1],true);echo $x["preset"]["channel"]??"";' "$preset")"
if ! "$SCRIPT_DIR/cli/run/run-start.sh" --show 2>/dev/null | grep -Eq '^(prod|local)$'; then "$SCRIPT_DIR/cli/run/run-start.sh" >/dev/null; fi
fetch="$($SCRIPT_DIR/cli/api/fetch-rows.sh "$SIZE" "$query" 2>&1)"
rows="$(printf '%s\n' "$fetch" | grep -oE '/[^ ]*/output/rows_[0-9_]+\.json' | tail -1 || true)"
test -f "$rows" || rows="$(ls -t "$SCRIPT_DIR"/output/rows_*.json 2>/dev/null | head -1 || true)"
test -f "$rows" || { echo '{"ok":false,"state":"waiting_dependency","reason":"fetch_failed"}'; exit 1; }
count="$(php -r 'echo count(json_decode(file_get_contents($argv[1]),true)["data"]["rows"]??[]);' "$rows")"
if [ "$count" -eq 0 ]; then printf '{"ok":true,"mode":"%s","state":"complete","rows":0}\n' "$MODE"; exit 0; fi
"$SCRIPT_DIR/cli/batch/batch-new.sh" "$rows" >/dev/null
B="$($SCRIPT_DIR/cli/batch/batch-dir.sh)"
php -r 'require $argv[1];$w=Bdo\Translate\Batch\Workspace::requireCurrent($argv[2]);$w->updateManifest(function($m)use($argv){$m["mode"]=$argv[3];$m["channel"]=$argv[4];$m["query"]=$argv[5];return $m;},"run_spec");' "$SCRIPT_DIR/lib/autoload.php" "${BDO_STATE_DIR:-$SCRIPT_DIR/state}" "$MODE" "$channel" "$query"
printf '{"ok":true,"mode":"%s","state":"selected","rows":%d,"batch_dir":"%s"}\n' "$MODE" "$count" "$B"
