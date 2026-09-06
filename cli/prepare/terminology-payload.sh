#!/usr/bin/env bash
# Побудувати компактний payload для translation-terminology.
#
#   ./terminology-payload.sh rows.json
#   ./terminology-payload.sh rows.json --no-resolve   # без звернень до API
#
# Навіщо цей скрипт існує. Раніше primary передавав субагенту ШЛЯХ до
# `rows.json`, і той читав пачку сам інструментом `read`. Пачка містить
# classification, tokens, constraints, glossary, reference і patch на КОЖЕН
# рядок, тобто субагент отримував десятки кілобайт службових полів, щоб дістати
# звідти шість назв. Виміряно на живому прогоні 2026-08-16: дві сесії
# terminology зʼїли 420 244 і 124 920 вхідних токенів · більше за решту флоу
# разом узяту.
#
# Тут з пачки дістається рівно те, що потрібно для роботи з термінами:
# канонічна назва, один представницький рядок для неї (identity_hash плюс
# джерело для контексту) і ГОТОВИЙ результат resolve.
#
# Resolve робиться ТУТ, а не моделлю. Це детермінований факт із каталогу, і
# віддавати його моделі означає додати ймовірність там, де її не було: субагент
# один раз уже вигадав хост `http://localhost/...` і впав. Спершу запит без
# identity; якщо каталог відповів `blocked_identity` (назву мають кілька
# сутностей), запит повторюється з `identity_hash` того рядка, для якого термін
# і потрібен. Обидва кроки механічні.
#
# Наслідок для промпта: субагенту лишається рівно те, що правилом не описати ·
# запропонувати український відповідник. Тому `read` йому більше не потрібен.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"
shift
WANT_RESOLVE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-resolve) WANT_RESOLVE=0 ;;
        *) echo "Невідомий прапорець: $1" >&2; exit 1 ;;
    esac
    shift
done

# Терміни й представницький рядок для кожного. Один рядок на термін достатньо:
# resolve звіряє identity саме сутності, а не всіх її згадок.
TERMS_FILE="$(mktemp)"
# Індекс «термін -> рядок» лишається на НАШОМУ боці: у payload identity не йде,
# але resolve до каталогу без неї неможливий.
INDEX_FILE="$(mktemp)"
trap 'rm -f "$TERMS_FILE" "$INDEX_FILE"' EXIT
php -r '
require $argv[2];
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Payload\Excerpt;
use Bdo\Translate\Payload\TermIndex;

// Відображення «термін -> рядок» будує спільний клас: після відповіді моделі
// те саме відображення повертає `identity_hash` у пропозиції, і два місця не
// мають права розійтися в тому, який рядок вважати представницьким.
$index = TermIndex::forRows(RowSet::fromFile($argv[1]));
$budget = (int) (getenv("BDO_TERM_EXCERPT") ?: Excerpt::DEFAULT_BUDGET);
$terms = [];
foreach ($index as $name => $meta) {
    $item = [
        "canonical_source" => $name,
        "kind" => $meta["kind"],
        // УРИВОК навколо терміна, а не весь опис предмета.
        //
        // Заміряно 2026-09-06: 136 термінів дали payload 111 КБ, `in=43 839`,
        // `out=17 722`, 621 с · найважчий виклик усього флоу. Причина не в
        // кількості термінів, а в тому, що кожен ніс ПОВНИЙ опис предмета.
        // Термінологу потрібне місце, де слово вжите: воно й каже, це назва
        // предмета чи дієслово в прозі.
        "source_text" => Excerpt::around($meta["source_text"], $name, $budget),
    ];
    // `identity_hash` тут БІЛЬШЕ НЕМАЄ, і це друга економія цього виклику.
    // Схема відповіді вимагала переписати його назад полем `source_identity`:
    // 10.5% payload і ~16% виходу на посимвольне копіювання 64 шістнадцяткових
    // знаків (клас D59). Звʼязок відновлює КОД за `canonical_source`.
    //
    // Класифікація рядка лишається: «Move» у підписі кнопки й «Move» у назві
    // вміння · різні терміни, і без `domain` модель розрізняє їх здогадом.
    if ($meta["semantic_type"] !== null) $item["semantic_type"] = $meta["semantic_type"];
    if ($meta["domain"] !== null) $item["domain"] = $meta["domain"];
    $terms[] = $item;
}
file_put_contents($argv[3], json_encode($index, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
echo json_encode($terms, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
' "$ROWS_FILE" "$SCRIPT_DIR/lib/autoload.php" "$INDEX_FILE" > "$TERMS_FILE"

COUNT="$(php -r 'echo count(json_decode(file_get_contents($argv[1]), true) ?: []);' "$TERMS_FILE")"
if [ "$COUNT" = 0 ]; then
    echo '[]'
    echo "Термінів без відповідника немає · translation-terminology не потрібен." >&2
    exit 0
fi

# Resolve по кожному терміну. Недоступний API не валить крок: payload без
# resolve усе одно робочий, лише слабший · так само, як приклади в Q3.
RESOLVED_FILE="$(mktemp)"
trap 'rm -f "$TERMS_FILE" "$RESOLVED_FILE"' EXIT
printf '{}' > "$RESOLVED_FILE"

if [ "$WANT_RESOLVE" = 1 ]; then
    if ! bash "$SCRIPT_DIR/cli/system/select-env.sh" >/dev/null 2>&1; then
        echo "Resolve пропущено: середовище недоступне (немає .env або ключа)." >&2
        WANT_RESOLVE=0
    fi
fi

if [ "$WANT_RESOLVE" = 1 ]; then
    READY=0; BLOCKED=0; UNKNOWN=0
    while IFS=$'\t' read -r name hash; do
        [ -n "$name" ] || continue
        out="$("$SCRIPT_DIR/cli/api/glossary-resolve.sh" "$name" 2>/dev/null || true)"
        status="$(printf '%s\n' "$out" | sed -n 's/^status: //p' | sed -n '1p')"
        # Назву мають кілька сутностей · повторюємо з identity того рядка.
        if [ "$status" = blocked_identity ]; then
            out="$("$SCRIPT_DIR/cli/api/glossary-resolve.sh" "$name" "$hash" 2>/dev/null || true)"
            status="$(printf '%s\n' "$out" | sed -n 's/^status: //p' | sed -n '1p')"
        fi
        case "$status" in
            ready) READY=$((READY + 1)) ;;
            blocked_identity) BLOCKED=$((BLOCKED + 1)) ;;
            *) UNKNOWN=$((UNKNOWN + 1)) ;;
        esac
        php -r '
        $file = $argv[1];
        $all = json_decode(file_get_contents($file), true) ?: [];
        $entry = ["status" => $argv[3] !== "" ? $argv[3] : "no_answer"];
        foreach (explode("\n", $argv[4]) as $line) {
            // `source_identity` каталогу сюди НЕ береться: це той самий
            // 64-символьний хеш, тільки загорнутий у рядок JSON. Модель за ним
            // нічого не вирішує · вона працює з `status`, `term_id` і
            // `entity_type`. Наш бік identity й так знає (`TermIndex`).
            foreach (["term_id", "entity_type", "category", "message"] as $k) {
                if (str_starts_with($line, $k . ": ")) $entry[$k] = substr($line, strlen($k) + 2);
            }
        }
        $all[$argv[2]] = $entry;
        file_put_contents($file, json_encode($all, JSON_UNESCAPED_UNICODE));
        ' "$RESOLVED_FILE" "$name" "$status" "$out"
    done < <(php -r '
    // Identity беремо з ІНДЕКСУ: у payload її немає навмисно (модель не мусить
    // переписувати 64 символи хеша), але каталогу вона потрібна.
    foreach (json_decode(file_get_contents($argv[1]), true) as $name => $meta) {
        printf("%s\t%s\n", $name, $meta["identity_hash"]);
    }' "$INDEX_FILE")
    echo "Resolve: $READY ready, $BLOCKED blocked_identity, $UNKNOWN без відповіді каталогу" >&2
fi

php -r '
$terms = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$resolved = json_decode(file_get_contents($argv[2]), true) ?: [];
$out = [];
foreach ($terms as $t) {
    $name = $t["canonical_source"];
    if (isset($resolved[$name])) $t["resolve"] = $resolved[$name];
    $out[] = $t;
}
echo json_encode($out, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
fwrite(STDERR, sprintf("payload terminology: %d термінів (без відповідника %d, нерозпізнаних назв %d)\n",
    count($out),
    count(array_filter($out, fn ($t) => $t["kind"] === "pending")),
    count(array_filter($out, fn ($t) => $t["kind"] === "unresolved"))));
' "$TERMS_FILE" "$RESOLVED_FILE"
