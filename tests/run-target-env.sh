#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# BDO_ENV є єдиним перемикачем: застарілий глобальний DEV URL не має права
# перебити PROD-настройку.
cat > "$TMP/prod.env" <<'EOF'
BDO_ENV=PROD
BDO_API_KEY_PROD=test
BDO_API_BASE_PROD=https://prod.example/api
BDO_API_BASE=https://dev.example/api
EOF
resolved="$(TRANSLATE_ENV_FILE="$TMP/prod.env" bash -c 'source "$1/cli/system/select-env.sh" >/dev/null; printf "%s|%s" "$BDO_ENV" "$BDO_API_BASE"' _ "$ROOT")"
test "$resolved" = 'PROD|https://prod.example/api' || {
    printf 'BDO_ENV=PROD перебито чужим URL: %s\n' "$resolved" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$ROOT/cli/system/select-env.sh" >/dev/null
if [ "$BDO_API_ENV" = prod ]; then wrong=local; else wrong=prod; fi
printf '%s\n' "$wrong" > "$TMP/run-target"
# Застарілий lock без незавершеної пачки має переїхати автоматично: агент не
# повинен вгадувати окрему cleanup-команду.
BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null
test "$(cat "$TMP/run-target")" = "$BDO_API_ENV"

# Але активну пачку між середовищами переносити не можна.
mkdir -p "$TMP/batches/active-test"
printf '%s\n' 'active-test' > "$TMP/current-batch"
printf '%s\n' '{"state":"awaiting_worker"}' > "$TMP/batches/active-test/manifest.json"
printf '%s\n' "$wrong" > "$TMP/run-target"
if BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null 2>&1; then
    echo 'active batch crossed environments' >&2
    exit 1
fi
test "$(cat "$TMP/run-target")" = "$wrong"

# Термінальна пачка вже не блокує новий прогін.
printf '%s\n' '{"state":"verified"}' > "$TMP/batches/active-test/manifest.json"
BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null
test "$(cat "$TMP/run-target")" = "$BDO_API_ENV"
printf '%s\n' "$BDO_API_ENV" > "$TMP/run-target"
BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null
echo 'run target env guard: OK'
