#!/usr/bin/env bash
# Перемкнути профіль моделі для пʼяти translation-* субагентів.
#
#   ./set-translation-profile.sh quality   # ollama-local/qwen3.6:35b-a3b-mtp-q4_K_M (найкраща українська)
#   ./set-translation-profile.sh fast      # ollama-local/qwen3.5:9b (швидкий fallback)
#   ./set-translation-profile.sh status    # активний профіль і доступність моделі
#
# Змінює opencode.json і frontmatter агентів разом, потім проганяє валідатор.
# Після перемикання перезапусти OpenCode, щоб він перечитав конфіг.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=paths.sh
source "$SCRIPT_DIR/paths.sh"
translate_require_path TRANSLATE_OPENCODE_CONFIG 'конфіг OpenCode' "$TRANSLATE_OPENCODE_CONFIG"
translate_require_path TRANSLATE_AGENTS_DIR 'каталог промптів субагентів' "$TRANSLATE_AGENTS_DIR"
readonly CONFIG="$TRANSLATE_OPENCODE_CONFIG"
readonly QUALITY='ollama-local/qwen3.6:35b-a3b-mtp-q4_K_M'
readonly FAST='ollama-local/qwen3.5:9b'
readonly OLLAMA_URL='http://127.0.0.1:11434'
readonly AGENTS=(translation-terminology translation-worker translation-qa translation-repair translation-smoke)

model_available() {
    curl -fsS -m 5 "$OLLAMA_URL/v1/models" 2>/dev/null \
        | jq -e --arg m "${1#ollama-local/}" '.data[] | select(.id == $m)' >/dev/null
}

show_status() {
    local active
    active="$(jq -r '.agent["translation-worker"].model // empty' "$CONFIG")"
    case "$active" in
    "$QUALITY") echo "Активний профіль: quality ($active)" ;;
    "$FAST")    echo "Активний профіль: fast ($active)" ;;
    *)          echo "Активна модель поза профілями: $active" ;;
    esac
    for model in "$QUALITY" "$FAST"; do
        if model_available "$model"; then
            echo "  доступна: $model"
        else
            echo "  НЕДОСТУПНА в Ollama: $model"
        fi
    done
}

case "${1:-}" in
quality) TARGET="$QUALITY" ;;
fast)    TARGET="$FAST" ;;
status)  show_status; exit 0 ;;
*)       echo "Використання: $0 quality|fast|status" >&2; exit 2 ;;
esac

if ! model_available "$TARGET"; then
    echo "ERROR: модель ${TARGET#ollama-local/} не доступна на $OLLAMA_URL." >&2
    echo "Завантаж її: ollama pull ${TARGET#ollama-local/}" >&2
    exit 1
fi

tmp="$(mktemp)"
jq --arg m "$TARGET" '
    .agent["translation-terminology"].model = $m |
    .agent["translation-worker"].model = $m |
    .agent["translation-qa"].model = $m |
    .agent["translation-repair"].model = $m |
    .agent["translation-smoke"].model = $m
' "$CONFIG" > "$tmp"
mv "$tmp" "$CONFIG"

for agent in "${AGENTS[@]}"; do
    file="$TRANSLATE_AGENTS_DIR/$agent.md"
    php -r '
        $file = $argv[1];
        $model = $argv[2];
        $text = file_get_contents($file);
        $updated = preg_replace("/^model: .*$/m", "model: " . $model, $text, 1);
        if ($updated === null || $updated === $text && !str_contains($text, "model: " . $model)) {
            fwrite(STDERR, "Не вдалося оновити model у $file\n");
            exit(1);
        }
        file_put_contents($file, $updated);
    ' "$file" "$TARGET"
done

translate_require_path TRANSLATE_AGENT_VALIDATOR 'валідатор агентів' "$TRANSLATE_AGENT_VALIDATOR"
bash "$TRANSLATE_AGENT_VALIDATOR"
echo "Профіль перемкнено на: $TARGET"
echo "Перезапусти OpenCode, щоб зміна набула чинності."
