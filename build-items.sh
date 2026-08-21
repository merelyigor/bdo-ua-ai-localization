#!/usr/bin/env bash
# Створити безпечний items.json із rows JSON.
# Hashes беруться тільки з API-вибірки; ручне введення identity/source hash не потрібне.
# Використання: ./build-items.sh rows.json translations.json items.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"
TRANSLATIONS_FILE="${2:?Потрібен translations.json від перекладача}"
OUTPUT_FILE="${3:?Потрібен вихідний items.json}"
ALLOW_REVIEW="${4:-}"
REQUIRE_ALL="${5:-}"

# Пропущений шлях виводу перетворював прапорець на назву файла: виклик
# `build-items.sh rows.json clean.json --require-all` мовчки створював у теці
# скриптів файл з іменем `--require-all` і повними перекладами всередині. Знайдено
# 2026-08-17 як безхазяйний файл у git status. Прапорець ніколи не є шляхом.
case "$OUTPUT_FILE" in
    --*)
        echo "Третім аргументом має бути шлях до items.json, а не прапорець '$OUTPUT_FILE'." >&2
        echo "Правильно: ./bdo items rows.json clean.json items.json \"\" --require-all" >&2
        exit 1
        ;;
esac

# Вихід model-ab.sh - вимір, а не переклад: він народився поза видимою
# субагентською сесією. Механічна відмова тут і в batch-commit.sh - це те, що
# тримає виняток «shell-runner викликає модель» безпечним.
# Шлях нормалізується: перша версія перевірки зіставляла рядок як є й пропускала
# той самий файл, переданий відносним шляхом.
if [ -e "$TRANSLATIONS_FILE" ] && case "$(cd "$(dirname "$TRANSLATIONS_FILE")" && pwd)" in
        */output/benchmark) true ;; *) false ;;
    esac
then
    echo "Це файл виміру (output/benchmark/), а не переклад. Записувати його не можна." >&2
    exit 1
fi

php -r '
require $argv[6];
use Bdo\Translate\Batch\RowSet;

$byHash = RowSet::fromFile($argv[1])->writeIdentities();
$translations = json_decode(file_get_contents($argv[2]), true, 512, JSON_THROW_ON_ERROR);
$items = [];
$seen = [];
foreach ($translations as $translation) {
    $hash = $translation["identity_hash"] ?? "";
    $text = $translation["text"] ?? null;
    $status = $translation["status"] ?? "ready";
    if (!isset($byHash[$hash])) throw new RuntimeException("Переклад не належить rows.json: $hash");
    if (isset($seen[$hash])) throw new RuntimeException("Дубль identity_hash: $hash");
    $allowAll = $argv[4] === "--allow-review";
    if (!is_string($status) || trim($status) === "" || (!$allowAll && !in_array($status, ["ready", "approved", "translated"], true))) {
        throw new RuntimeException("Незаписуваний статус $status для $hash");
    }
    if (!is_string($text) || trim($text) === "") throw new RuntimeException("Порожній переклад для $hash");
    $seen[$hash] = true;
    $items[] = $byHash[$hash] + ["text" => $text];
}
if ($items === []) throw new RuntimeException("Немає готових перекладів для payload");
if ($argv[5] === "--require-all" && count($items) !== count($byHash)) {
    $missing = array_diff(array_keys($byHash), array_keys($seen));
    throw new RuntimeException("Пачка не має повного coverage; відсутні: " . implode(",", $missing));
}
file_put_contents($argv[3], json_encode($items, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR));
' "$ROWS_FILE" "$TRANSLATIONS_FILE" "$OUTPUT_FILE" "$ALLOW_REVIEW" "$REQUIRE_ALL" \
  "$SCRIPT_DIR/lib/autoload.php"
