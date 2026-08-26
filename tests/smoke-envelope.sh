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
# Payload smoke · такий самий масив рядків, як у воркера, а не власний формат.
#
# Досі smoke мав окремий `echo_response` і власну крихітну схему з обʼєктним
# коренем. Через це він півтора місяця показував «маршрут здоровий» там, де
# жоден реальний child не працював: робоча staged-схема мала корінь `array`,
# який OpenAI-сумісні провайдери відхиляють кодом `[400]`. Виміряно 2026-08-27:
# `opencode-go` мав 0 успішних дитячих сесій із 3 при зелених smoke.
jq -e 'type == "array" and length == 1 and (.[0] | has("identity_hash") and has("source_text"))' \
    "$TMP/smoke/payload.json" >/dev/null
test ! -f "$TMP/smoke/response.json"

# Схема smoke мусить бути ТІЄЮ САМОЮ формою, що й у робочих ролей: інакше
# перевірка провайдера знову перевірятиме не те, що ламається.
worker_shape="$(BDO_STATE_DIR="$TMP" bash "$ROOT/cli/prepare/build-schema.sh" \
    --out "$TMP/worker-schema.json" "$TMP/smoke/rows.json" >/dev/null \
    && jq -S 'del(.properties.items.items.properties.identity_hash.enum)' "$TMP/worker-schema.json")"
smoke_shape="$(jq -S 'del(.properties.items.items.properties.identity_hash.enum)' "$TMP/current-smoke-schema.json")"
test "$worker_shape" = "$smoke_shape" || {
    echo 'FAIL: схема smoke розійшлася з робочою · перевірка провайдера знову фіктивна' >&2
    exit 1
}
# Той самий envelope staged для механічного child-контракту.
jq -e --argjson next "$(jq -c '.next' <<< "$envelope")" '. == $next' "$TMP/next-child.json" >/dev/null
echo 'smoke envelope: OK'
