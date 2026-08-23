#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Застарілий response від попереднього прогону має зникнути: інакше капчер і
# translation_result сприймуть його за відповідь нового child.
mkdir -p "$TMP/smoke"
printf '%s\n' '{"ok":true,"text":"застаріле"}' > "$TMP/smoke/response.json"

envelope="$(BDO_STATE_DIR="$TMP" bash "$ROOT/cli/runtime/prepare-smoke.sh")"
jq -e '.ok == true and .state == "smoke" and .next.kind == "child" and
    .next.role == "translation-smoke" and
    (.next.payload_path | endswith("/smoke/payload.json")) and
    (.next.response_path | endswith("/smoke/response.json"))' <<< "$envelope" >/dev/null
jq -e '. == {"task":"echo_response","response":{"ok":true,"text":"готово"}}' \
    "$TMP/smoke/payload.json" >/dev/null
test ! -f "$TMP/smoke/response.json"
# Той самий envelope staged для механічного child-контракту.
jq -e --argjson next "$(jq -c '.next' <<< "$envelope")" '. == $next' "$TMP/next-child.json" >/dev/null
echo 'smoke envelope: OK'
