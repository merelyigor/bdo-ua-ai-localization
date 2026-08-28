#!/usr/bin/env bash
# Зібрати підозрілі записи глосарію в окремий звіт для власника.
#
#   ./glossary-suspects.sh            # звіт + позначки
#   ./glossary-suspects.sh --list     # лише показати, нічого не писати
#
# Джерело · реєстр термінів, які реально трапились у роботі
# (`state/term-notes-queue.json`). Це навмисно не весь глосарій: перевіряти
# треба те, що вже псує пачки, а не те, що ніколи не траплялось.
#
# Пишемо ДВА файли з різним призначенням:
#   docs/plans/GLOSSARY_SUSPECTS.md · звіт для людини, його власник віддає на
#     перевірку;
#   state/glossary-suspects.json    · позначки для коду: ці терміни не їдуть у
#     payload як закон і не викидають приклади, поки людина не вирішить.
#
# Глосарій не змінюється НІКОЛИ: ми лише позначаємо, а рішення ухвалює власник.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${BDO_STATE_DIR:-$SCRIPT_DIR/state}"
QUEUE="$STATE_DIR/term-notes-queue.json"
MARKS="$STATE_DIR/glossary-suspects.json"
REPORT="$SCRIPT_DIR/docs/plans/GLOSSARY_SUSPECTS.md"
LIST_ONLY=0
test "${1:-}" = --list && LIST_ONLY=1

if [ ! -s "$QUEUE" ]; then
    echo 'Реєстр термінів порожній · підозри збирати нема з чого. Реєстр наповнюють прогони.' >&2
    exit 1
fi

php -r '
require $argv[1];

use Bdo\Translate\Quality\GlossarySuspects;

$terms = json_decode((string) file_get_contents($argv[2]), true)["terms"] ?? [];
$suspects = GlossarySuspects::find($terms);
$listOnly = $argv[5] === "1";

printf("Термінів у реєстрі: %d | підозрілих: %d\n", count($terms), count($suspects));
foreach ($suspects as $s) {
    printf("  %s -> %s · %s (%s), траплявся %d раз(ів)\n",
        $s["canonical_source"], $s["ukrainian"], $s["reason"], $s["detail"], $s["seen"]);
}
if ($listOnly) exit(0);

// Позначки для коду: рівно назви термінів і причина, без тексту звіту.
$marks = ["updated_at" => gmdate("c"), "terms" => []];
foreach ($suspects as $s) {
    $marks["terms"][$s["canonical_source"]] = ["reason" => $s["reason"], "ukrainian" => $s["ukrainian"]];
}
file_put_contents($argv[3], json_encode($marks, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR)."\n");

$rows = "";
$samples = [];
foreach ($terms as $term) {
    $samples[(string) ($term["canonical_source"] ?? "")] = $term["samples"][0] ?? "";
}
foreach ($suspects as $s) {
    $sample = str_replace(["|", "\n"], [" ", " "], (string) ($samples[$s["canonical_source"]] ?? ""));
    $rows .= sprintf("| `%s` | `%s` | %s | %s | %d | %s |\n",
        $s["canonical_source"], $s["ukrainian"], $s["reason"], $s["detail"], $s["seen"],
        mb_substr($sample, 0, 60));
}
$text = "# Підозрілі записи глосарію\n\n"
    ."Згенеровано `./bdo suspects` з реєстру термінів, які реально трапились у\n"
    ."прогонах (`state/term-notes-queue.json`). Це НЕ вирок: глосарій лишається\n"
    ."законом, а тут лише перелік записів, які на вигляд помилкові й потребують\n"
    ."людини. Жоден запис не змінено · зміна глосарію є рішенням власника.\n\n"
    ."Позначені терміни поки не подаються моделі як обовʼязкові й не викидають\n"
    ."приклади: помилковий закон псує кожен рядок, де трапився термін.\n\n"
    ."Класи підозр:\n\n"
    ."- `time_unit_mismatch` · одиниця часу перекладена іншою одиницею часу;\n"
    ."- `function_word` · займенник або визначник як обовʼязковий термін;\n"
    ."- `acronym` · абревіатура, яку кодом не перевірити;\n"
    ."- `duplicate_ukrainian` · один відповідник на кілька різних термінів.\n\n"
    ."| Термін | Відповідник | Клас | Чому | Разів | Приклад рядка |\n"
    ."|---|---|---|---|---|---|\n"
    .($rows === "" ? "| — | — | — | підозрілих записів немає | 0 | — |\n" : $rows);
file_put_contents($argv[4], $text);
printf("Звіт: %s\nПозначки: %s\n", $argv[4], $argv[3]);
' "$SCRIPT_DIR/lib/autoload.php" "$QUEUE" "$MARKS" "$REPORT" "$LIST_ONLY"
