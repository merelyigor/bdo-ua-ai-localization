#!/usr/bin/env bash
# Побудувати компактний payload для translation-worker або translation-repair.
#
#   ./worker-payload.sh rows.json                 # без прикладів
#   ./worker-payload.sh rows.json --with-context   # + підтверджені приклади з API
#   ./worker-payload.sh rows.json --with-current   # + поточний machine-переклад (для retranslate)
#
# --with-context робить по одному запиту GET /rows/{hash}/context на рядок і додає
# до 3 вже перекладених прикладів зі спільним терміном. Вмикати варто лише коли в
# шарі перекладів уже щось є: на свіжому патчі endpoint повертає порожньо, і це
# буде N марних викликів.
#
# --with-current додає поточний machine-переклад рядка як поле "current". Для
# переперекладу: модель бачить наявний текст і може вирішити, чи варто його
# змінювати. Працює лише якщо rows.json містить поля layers (fetch-rows.sh з
# fields=...,layers).
#
# Друкує в stdout мінімальний JSON-масив: identity_hash, source_text,
# semantic_type, mandatory glossary і must_preserve токени. Це єдине, що
# треба вставляти в промпт субагента; повний rows.json з classification та
# службовими полями в промпт не потрапляє, що економить токени primary-моделі.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"
WITH_CONTEXT=""
WITH_CURRENT=""
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --with-context) WITH_CONTEXT="--with-context" ;;
        --with-current) WITH_CURRENT="--with-current" ;;
        *) echo "Невідомий прапорець: $1" >&2; exit 1 ;;
    esac
    shift
done
CONTEXT_FILE=""
if [ "$WITH_CONTEXT" = "--with-context" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/select-env.sh"
    CONTEXT_FILE="$(mktemp)"
    trap 'rm -f "$CONTEXT_FILE"' EXIT
    php -r '
    $rows = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR)["data"]["rows"] ?? [];
    $out = [];
    foreach ($rows as $row) {
        $hash = $row["identity_hash"] ?? "";
        $url = $argv[2] . "/rows/" . $hash . "/context";
        $ctx = @file_get_contents($url, false, stream_context_create([
            "http" => ["header" => "X-API-Key: " . $argv[3], "timeout" => 30, "ignore_errors" => true],
        ]));
        if ($ctx === false) continue;
        $data = json_decode($ctx, true)["data"]["context"] ?? [];
        $examples = [];
        foreach (array_slice($data["related_rows"] ?? [], 0, 3) as $related) {
            $text = $related["translation"]["text"] ?? null;
            $src = $related["source_text"] ?? null;
            if (is_string($text) && is_string($src) && $text !== "" && $src !== "") {
                $examples[] = ["en" => $src, "ua" => $text];
            }
        }
        if ($examples !== []) $out[$hash] = $examples;
    }
    file_put_contents($argv[4], json_encode($out, JSON_UNESCAPED_UNICODE));
    fwrite(STDERR, "Прикладів із контексту: " . count($out) . " рядків із " . count($rows) . "\n");
    ' "$ROWS_FILE" "$BDO_API_BASE" "$BDO_API_KEY" "$CONTEXT_FILE"
fi

php -r '
require $argv[4];
use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1]);
$rows->identityHashes();
$payload = [];
foreach ($rows as $row) {
    $hash = $row->identityHash();
    if ($row->sourceText() === "") {
        throw new RuntimeException("Порожній source_text у rows.json: $hash");
    }
    $item = ["identity_hash" => $hash, "source_text" => $row->sourceText()];
    if ($row->semanticType() !== null) $item["semantic_type"] = $row->semanticType();
    $glossary = $row->glossary();
    if ($glossary !== []) $item["glossary"] = $glossary;
    $keep = $row->keepTokens();
    if ($keep !== []) $item["keep"] = $keep;
    // Термін позначений mandatory, але канонічного відповідника ще немає.
    // Моделі це сигнал перекладати консервативно, а QA - що звірити нема з чим.
    $unresolved = $row->pendingTerms();
    if ($unresolved !== []) $item["canonical_pending"] = $unresolved;
    // API перевіряє довжину сам. Якщо не показати ліміт моделі, вона дізнається
    // про нього тільки з rejected на validate.
    $limits = $row->limits();
    if ($limits !== null) $item["limits"] = $limits;
    if ($row->isNonTranslatable()) $item["non_translatable"] = true;
    // Поточний machine-переклад для переперекладу.
    if ($argv[3] === "--with-current") {
        $current = $row->raw()["layers"]["machine"]["text"] ?? "";
        if ($current !== "") $item["current"] = $current;
    }
    if ($argv[2] !== "" && file_exists($argv[2])) {
        $ctxAll = json_decode(file_get_contents($argv[2]), true) ?: [];
        if (!empty($ctxAll[$hash])) $item["examples"] = $ctxAll[$hash];
    }
    $payload[] = $item;
}
echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
' "$ROWS_FILE" "$CONTEXT_FILE" "$WITH_CURRENT" "$SCRIPT_DIR/lib/autoload.php"
