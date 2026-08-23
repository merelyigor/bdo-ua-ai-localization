#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/state/batches/old-verified" "$TMP/state/batches/old-awaiting" "$TMP/output"
printf '{"state":"verified"}\n' > "$TMP/state/batches/old-verified/manifest.json"
printf '{"state":"awaiting_worker"}\n' > "$TMP/state/batches/old-awaiting/manifest.json"
printf 'old\n' > "$TMP/output/old.json"
touch -t 200001010000 "$TMP/state/batches/old-verified" "$TMP/state/batches/old-awaiting" "$TMP/output/old.json"

preview="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/batch/batch-clean.sh" --days 0)"
grep -q 'буде прибрано: old-verified' <<<"$preview"
grep -q 'ПРОПУСК (не завершена: awaiting_worker): old-awaiting' <<<"$preview"
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/batch/batch-clean.sh" --days 0 --apply >/dev/null
test ! -d "$TMP/state/batches/old-verified"
test -d "$TMP/state/batches/old-awaiting"
echo 'rotation: OK'
