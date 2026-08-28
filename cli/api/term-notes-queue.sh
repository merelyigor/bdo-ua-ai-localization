#!/usr/bin/env bash
# Черга термінів, яким бракує опису · збирається під час прогону, нічого не шле.
#
#   ./term-notes-queue.sh <terms.json> <rows.json>   # додати терміни пачки
#   ./term-notes-queue.sh --report [N]               # показати найчастіші
#
# Навіщо саме черга, а не автоматична пропозиція.
#
# Рішення власника 2026-08-28: часу на довгу модерацію немає, глосарій уже
# наповнений, тому НОВИЙ термін пропонувати не треба взагалі · лише опис до
# наявного, і лише коли впевненість у релевантності саме для Black Desert
# перевищує 50%. Виміряно того ж дня: у пачці з 20 рядків 9 термінів мають
# затверджений відповідник і ЖОДЕН не має опису. На патчі це сотні пропозицій ·
# черга модерації стала б непридатною, як свого часу карантин.
#
# Тому набір спершу лише РАХУЄ: який термін скільки разів трапився і в яких
# рядках. Це і є пріоритет для заповнення описів, і його видно без жодного
# виклику моделі та без жодного запису в API. Надсилання пропозицій · окремий
# крок, який вмикається свідомо.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=cli/system/paths.sh
source "$SCRIPT_DIR/cli/system/paths.sh"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
QUEUE="$STATE_DIR/term-notes-queue.json"

if [ "${1:-}" = "--report" ]; then
    test -s "$QUEUE" || { echo 'Черга порожня: жодна пачка ще не додала термінів без опису.'; exit 0; }
    php -r '
    $queue = json_decode((string) file_get_contents($argv[1]), true)["terms"] ?? [];
    usort($queue, static fn (array $a, array $b): int => ($b["seen"] ?? 0) <=> ($a["seen"] ?? 0));
    $limit = (int) ($argv[2] ?: 20);
    printf("Термінів без опису в черзі: %d. Найчастіші %d:\n\n", count($queue), min($limit, count($queue)));
    foreach (array_slice($queue, 0, $limit) as $term) {
        printf("  %-38s %-26s трапився %d\n", $term["canonical_source"], $term["ukrainian"] ?? "?", $term["seen"] ?? 0);
        if (! empty($term["samples"][0])) printf("      %s\n", mb_substr($term["samples"][0], 0, 96));
    }
    echo "\nЗаповнювати описи · в адмінці глосарія, згори вниз за частотою.\n";
    ' "$QUEUE" "${2:-20}"
    exit 0
fi

TERMS_FILE="${1:?Потрібен terms.json пачки}"
ROWS_FILE="${2:?Потрібен rows.json пачки}"
test -s "$TERMS_FILE" || exit 0

php -r '
require $argv[4];
use Bdo\Translate\Batch\RowSet;

$terms = json_decode((string) file_get_contents($argv[1]), true) ?: [];
$rows = RowSet::fromFile($argv[2]);
$queueFile = $argv[3];
$queue = is_file($queueFile) ? (json_decode((string) file_get_contents($queueFile), true)["terms"] ?? []) : [];

$byName = [];
foreach ($queue as $entry) {
    if (isset($entry["canonical_source"])) $byName[$entry["canonical_source"]] = $entry;
}

// Snapshot пачки віддає сам API у `meta.snapshot_id` відповіді `/rows`.
$snapshotId = json_decode((string) file_get_contents($argv[2]), true)["meta"]["snapshot_id"] ?? null;
$snapshotId = is_int($snapshotId) ? $snapshotId : null;
$added = 0;
$unknown = 0;
foreach ($terms as $term) {
    $name = (string) ($term["canonical_source"] ?? "");
    // Беремо ЛИШЕ наявні терміни з ДОВЕДЕНО порожнім описом.
    //
    // Три різні випадки, і плутати їх означає зіпсувати чужі дані:
    //   опис є        · термін закритий, чіпати не можна;
    //   опису немає   · кандидат (API прямо сказав `definition: null`);
    //   невідомо      · API не віддав поля взагалі · МОВЧКИ ПРОПУСКАЄМО.
    // Третій випадок трапляється на старішому деплої сервера, і саме він
    // небезпечний: якби «немає ключа» читалось як «немає опису», пропозиція
    // пішла б поверх уже написаного людиною тексту.
    if ($name === "" || ($term["ukrainian"] ?? "") === "") {
        continue;
    }
    if (! array_key_exists("has_definition", $term)) {
        $unknown++;
        continue;
    }
    if ($term["has_definition"] === true || ($term["definition"] ?? "") !== "") {
        continue;
    }
    $entry = $byName[$name] ?? [
        "canonical_source" => $name,
        "ukrainian" => (string) $term["ukrainian"],
        "entity_type" => $term["entity_type"] ?? null,
        "seen" => 0,
        "samples" => [],
    ];
    $entry["seen"] = (int) $entry["seen"] + 1;
    // Кілька живих рядків · це те, з чого людина або модель зможе написати опис.
    // Разом із ними зберігаємо identity ПЕРШОГО такого рядка й snapshot пачки:
    // `POST /glossary/proposals` вимагає `source_identity`, і вигадати його
    // потім буде ні з чого.
    if (count($entry["samples"]) < 3) {
        foreach ($rows as $row) {
            $text = $row->sourceText();
            if ($text === "" || ! str_contains($text, $name)) continue;
            $sample = mb_substr($text, 0, 200);
            if (! in_array($sample, $entry["samples"], true)) $entry["samples"][] = $sample;
            if (! isset($entry["identity_hash"])) $entry["identity_hash"] = $row->identityHash();
            break;
        }
    }
    if ($snapshotId !== null && ! isset($entry["snapshot_id"])) $entry["snapshot_id"] = $snapshotId;
    if (! isset($byName[$name])) $added++;
    $byName[$name] = $entry;
}

$tmp = $queueFile.".tmp";
file_put_contents($tmp, json_encode(
    ["updated_at" => gmdate("c"), "terms" => array_values($byName)],
    JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR,
));
rename($tmp, $queueFile);
fprintf(STDERR, "Терміни без опису: %d у черзі (нових цією пачкою %d)\n", count($byName), $added);
if ($unknown > 0) {
    // Мовчазний пропуск читався б як «таких термінів немає».
    fprintf(STDERR, "Пропущено %d термінів: сервер не сказав, чи є в них опис · пропонувати наосліп не можна.\n", $unknown);
}
' "$TERMS_FILE" "$ROWS_FILE" "$QUEUE" "$SCRIPT_DIR/lib/autoload.php"
