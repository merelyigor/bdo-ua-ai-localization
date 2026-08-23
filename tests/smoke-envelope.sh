#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

envelope="$(BDO_STATE_DIR="$TMP" bash "$ROOT/cli/runtime/prepare-smoke.sh")"
jq -e '.ok == true and .state == "smoke" and .next.kind == "child" and
    .next.role == "translation-smoke" and
    (.next.payload_path | endswith("/smoke/payload.json")) and
    (.next.response_path | endswith("/smoke/response.json"))' <<< "$envelope" >/dev/null
jq -e '.request | type == "string" and length > 0' "$TMP/smoke/payload.json" >/dev/null
echo 'smoke envelope: OK'
