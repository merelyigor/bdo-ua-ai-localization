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
if BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null 2>&1; then
    echo 'run-target mismatch was accepted' >&2
    exit 1
fi
printf '%s\n' "$BDO_API_ENV" > "$TMP/run-target"
BDO_STATE_DIR="$TMP" bash "$ROOT/cli/run/run-start.sh" >/dev/null
echo 'run target env guard: OK'
