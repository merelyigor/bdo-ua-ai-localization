#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly CONFIG="$ROOT/opencode.json"
# GGUF only: Ollama MLX runner ignores constrained decoding, so -mlx models are forbidden.
readonly ALLOWED_MODELS=('ollama-local/qwen3.6:35b-a3b-mtp-q4_K_M' 'ollama-local/qwen3.5:9b')
readonly AGENTS=(translation-terminology translation-worker translation-qa translation-repair translation-smoke)

jq -e . "$CONFIG" >/dev/null

active="$(jq -r '.agent["translation-worker"].model // empty' "$CONFIG")"
allowed=false
for model in "${ALLOWED_MODELS[@]}"; do
    test "$active" = "$model" && allowed=true
done
if [ "$allowed" != true ]; then
    printf 'ERROR: active model %s is not in the allowed list: %s\n' \
        "$active" "${ALLOWED_MODELS[*]}" >&2
    exit 1
fi
case "$active" in
*-mlx*)
    printf 'ERROR: %s is an MLX model; the MLX runner ignores constrained decoding\n' "$active" >&2
    exit 1
    ;;
esac

for agent in "${AGENTS[@]}"; do
    configured="$(jq -r --arg agent "$agent" '.agent[$agent].model // empty' "$CONFIG")"
    test "$configured" = "$active" || {
        printf 'ERROR: %s model %s differs from active model %s\n' "$agent" "$configured" "$active" >&2
        exit 1
    }
    grep -Fqx "model: $active" "$ROOT/.opencode/agents/$agent.md" || {
        printf 'ERROR: %s frontmatter model does not match project config\n' "$agent" >&2
        exit 1
    }
done

# Constrained агенти не можуть викликати інструменти (грамматика забороняє tool
# calls), тому bash має бути явно заборонений - інакше агент зависне на спробі.
# QA працює read-only. task: deny в усіх пʼяти тримає subagent_depth фактично.
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
    # Payload передається текстом у промпті (`worker-payload.sh`/`qa-payload.sh`).
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

for primary in build plan; do
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

test "$(jq -r '.subagent_depth' "$CONFIG")" = '1' || {
    printf 'ERROR: subagent_depth must be 1\n' >&2
    exit 1
}

printf 'Translation UI agents: %s is active and consistent across config and frontmatter.\n' "$active"
