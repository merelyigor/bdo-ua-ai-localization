#!/usr/bin/env bash
# Чистий клон не має ignored runtime-конфігів. Цей тест доводить, що профіль
# атомарно матеріалізується лише з tracked-шаблонів і не змінює їх.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/.opencode/templates" "$TMP/.opencode/agent-templates"
cp "$ROOT/templates/opencode.json" "$TMP/templates-opencode.json"
mkdir -p "$TMP/templates"
mv "$TMP/templates-opencode.json" "$TMP/templates/opencode.json"
cp "$ROOT/.opencode/templates/translation-models.json" "$TMP/.opencode/templates/translation-models.json"
cp "$ROOT"/.opencode/agent-templates/translation-*.md "$TMP/.opencode/agent-templates/"

for template in "$TMP"/.opencode/agent-templates/translation-*.md; do
    test "$(grep -Fc 'model: __BDO_RUNTIME_MODEL__' "$template")" -eq 1
done

before="$(find "$TMP/templates" "$TMP/.opencode/templates" "$TMP/.opencode/agent-templates" -type f -exec shasum -a 256 {} \; | sort)"
TRANSLATE_HOME="$TMP" php "$ROOT/cli/runtime/model-profile.php" env session-free opencode/big-pickle free >/dev/null
after="$(find "$TMP/templates" "$TMP/.opencode/templates" "$TMP/.opencode/agent-templates" -type f -exec shasum -a 256 {} \; | sort)"
test "$before" = "$after" || { echo 'tracked-шаблони змінено матеріалізацією' >&2; exit 1; }
fingerprint="$(jq -r '.fingerprint' "$TMP/.opencode/runtime-model-state.json")"
test "$(jq -r '.schema_version' "$TMP/.opencode/runtime-model-state.json")" = 1
printf '%s' "$fingerprint" | grep -Eq '^[a-f0-9]{64}$'

# Час генерації може змінитись, effective fingerprint · ні.
TRANSLATE_HOME="$TMP" php "$ROOT/cli/runtime/model-profile.php" env session-free opencode/big-pickle free >/dev/null
test "$(jq -r '.fingerprint' "$TMP/.opencode/runtime-model-state.json")" = "$fingerprint"

# Реальна зміна profile/model мусить дати інше покоління для restart-gate.
TRANSLATE_HOME="$TMP" php "$ROOT/cli/runtime/model-profile.php" env ollama-local ollama-local/gemma4:26b free >/dev/null
test "$(jq -r '.fingerprint' "$TMP/.opencode/runtime-model-state.json")" != "$fingerprint"
TRANSLATE_HOME="$TMP" php "$ROOT/cli/runtime/model-profile.php" env session-free opencode/big-pickle free >/dev/null

test "$(jq -r '.active_profile' "$TMP/.opencode/translation-models.json")" = session-free
for role in translation-terminology translation-worker translation-qa translation-repair translation-judge translation-smoke; do
    test "$(jq -r --arg role "$role" '.agent[$role].model' "$TMP/opencode.json")" = opencode/big-pickle
    grep -Fqx 'model: opencode/big-pickle' "$TMP/.opencode/agents/$role.md"
done
find "$TMP" -name '*.tmp.*' -print -quit | grep -q . && { echo 'лишився неатомарний temp-файл' >&2; exit 1; }
test ! -e "$TMP/.opencode/runtime-model-state.busy" || { echo 'лишився runtime busy marker' >&2; exit 1; }

echo 'model runtime materialization: OK'
