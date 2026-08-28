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

// Два формати входу з однією семантикою:
//   NDJSON  · повний каталог із `glossary-list.sh` (136 тисяч записів, у памʼять
//             цілком не влазить · читаємо потоком);
//   {"terms":[…]} · реєстр баченого в роботі.
// Приклади рядків беремо лише з другого: у повному переліку їх немає.
$suspects = [];
$samples = [];
$count = 0;
$handle = fopen($argv[2], "rb");
if ($handle === false) { fwrite(STDERR, "Не читається джерело термінів.\n"); exit(1); }
$first = fgets($handle);
rewind($handle);
$isNdjson = is_string($first) && str_starts_with(ltrim($first), "{") && ! str_contains($first, "\"terms\"");
if ($isNdjson) {
    while (($line = fgets($handle)) !== false) {
        $term = json_decode($line, true);
        if (! is_array($term)) continue;
        $count++;
        $hit = GlossarySuspects::perTerm($term);
        if ($hit !== null) $suspects[] = $hit;
    }
} else {
    $terms = json_decode((string) stream_get_contents($handle), true)["terms"] ?? [];
    $count = count($terms);
    $suspects = GlossarySuspects::find($terms);
    foreach ($terms as $term) {
        $samples[(string) ($term["canonical_source"] ?? "")] = $term["samples"][0] ?? "";
    }
}
fclose($handle);
$listOnly = $argv[5] === "1";

printf("Джерело: %s | термінів: %d | підозрілих: %d\n",
    $argv[6] === "full" ? "весь глосарій" : "лише бачені в роботі", $count, count($suspects));
foreach ($suspects as $s) {
    printf("  %s -> %s · %s (%s), траплявся %d раз(ів)\n",
        $s["canonical_source"], $s["ukrainian"], $s["reason"], $s["detail"], $s["seen"]);
}
if ($listOnly) exit(0);

// Позначки для коду: рівно назви термінів і причина, без тексту звіту.
// `withhold` вирішує, чи прибирати термін із payload. Не кожна підозра цього
// варта: `untranslated_target` каже моделі те саме, що й оригінал, і прибрати
// його означає ЗМІНИТИ поведінку там, де помилки ще ніхто не довів.
// Прибираємо з payload лише підміну змісту. Косметика розмітки й регістру
// лишається моделі: вона каже те саме, що й оригінал, а мовчки міняти
// поведінку через дрібницю не можна.
$withheld = ["latin_target_mismatch" => true, "time_unit_mismatch" => true];
$marks = ["updated_at" => gmdate("c"), "terms" => []];
foreach ($suspects as $s) {
    $marks["terms"][$s["canonical_source"]] = [
        "reason" => $s["reason"],
        "ukrainian" => $s["ukrainian"],
        "withhold" => isset($withheld[$s["reason"]]),
    ];
}
file_put_contents($argv[3], json_encode($marks, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT | JSON_THROW_ON_ERROR)."\n");

$rows = "";
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
    ."- `latin_target_mismatch` · у полі відповідника стоїть ІНШИЙ латинський\n"
    ."  рядок (`Bilson -> Kiraki`, `Gladius -> Labour Day`): у гру йде чуже імʼя\n"
    ."  чи чужа назва, тобто ПІДМІНА ЗМІСТУ. Такий термін моделі не подається;\n"
    ."- `time_unit_mismatch` · одиниця часу перекладена іншою одиницею часу;\n"
    ."- `markup_or_space_only` · різниця лише в пробілах або PA-розмітці;\n"
    ."- `case_only` · різниця лише в регістрі.\n\n"
    ."Два останні класи · косметика, і вони НЕ прибираються з payload. Але\n"
    ."нулем вони теж не є: поки такий запис лишався `mandatory`, у гру йшов\n"
    ."рядок зі зміненим пробілом або регістром.\n\n"
    ."Дослівний збіг (`AP -> AP`) і політика `keep_source` підозрою не є: це\n"
    ."свідоме «не перекладати». Правила «один відповідник на кілька термінів»\n"
    ."немає навмисно · на повному каталозі таких 47 205 із 136 022 (35%), це\n"
    ."нормальні варіанти предметів, а не дефект.\n\n"
    ."| Термін | Відповідник | Клас | Чому | Разів | Приклад рядка |\n"
    ."|---|---|---|---|---|---|\n"
    .($rows === "" ? "| — | — | — | підозрілих записів немає | 0 | — |\n" : $rows);
file_put_contents($argv[4], $text);
printf("Звіт: %s\nПозначки: %s\n", $argv[4], $argv[3]);
' "$SCRIPT_DIR/lib/autoload.php" "$SOURCE_FILE" "$MARKS" "$REPORT" "$LIST_ONLY" "$SOURCE_KIND"
