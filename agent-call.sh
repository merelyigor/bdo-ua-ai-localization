#!/usr/bin/env bash
# Викликати локального субагента НАПРЯМУ, без OpenCode.
#
#   ./agent-call.sh worker payload.json schema.json    > candidate.json
#   ./agent-call.sh repair payload.json schema.json    > fixes.json
#   ./agent-call.sh qa     payload.json qa-schema.json > verdicts.json
#
# «Субагент» тут - не інша логіка, а ТОЙ САМИЙ контракт, що в OpenCode-флоу:
# системний промпт береться з translation-<роль>.md у TRANSLATE_AGENTS_DIR, модель
# і температура - з його frontmatter, відповідь обмежена тією самою staged-схемою.
# Різниця лише в тому, що запит іде в Ollama /v1 без UI.
#
# Гарантії, які в OpenCode тримає плагін, тут тримає сам скрипт:
#   - модель звіряється з allowlist із validate-translation-agents.sh;
#   - -mlx відкидається (MLX мовчки ігнорує constrained decoding);
#   - reasoning_effort=none (інакше Qwen віддає бюджет у reasoning);
#   - відповідь, що не парситься як JSON, повторюється до BDO_AGENT_RETRIES разів.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=paths.sh
source "$SCRIPT_DIR/paths.sh"
ROLE="${1:?Потрібна роль: worker|repair|qa}"
PAYLOAD_FILE="${2:?Потрібен payload.json}"
SCHEMA_FILE="${3:?Потрібен schema.json}"

case "$ROLE" in
    worker|repair|qa) ;;
    *) echo "Дозволені ролі: worker, repair, qa. Отримано '$ROLE'." >&2; exit 1 ;;
esac
for f in "$PAYLOAD_FILE" "$SCHEMA_FILE"; do
    test -f "$f" || { echo "Немає файлу: $f" >&2; exit 1; }
done

translate_require_path TRANSLATE_AGENTS_DIR 'каталог промптів субагентів' "$TRANSLATE_AGENTS_DIR"
AGENT_FILE="$TRANSLATE_AGENTS_DIR/translation-$ROLE.md"
test -f "$AGENT_FILE" || { echo "Немає промпту агента: $AGENT_FILE" >&2; exit 1; }

OLLAMA_URL="${BDO_OLLAMA_URL:-http://127.0.0.1:11434}"
RETRIES="${BDO_AGENT_RETRIES:-2}"

MODEL="$(awk -F': ' '/^model: /{print $2; exit}' "$AGENT_FILE")"
MODEL="${MODEL#ollama-local/}"
TEMPERATURE="$(awk -F': ' '/^temperature: /{print $2; exit}' "$AGENT_FILE")"
TEMPERATURE="${TEMPERATURE:-0.1}"

# Той самий allowlist, що тримає маршрутизацію в OpenCode. Джерело одне,
# щоб зміна моделі не вимагала правити два списки.
translate_require_path TRANSLATE_AGENT_VALIDATOR 'валідатор агентів' "$TRANSLATE_AGENT_VALIDATOR"
if ! grep -o "ollama-local/[A-Za-z0-9._:-]*" "$TRANSLATE_AGENT_VALIDATOR" \
        | sed 's|^ollama-local/||' | grep -Fxq "$MODEL"; then
    echo "Модель '$MODEL' не в allowlist validate-translation-agents.sh." >&2
    exit 1
fi
case "$MODEL" in
    *-mlx*) echo "MLX-модель заборонена: ігнорує constrained decoding." >&2; exit 1 ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$AGENT_FILE" > "$TMP_DIR/system.txt"

php -r '
$body = [
    "model" => $argv[1],
    "messages" => [
        ["role" => "system", "content" => file_get_contents($argv[2])],
        ["role" => "user", "content" => file_get_contents($argv[3])],
    ],
    "temperature" => (float) $argv[4],
    "reasoning_effort" => "none",
    "response_format" => [
        "type" => "json_schema",
        "json_schema" => ["name" => "translations", "strict" => true,
            "schema" => json_decode(file_get_contents($argv[5]), true, 512, JSON_THROW_ON_ERROR)],
    ],
];
file_put_contents($argv[6], json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
' "$MODEL" "$TMP_DIR/system.txt" "$PAYLOAD_FILE" "$TEMPERATURE" "$SCHEMA_FILE" "$TMP_DIR/request.json"

attempt=0
while :; do
    attempt=$((attempt + 1))
    if curl -fsS -m 1800 -X POST "$OLLAMA_URL/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            --data-binary "@$TMP_DIR/request.json" -o "$TMP_DIR/response.json" \
       && php -r '
            $r = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
            if (isset($r["error"])) exit(1);
            $items = json_decode($r["choices"][0]["message"]["content"] ?? "", true);
            if (!is_array($items)) exit(1);
            file_put_contents($argv[2], json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
            $u = $r["usage"] ?? [];
            fprintf(STDERR, "agent-call %s: елементів %d | in=%d out=%d\n",
                $argv[3], count($items), $u["prompt_tokens"] ?? 0, $u["completion_tokens"] ?? 0);
       ' "$TMP_DIR/response.json" "$TMP_DIR/parsed.json" "$ROLE" 2> "$TMP_DIR/stats.txt"
    then
        cat "$TMP_DIR/stats.txt" >&2
        cat "$TMP_DIR/parsed.json"
        exit 0
    fi
    if [ "$attempt" -gt "$RETRIES" ]; then
        echo "agent-call $ROLE: відповідь не пройшла розбір після $attempt спроб." >&2
        head -c 400 "$TMP_DIR/response.json" >&2 2>/dev/null || true
        exit 1
    fi
    echo "agent-call $ROLE: спроба $attempt невдала, повторюю..." >&2
done
