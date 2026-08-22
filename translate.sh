#!/usr/bin/env bash
# Викликати локальну модель НАПРЯМУ, з payload і схемою з ДИСКА.
#
#   ./translate.sh worker rows.json              > candidate.json
#   ./translate.sh qa     rows.json candidate.json > verdicts.json
#   ./translate.sh repair payload.json schema.json > fixes.json
#
# НАВІЩО ЦЕ ІСНУЄ. Мовну роботу мали робити субагенти OpenCode, і диригент мусив
# вставляти payload у їхній промпт текстом. Він не зміг: 2026-08-22 чотири прогони
# підряд надіслали воркеру ПОСИЛАННЯ на payload замість самого payload · 303-361
# символ замість 45-57 кілобайт, нуль identity_hash пачки в промпті. Модель без
# даних вигадувала переклади під правильні identity, тому й схема, і аудит їх
# пропускали: `Bundle of 3,000 Crow Coins` ставало `[Титул] Військовий ескорт`.
# Нуль записаних рядків, чотири рази.
#
# Причина архітектурна, не промптова: 57 КБ даних, які лежать на диску, не мають
# сенсу пересилати через контекст мовної моделі. Тут вони йдуть із файла прямо в
# Ollama, тому «payload не дійшов» стає неможливим станом.
#
# Той самий контракт, що в OpenCode: системний промпт із translation-<роль>.md,
# модель і температура з його frontmatter, відповідь під тією самою схемою.
# Гарантії, які там тримає плагін, тут тримає скрипт:
#   - модель звіряється з allowlist із validate-translation-agents.sh;
#   - `-mlx` відкидається (MLX мовчки ігнорує constrained decoding);
#   - reasoning_effort=none (інакше Qwen віддає весь бюджет у reasoning);
#   - відповідь без валідного JSON повторюється до BDO_AGENT_RETRIES разів;
#   - identity звіряються з пачкою ОДРАЗУ: склад, унікальність, непорожній текст.
#
# Аудит не втрачається: кожен виклик пише рядок у state/translate-log.jsonl
# (роль, модель, токени, кількість елементів, час), бо сесії OpenCode тут немає.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=paths.sh
source "$SCRIPT_DIR/paths.sh"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"

ROLE="${1:?Потрібна роль: worker|qa|repair}"
case "$ROLE" in worker|qa|repair) ;; *) echo "Дозволені ролі: worker, qa, repair." >&2; exit 1 ;; esac

translate_require_path TRANSLATE_AGENTS_DIR 'каталог промптів субагентів' "$TRANSLATE_AGENTS_DIR"
AGENT_FILE="$TRANSLATE_AGENTS_DIR/translation-$ROLE.md"
test -f "$AGENT_FILE" || { echo "Немає промпту агента: $AGENT_FILE" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- payload і схема: будуються тут, із файлів, без участі моделі -------------
case "$ROLE" in
    worker)
        ROWS_FILE="${2:?Потрібен rows.json або to-translate.json}"
        test -f "$ROWS_FILE" || { echo "Немає файлу: $ROWS_FILE" >&2; exit 1; }
        "$SCRIPT_DIR/worker-payload.sh" "$ROWS_FILE" > "$TMP_DIR/payload.json"
        "$SCRIPT_DIR/build-schema.sh" --out "$TMP_DIR/schema.json" "$ROWS_FILE" >/dev/null
        IDENTITY_SOURCE="$ROWS_FILE"
        ;;
    qa)
        ROWS_FILE="${2:?Потрібен rows.json}"
        CAND_FILE="${3:?Потрібен candidate.json}"
        "$SCRIPT_DIR/qa-payload.sh" "$ROWS_FILE" "$CAND_FILE" > "$TMP_DIR/payload.json"
        "$SCRIPT_DIR/build-schema.sh" --qa --out "$TMP_DIR/schema.json" "$ROWS_FILE" >/dev/null
        IDENTITY_SOURCE="$ROWS_FILE"
        ;;
    repair)
        cp "${2:?Потрібен payload.json}" "$TMP_DIR/payload.json"
        cp "${3:?Потрібен schema.json}" "$TMP_DIR/schema.json"
        IDENTITY_SOURCE=""
        ;;
esac

OLLAMA_URL="${BDO_OLLAMA_URL:-http://127.0.0.1:11434}"
RETRIES="${BDO_AGENT_RETRIES:-2}"

MODEL="$(awk -F': ' '/^model: /{print $2; exit}' "$AGENT_FILE")"
MODEL="${MODEL#ollama-local/}"
TEMPERATURE="$(awk -F': ' '/^temperature: /{print $2; exit}' "$AGENT_FILE")"
TEMPERATURE="${TEMPERATURE:-0.1}"

# Той самий allowlist, що тримає маршрутизацію в OpenCode: джерело одне, щоб
# зміна моделі не вимагала правити два списки.
translate_require_path TRANSLATE_AGENT_VALIDATOR 'валідатор агентів' "$TRANSLATE_AGENT_VALIDATOR"
if ! grep -o "ollama-local/[A-Za-z0-9._:-]*" "$TRANSLATE_AGENT_VALIDATOR" \
        | sed 's|^ollama-local/||' | grep -Fxq "$MODEL"; then
    echo "Модель '$MODEL' не в allowlist validate-translation-agents.sh." >&2
    exit 1
fi
case "$MODEL" in
    *-mlx*) echo "MLX-модель заборонена: ігнорує constrained decoding." >&2; exit 1 ;;
esac

# Системний промпт · тіло агента без YAML-frontmatter.
awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$AGENT_FILE" > "$TMP_DIR/system.txt"

PAYLOAD_BYTES="$(wc -c < "$TMP_DIR/payload.json" | tr -d ' ')"
echo "translate $ROLE: модель $MODEL | payload $PAYLOAD_BYTES байт із файла" >&2

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
' "$MODEL" "$TMP_DIR/system.txt" "$TMP_DIR/payload.json" "$TEMPERATURE" \
  "$TMP_DIR/schema.json" "$TMP_DIR/request.json"

attempt=0
while :; do
    attempt=$((attempt + 1))
    if curl -fsS -m 1800 -X POST "$OLLAMA_URL/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            --data-binary "@$TMP_DIR/request.json" -o "$TMP_DIR/response.json" \
       && php -r '
            require $argv[6];
            $r = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
            if (isset($r["error"])) { fwrite(STDERR, "Ollama: " . json_encode($r["error"], JSON_UNESCAPED_UNICODE) . "\n"); exit(1); }
            $items = json_decode($r["choices"][0]["message"]["content"] ?? "", true);
            if (! is_array($items)) { fwrite(STDERR, "Відповідь не JSON-масив.\n"); exit(1); }

            // Звірка identity ОДРАЗУ, а не на build-items: саме тут дешево
            // побачити, що модель працювала не з тією пачкою.
            if ($argv[4] !== "") {
                $want = Bdo\Translate\Batch\RowSet::fromFile($argv[4])->identityHashes();
                $got = array_map(static fn ($x) => is_array($x) ? ($x["identity_hash"] ?? null) : null, $items);
                $got = array_values(array_filter($got, static fn ($x) => is_string($x) && $x !== ""));
                if (count($got) !== count($items)) { fwrite(STDERR, "Не в усіх обʼєктах є identity_hash.\n"); exit(1); }
                if (count(array_unique($got)) !== count($got)) { fwrite(STDERR, "Повторений identity_hash.\n"); exit(1); }
                if (array_diff($got, $want) !== []) { fwrite(STDERR, "Чужі identity_hash у відповіді.\n"); exit(1); }
                if (count($got) !== count($want)) {
                    fwrite(STDERR, sprintf("Неповна пачка: %d із %d.\n", count($got), count($want)));
                    exit(1);
                }
            }
            $empty = 0;
            foreach ($items as $x) {
                $t = $x["text"] ?? ($x["status"] ?? null);
                if (! is_string($t) || trim($t) === "") { $empty++; }
            }
            if ($empty > 0) { fwrite(STDERR, "Порожній текст у $empty обʼєктах.\n"); exit(1); }

            file_put_contents($argv[2], json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
            $u = $r["usage"] ?? [];
            fwrite(STDERR, sprintf("translate %s: елементів %d | in=%d out=%d\n",
                $argv[3], count($items), $u["prompt_tokens"] ?? 0, $u["completion_tokens"] ?? 0));
            // Лог замість сесії OpenCode: аудит не має зникнути разом із UI.
            $line = json_encode([
                "at" => date("c"), "role" => $argv[3], "model" => $argv[5],
                "items" => count($items),
                "in" => $u["prompt_tokens"] ?? 0, "out" => $u["completion_tokens"] ?? 0,
            ], JSON_UNESCAPED_UNICODE);
            file_put_contents($argv[7], $line . "\n", FILE_APPEND);
       ' "$TMP_DIR/response.json" "$TMP_DIR/parsed.json" "$ROLE" "$IDENTITY_SOURCE" "$MODEL" \
         "$SCRIPT_DIR/lib/autoload.php" "$STATE_DIR/translate-log.jsonl" 2> "$TMP_DIR/stats.txt"
    then
        cat "$TMP_DIR/stats.txt" >&2
        cat "$TMP_DIR/parsed.json"
        exit 0
    fi
    cat "$TMP_DIR/stats.txt" >&2 2>/dev/null || true
    if [ "$attempt" -gt "$RETRIES" ]; then
        echo "translate $ROLE: відповідь не пройшла перевірку після $attempt спроб." >&2
        exit 1
    fi
    echo "translate $ROLE: спроба $attempt невдала, повторюю..." >&2
done
