#!/usr/bin/env bash
# Зібрати підозрілі записи глосарію в окремий звіт для власника.
#
#   ./glossary-suspects.sh            # звіт + позначки
#   ./glossary-suspects.sh --list     # лише показати, нічого не писати
#   ./glossary-suspects.sh --local    # не ходити в API, брати лише бачені терміни
#
# Джерело · ВЕСЬ глосарій через `GET /glossary/terms/list` (сторінками по
# курсору). Поки цього endpoint немає на цілі, скрипт падає назад на реєстр
# термінів, які траплялись у роботі (`state/term-notes-queue.json`), і каже про
# це вголос: «перевірено лише бачене» і «перевірено весь глосарій» · різні
# заяви, і плутати їх не можна.
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
LOCAL_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --list) LIST_ONLY=1 ;;
        --local) LOCAL_ONLY=1 ;;
        *) echo "Невідомий аргумент: $arg" >&2; exit 2 ;;
    esac
done

# Повний перелік глосарію сторінками. Порожній вивід означає «не вдалося»:
# тоді працюємо з реєстром баченого, а не вдаємо повне охоплення.
SOURCE_FILE="$QUEUE"
SOURCE_KIND=seen
if [ "$LOCAL_ONLY" = 0 ] && [ "${BDO_PIPELINE_OFFLINE:-0}" != 1 ]; then
    FULL="$(mktemp)"
    if bash "$SCRIPT_DIR/cli/api/glossary-list.sh" > "$FULL" 2>/tmp/.glossary-list.err; then
        SOURCE_FILE="$FULL"
        SOURCE_KIND=full
    else
        sed -n '1,2p' /tmp/.glossary-list.err >&2
        echo 'Повний перелік недоступний · перевіряю лише терміни, що вже траплялись у роботі.' >&2
    fi
    rm -f /tmp/.glossary-list.err
fi

if [ ! -s "$SOURCE_FILE" ]; then
    echo 'Немає джерела термінів: перелік недоступний, а реєстр баченого порожній.' >&2
    exit 1
fi

php -r '
require $argv[1];

use Bdo\Translate\Quality\GlossarySuspects;

$terms = json_decode((string) file_get_contents($argv[2]), true)["terms"] ?? [];
$suspects = GlossarySuspects::find($terms);
$listOnly = $argv[5] === "1";

printf("Джерело: %s | термінів: %d | підозрілих: %d\n",
    $argv[6] === "full" ? "весь глосарій" : "лише бачені в роботі", count($terms), count($suspects));
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
    .($argv[6] === "full"
        ? "ОХОПЛЕННЯ · весь глосарій, зчитаний сторінками через\n"
          ."`GET /glossary/terms/list`.\n\n"
        : "ОХОПЛЕННЯ · лише терміни, які вже траплялись у прогонах: повний перелік\n"
          ."глосарію був недоступний під час генерації. Це НЕ повний аудит.\n\n")
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
' "$SCRIPT_DIR/lib/autoload.php" "$SOURCE_FILE" "$MARKS" "$REPORT" "$LIST_ONLY" "$SOURCE_KIND"
