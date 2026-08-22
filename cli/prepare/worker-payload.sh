#!/usr/bin/env bash
# Побудувати компактний payload для translation-worker або translation-repair.
#
#   ./worker-payload.sh rows.json                 # з прикладами (за замовчуванням)
#   ./worker-payload.sh rows.json --no-context     # без прикладів, без звернень до API
#   ./worker-payload.sh rows.json --with-current   # + поточний machine-переклад (для retranslate)
#
# ПРИКЛАДИ ВВІМКНЕНІ ЗА ЗАМОВЧУВАННЯМ. Промпт воркера сам називає їх найсильнішим
# сигналом («тримайся їхнього стилю й термінології, навіть якщо маєш свою думку»),
# і при цьому вони роками були opt-in, тобто фактично не вживались ніколи.
# Робить по одному запиту `GET /rows/{hash}/context` на рядок і додає до 3 вже
# затверджених пар en/ua зі спільним терміном.
#
# Причина, через яку вони були opt-in, більше не діє: на свіжому патчі endpoint
# віддавав порожньо, і це були N марних викликів. Тепер ШІ-шар покриває 941 273
# записи, тобто корпус є. А проти того самого ризику стоять три запобіжники:
#
#   1. Проба. Перші 3 рядки питаються першими; якщо ЖОДЕН не дав прикладів,
#      решта не питається взагалі. На справді свіжому патчі ціна · 3 виклики, а
#      не 20.
#   2. Готовий контекст не перепитується. Якщо `context.json` у теці пачки вже
#      є (наприклад, повторний виклик після збою воркера), він просто читається.
#   3. Недоступний API не валить пачку. Немає `.env`, ключ не той, мережа впала ·
#      попередження в stderr і payload БЕЗ прикладів. Payload без прикладів
#      робочий; зламана побудова payload зупиняє прогін.
#
# `--with-context` лишається прийнятним і нічого не змінює: це тепер дефолт.
#
# --with-current додає поточний machine-переклад рядка як поле "current". Для
# переперекладу: модель бачить наявний текст і може вирішити, чи варто його
# змінювати. Працює лише якщо rows.json містить поля layers (cli/api/fetch-rows.sh з
# fields=...,layers).
#
# Друкує в stdout мінімальний JSON-масив: identity_hash, source_text,
# semantic_type, mandatory glossary і must_preserve токени. Це єдине, що
# треба вставляти в промпт субагента; повний rows.json з classification та
# службовими полями в промпт не потрапляє, що економить токени primary-моделі.
#
# Контекст зберігається у теку пачки (`context.json`), а не в тимчасовий файл:
# ті самі приклади потрібні `cli/prepare/qa-payload.sh`, інакше QA судить рядок, не бачачи
# підстави, за якою воркер обрав відповідник. Повторно питати API за ними
# означало б заплатити N викликів удруге за те саме.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"
WANT_CONTEXT=1
WITH_CURRENT=""
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --no-context)   WANT_CONTEXT=0 ;;
        --with-context) WANT_CONTEXT=1 ;;   # дефолт; лишається для сумісності
        --with-current) WITH_CURRENT="--with-current" ;;
        *) echo "Невідомий прапорець: $1" >&2; exit 1 ;;
    esac
    shift
done

CONTEXT_FILE=""
if [ "$WANT_CONTEXT" = 1 ]; then
    # Тека пачки, якщо вона є: тоді контекст переживе цей запуск і дістанеться QA.
    # Без розпочатої пачки лишається тимчасовий файл · QA його не побачить.
    BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
    if [ -n "$BATCH_DIR" ]; then
        CONTEXT_FILE="$BATCH_DIR/context.json"
    else
        CONTEXT_FILE="$(mktemp)"
        trap 'rm -f "$CONTEXT_FILE"' EXIT
    fi

    if [ -s "$CONTEXT_FILE" ]; then
        # Запобіжник 2: готовий контекст не перепитується.
        echo "Контекст уже зібраний: $CONTEXT_FILE (API не питаю)" >&2
    # Запобіжник 3: `cli/system/select-env.sh` при відсутньому `.env` або невідомому BDO_ENV
    # робить `exit 1`. Пряме `source` вбило б і цей скрипт, тому спершу проба в
    # підоболонці · вона впасти не може нікого, крім себе.
    elif ! bash "$SCRIPT_DIR/cli/system/select-env.sh" >/dev/null 2>&1; then
        echo "Приклади пропущено: середовище недоступне (немає .env або ключа)." >&2
        echo "Payload будується без них · це робочий payload, лише слабший сигнал." >&2
        CONTEXT_FILE=""
    else
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/cli/system/select-env.sh"
        php -r '
        $rows = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR)["data"]["rows"] ?? [];
        // Запобіжник 1: проба. Якщо перші PROBE рядків не дали жодного приклада,
        // корпус для цієї пачки порожній · решту не питаємо.
        $probe = 3;
        $out = [];
        $asked = 0;
        $failed = 0;
        foreach ($rows as $i => $row) {
            if ($i === $probe && $out === []) break;
            $hash = $row["identity_hash"] ?? "";
            if ($hash === "") continue;
            $url = $argv[2] . "/rows/" . $hash . "/context";
            $ctx = @file_get_contents($url, false, stream_context_create([
                "http" => ["header" => "X-API-Key: " . $argv[3], "timeout" => 30, "ignore_errors" => true],
            ]));
            $asked++;
            if ($ctx === false) { $failed++; continue; }
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
        $total = count($rows);
        if ($out === [] && $asked < $total) {
            fwrite(STDERR, sprintf(
                "Приклади: перші %d рядків не дали жодного · решту %d не питав (порожній корпус для цієї пачки).\n",
                $asked, $total - $asked));
        } else {
            fwrite(STDERR, sprintf("Приклади: %d рядків із %d (запитів %d%s)\n",
                count($out), $total, $asked, $failed > 0 ? ", невдалих $failed" : ""));
        }
        ' "$ROWS_FILE" "$BDO_API_BASE" "$BDO_API_KEY" "$CONTEXT_FILE"
    fi
fi

php -r '
require $argv[4];
use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1]);
$rows->identityHashes();

// Контекст читається ОДИН раз, а не в кожній ітерації.
$examplesByHash = [];
if ($argv[2] !== "" && file_exists($argv[2])) {
    $examplesByHash = json_decode(file_get_contents($argv[2]), true) ?: [];
}

$payload = [];
$stats = ["glossary" => 0, "pending" => 0, "unresolved" => 0, "examples" => 0, "limits" => 0];
foreach ($rows as $row) {
    $hash = $row->identityHash();
    if ($row->sourceText() === "") {
        throw new RuntimeException("Порожній source_text у rows.json: $hash");
    }
    $item = ["identity_hash" => $hash, "source_text" => $row->sourceText()];
    if ($row->semanticType() !== null) $item["semantic_type"] = $row->semanticType();
    $glossary = $row->glossary();
    if ($glossary !== []) { $item["glossary"] = $glossary; $stats["glossary"]++; }
    $keep = $row->keepTokens();
    if ($keep !== []) $item["keep"] = $keep;
    // Термін позначений mandatory, але канонічного відповідника ще немає.
    // Моделі це сигнал перекладати консервативно, а QA - що звірити нема з чим.
    $pending = $row->pendingTerms();
    if ($pending !== []) { $item["canonical_pending"] = $pending; $stats["pending"]++; }
    // Назва, яку API впізнав як сутність, але каталог глосарію її не знає
    // (`evidence_kind: probable_unresolved`). Найнебезпечніший клас рядків: у
    // ШІ-шар за замовчуванням він ЗАПИСУЄТЬСЯ, тобто вигаданий тут варіант стає
    // фактичним стандартом патча. Виміряно на живій пачці · 7 рядків із 20, усі
    // з вердиктом PASS, бо звіряти було ні з чим. Досі модель про це не чула:
    // позначка існувала лише для вироку glossary-gaps і маршруту в модерацію.
    $unresolved = $row->unresolvedEntities();
    if ($unresolved !== []) { $item["unresolved"] = $unresolved; $stats["unresolved"]++; }
    // API перевіряє довжину сам. Якщо не показати ліміт моделі, вона дізнається
    // про нього тільки з rejected на validate.
    $limits = $row->limits();
    if ($limits !== null) { $item["limits"] = $limits; $stats["limits"]++; }
    if ($row->isNonTranslatable()) $item["non_translatable"] = true;
    // Поточний machine-переклад для переперекладу.
    if ($argv[3] === "--with-current") {
        $current = $row->raw()["layers"]["machine"]["text"] ?? "";
        if ($current !== "") $item["current"] = $current;
    }
    if (!empty($examplesByHash[$hash])) { $item["examples"] = $examplesByHash[$hash]; $stats["examples"]++; }
    $payload[] = $item;
}
echo json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
// Підсумок у stderr: диригент звітує з нього, замість перечитувати payload.
// stdout лишається чистим JSON, тому підстановку в промпт це не ламає.
fwrite(STDERR, sprintf(
    "payload воркера: %d рядків | глосарій %d | без відповідника %d | нерозпізнані назви %d | приклади %d | межі довжини %d\n",
    count($payload), $stats["glossary"], $stats["pending"], $stats["unresolved"], $stats["examples"], $stats["limits"]));
' "$ROWS_FILE" "$CONTEXT_FILE" "$WITH_CURRENT" "$SCRIPT_DIR/lib/autoload.php"
