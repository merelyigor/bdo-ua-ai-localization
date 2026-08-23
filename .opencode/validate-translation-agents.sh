#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly CONFIG="$ROOT/opencode.json"
readonly AGENTS=(translation-terminology translation-worker translation-qa translation-repair translation-smoke)
readonly POLICY="$ROOT/.opencode/translation-models.json"

jq -e . "$CONFIG" >/dev/null
php -r 'require $argv[1]; Bdo\Translate\Runtime\ModelPolicy::load($argv[2]);' "$ROOT/lib/autoload.php" "$POLICY"
if rg -n 'client\.session\.(create|prompt|promptAsync)' "$ROOT/.opencode/plugin" >/dev/null; then
    echo 'ERROR: plugins must not create hidden child sessions; use native visible Task' >&2
    exit 1
fi
test -f "$ROOT/.opencode/plugin/translation-result-writer.ts" || {
    echo 'ERROR: native Task results need the atomic result writer' >&2
    exit 1
}
test -f "$ROOT/.opencode/plugin/translation-execution-guard.ts" || {
    echo 'ERROR: native Task flow requires the shell execution guard' >&2
    exit 1
}
active_profile="$(jq -r '.active_profile' "$POLICY")"

for agent in "${AGENTS[@]}"; do
    active="$(jq -r --arg agent "$agent" --arg profile "$active_profile" '.profiles[$profile].routes[$agent][0] // empty' "$POLICY")"
    configured="$(jq -r --arg agent "$agent" '.agent[$agent].model // empty' "$CONFIG")"
    test "$configured" = "$active" || {
        printf 'ERROR: %s model %s differs from policy model %s\n' "$agent" "$configured" "$active" >&2
        exit 1
    }
    grep -Fqx "model: $active" "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s frontmatter model does not match project config\n' "$agent" >&2
        exit 1
    }
done

# Видимі native Task діти отримують payload у prompt. Усі tools заборонені.
for agent in translation-worker translation-repair translation-qa translation-smoke; do
    grep -Eq '^  bash: deny$' "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s frontmatter must deny bash\n' "$agent" >&2
        exit 1
    }
    grep -Eq '^  "\*": false$' "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s must start from tools "*": false; a schema does not stop tool calls\n' "$agent" >&2
        exit 1
    }
    # Винятків немає ЖОДНИХ, включно з `read`. Виклик будь-якого інструмента
    # знімає constrained decoding: схема пачки перестає діяти, і модель вільно
    # дублює та вигадує identity_hash. Виміряно 2026-08-20 на QA-сесії
    # ses_fe11de584ffeLjGxtFaJkIuDzp: 4 виклики `read`, на виході 20 обʼєктів
    # лише з 11 унікальними identity, хоча схема має enum і фіксовану довжину.
    # Payload передається текстом у промпті (`cli/prepare/worker-payload.sh`/`cli/prepare/qa-payload.sh`).
    # Коментарі всередині блоку пропускаємо: вони пояснюють саме це правило.
    extra="$(sed -n '/^tools:/,/^---$/p' "$ROOT/.opencode/agents/$agent.md" \
        | grep -E '^  ' | grep -v '^  *#' | grep -v '"\*": false' || true)"
    test -z "$extra" || {
        printf 'ERROR: %s enables a tool; constrained agents must have none:\n%s\n' "$agent" "$extra" >&2
        exit 1
    }
done

# MCP-інструменти обходять bash: deny (serena вміє execute_shell_command).
# Вимагаємо саме дозвільний список `"*": false`, а не перелік заборонених імен:
# заборонний список лишає дозволеним усе, чого в ньому немає, і на живому
# прогоні 2026-08-16 translation-terminology саме так дотягнувся до
# list_mcp_resources, спаливши 187 тисяч вхідних токенів на шість термінів.
for agent in "${AGENTS[@]}"; do
    grep -Eq '^  "\*": false$' "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s must start from a deny-all tool list ("*": false)\n' "$agent" >&2
        exit 1
    }
done
for agent in "${AGENTS[@]}"; do
    grep -Eq '^  task: deny$' "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s frontmatter must deny task\n' "$agent" >&2
        exit 1
    }
    grep -Eq '^  edit: deny$' "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s frontmatter must deny edit\n' "$agent" >&2
        exit 1
    }
done

for primary in патч ручний пропозиції покращення; do
    for agent in "${AGENTS[@]}"; do
        permission="$(jq -r --arg primary "$primary" --arg agent "$agent" '.agent[$primary].permission.task[$agent] // empty' "$CONFIG")"
        test "$permission" = 'allow' || {
            printf 'ERROR: %s cannot delegate to %s\n' "$primary" "$agent" >&2
            exit 1
        }
    done
    denied="$(jq -r --arg primary "$primary" '.agent[$primary].permission.task["*"] // empty' "$CONFIG")"
    test "$denied" = 'deny' || {
        printf 'ERROR: %s must deny all unnamed subagents\n' "$primary" >&2
        exit 1
    }
done

# Runtime prompts intentionally stay small enough for cheap models.
declare -A MAX_LINES=(
    [translation-smoke]=20 [translation-worker]=50 [translation-qa]=55
    [translation-repair]=40 [translation-terminology]=45
    [патч]=35 [ручний]=35 [пропозиції]=35 [покращення]=35
)
for agent in "${!MAX_LINES[@]}"; do
    lines="$(wc -l < "$ROOT/.opencode/agents/$agent.md" | tr -d ' ')"
    test "$lines" -le "${MAX_LINES[$agent]}" || {
        printf 'ERROR: %s prompt has %s lines; maximum is %s\n' "$agent" "$lines" "${MAX_LINES[$agent]}" >&2
        exit 1
    }
done
for agent in translation-worker translation-qa translation-repair translation-terminology; do
    grep -Fq 'Поверни тільки JSON-масив' "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s lacks an exact JSON-only output rule\n' "$agent" >&2
        exit 1
    }
done

for primary in патч ручний пропозиції покращення; do
    grep -Fq 'subagent_type=next.role' "$ROOT/.opencode/agents/$primary.md" || {
        printf 'ERROR: %s must invoke a native visible Task\n' "$primary" >&2
        exit 1
    }
done

test "$(jq -r '.subagent_depth' "$CONFIG")" = '1' || {
    printf 'ERROR: subagent_depth must be 1\n' >&2
    exit 1
}

# Four workflow primaries are selectable; patch is the safe weekly default.
test "$(jq -r '.default_agent // empty' "$CONFIG")" = 'патч' || {
    printf 'ERROR: default_agent must be "патч"\n' >&2
    exit 1
}
for primary in патч ручний пропозиції покращення; do
    test "$(jq -r --arg p "$primary" '.agent[$p].mode // empty' "$CONFIG")" = 'primary' || {
        printf 'ERROR: %s must be mode "primary"\n' "$primary" >&2
        exit 1
    }
    grep -Fq './bdo smoke' "$ROOT/.opencode/agents/$primary.md" || {
        printf 'ERROR: %s primary does not route smoke separately\n' "$primary" >&2
        exit 1
    }
    grep -Fq 'translation_result' "$ROOT/.opencode/agents/$primary.md" || {
        printf 'ERROR: %s primary does not save native Task output\n' "$primary" >&2
        exit 1
    }
done
for primary in build plan general explore; do
    test "$(jq -r --arg p "$primary" '.agent[$p].disable // empty' "$CONFIG")" = 'true' || {
        printf 'ERROR: general primary agent %s must be disabled\n' "$primary" >&2
        exit 1
    }
done

printf 'Translation UI agents: profile %s is consistent across policy, config and frontmatter.\n' "$active_profile"
