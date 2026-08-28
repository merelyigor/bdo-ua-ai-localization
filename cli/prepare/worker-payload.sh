#!/usr/bin/env bash
# Побудувати компактний payload для translation-worker або translation-repair.
#
#   ./worker-payload.sh rows.json                 # з прикладами (за замовчуванням)
#   ./worker-payload.sh rows.json --no-context     # без прикладів, без звернень до API
#   ./worker-payload.sh rows.json --with-current   # + поточний machine-переклад (для retranslate)
#   ./worker-payload.sh rows.json --with-reference # + російський довідковий текст
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
WITH_REFERENCE=""
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --no-context)   WANT_CONTEXT=0 ;;
        --with-context) WANT_CONTEXT=1 ;;   # дефолт; лишається для сумісності
        --with-current) WITH_CURRENT="--with-current" ;;
        --with-reference) WITH_REFERENCE="--with-reference" ;;
        *) echo "Невідомий прапорець: $1" >&2; exit 1 ;;
    esac
    shift
done

CONTEXT_FILE=""
# Терміни пачки живуть окремим файлом, бо `context.json` читають ще qa-payload
# і judge-payload у старій формі «приклади за хешем».
TERMS_FILE=""
if [ "$WANT_CONTEXT" = 1 ]; then
    # Тека пачки, якщо вона є: тоді контекст переживе цей запуск і дістанеться QA.
    # Без розпочатої пачки лишається тимчасовий файл · QA його не побачить.
    BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
    if [ -n "$BATCH_DIR" ]; then
        CONTEXT_FILE="$BATCH_DIR/context.json"
        TERMS_FILE="$BATCH_DIR/terms.json"
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
        // ОДИН запит на всю пачку замість запиту на кожен рядок.
        //
        // До 2026-08-28 тут був цикл `GET /rows/{hash}/context`: 29-50 HTTP на
        // пачку, і проба з трьох рядків існувала саме тому, що кожен запит
        // коштував окремо. Сервер отримав `POST /agent/v1/rows/context`
        // (версія 3.7.5), який приймає масив хешів і повертає ту саму структуру
        // ключем за identity_hash. Проба більше не потрібна: порожній корпус
        // коштує рівно один запит.
        //
        // Ліміт пачки контексту віддає сам сервер у `GET /me`
        // (`data.batch.max_context_rows`); зашивати 50 у клієнт не можна ·
        // власник міняє його змінною оточення без зміни коду.
        $rows = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR)["data"]["rows"] ?? [];
        $hashes = [];
        foreach ($rows as $row) {
            $hash = (string) ($row["identity_hash"] ?? "");
            if ($hash !== "") $hashes[] = $hash;
        }
        $http = getenv("BDO_CONTEXT_HTTP") ?: $argv[5];
        $call = static function (string $url, ?string $body) use ($http, $argv): ?array {
            $command = escapeshellarg($http) . " -fsS -H " . escapeshellarg("X-API-Key: " . $argv[3]);
            if ($body !== null) {
                $command .= " -X POST -H " . escapeshellarg("Content-Type: application/json")
                    . " -d " . escapeshellarg($body);
            }
            $command .= " " . escapeshellarg($url);
            $lines = [];
            $status = 0;
            exec($command . " 2>/dev/null", $lines, $status);
            if ($status !== 0) return null;
            $data = json_decode(implode("\n", $lines), true);
            return is_array($data) ? $data : null;
        };

        $limit = 50;
        $me = $call($argv[2] . "/me", null);
        if (isset($me["data"]["batch"]["max_context_rows"])) {
            $limit = max(1, (int) $me["data"]["batch"]["max_context_rows"]);
        }

        $contexts = [];
        $requests = 0;
        $failed = 0;
        foreach (array_chunk($hashes, $limit) as $chunk) {
            // Один повтор перед тим, як здатись: мережевий збій і недоступний
            // контекст · різні речі, і платити пачкою за перший не можна.
            $answer = null;
            foreach ([0, 1] as $attempt) {
                $requests++;
                $answer = $call($argv[2] . "/rows/context", json_encode(["identity_hashes" => $chunk]));
                if ($answer !== null) break;
                if ($attempt === 0) sleep(2);
            }
            if ($answer === null) { $failed++; break; }
            foreach ($answer["data"]["contexts"] ?? [] as $hash => $context) {
                $contexts[$hash] = $context;
            }
        }
        // Контекст пачки НЕ є прикрасою: у ньому приходять затверджені терміни
        // глосарію з `severity=mandatory`. 2026-08-28 цей запит мовчки не вдався
        // на пачці 20260828_100456, модель перекладала `Cheongsa Island`
        // наосліп, і 11 із 24 рядків модерації · це той самий острів у трьох
        // різних варіантах, хоча відповідник «Острів Ліхтарів» був затверджений
        // і повертався API. «Робочий payload зі слабшим сигналом» тут означає
        // зіпсовану пачку, тому онлайн-шлях падає, а не деградує.
        if ($failed > 0) {
            fwrite(STDERR, "Контекст пачки недоступний після повтору · payload НЕ будується.\n");
            fwrite(STDERR, "У контексті приходять затверджені терміни глосарію; без них пачка піде в модерацію.\n");
            exit(3);
        }

        // `context.json` лишається у СТАРІЙ формі (приклади за хешем): його
        // читають ще qa-payload і judge-payload, і ламати їх заради одного
        // споживача не можна.
        $examples = [];
        $terms = [];
        foreach ($contexts as $hash => $context) {
            $rowExamples = [];
            foreach (array_slice($context["related_rows"] ?? [], 0, 3) as $related) {
                $text = $related["translation"]["text"] ?? null;
                $src = $related["source_text"] ?? null;
                if (is_string($text) && is_string($src) && $text !== "" && $src !== "") {
                    $rowExamples[] = ["en" => $src, "ua" => $text];
                }
            }
            if ($rowExamples !== []) $examples[$hash] = $rowExamples;

            // Терміни · СПІЛЬНІ для пачки й дедупліковані за канонічною назвою.
            // Модель має бачити не лише відповідник, а й СИЛУ правила
            // (`policy`, `severity`), ознаку неоднозначності та опис із вікі,
            // коли він зʼявиться. Порожні поля не кладемо: сьогодні `definition`
            // порожній у всіх термінів, і зайвий null лише важчає payload.
            foreach ($context["terms"] ?? [] as $term) {
                $canonical = (string) ($term["canonical_source"] ?? "");
                if ($canonical === "" || isset($terms[$canonical])) continue;
                $entry = ["canonical_source" => $canonical];
                foreach (["ukrainian", "policy", "severity", "entity_type", "definition", "wiki_url"] as $field) {
                    $value = $term[$field] ?? null;
                    if (is_string($value) && $value !== "") $entry[$field] = $value;
                }
                // Відсутність поля НЕ дорівнює відсутності опису.
                //
                // Порожні поля з payload викидаються заради ваги, і після цього
                // «немає ключа `definition`» читається однаково і як «опису в
                // базі немає», і як «сервер про нього не сказав». Різниця
                // критична: на першому можна пропонувати опис, на другому · ні,
                // інакше пропозиція перезапише те, що вже написала людина.
                // Тому факт відповіді фіксується окремо й лише коли ключ
                // ПРИЙШОВ від API.
                if (array_key_exists("definition", $term)) {
                    $entry["has_definition"] = is_string($term["definition"]) && trim($term["definition"]) !== "";
                }
                if (! empty($term["ambiguous"])) $entry["ambiguous"] = true;
                if (! empty($term["scopes"])) $entry["scopes"] = $term["scopes"];
                $terms[$canonical] = $entry;
            }
        }

        file_put_contents($argv[4], json_encode($examples, JSON_UNESCAPED_UNICODE));
        if ($argv[6] !== "") {
            file_put_contents($argv[6], json_encode(array_values($terms), JSON_UNESCAPED_UNICODE));
        }
        $withWiki = count(array_filter($terms, static fn (array $t): bool => isset($t["definition"])));
        fwrite(STDERR, sprintf(
            "Контекст пачки: %d рядків одним запитом%s | приклади для %d рядків | термінів %d (з описом %d)\n",
            count($hashes), $requests > 1 ? " x$requests" : "", count($examples), count($terms), $withWiki));
        // Часткова відповідь · теж сигнал: рядок без контексту перекладається
        // без своїх термінів, і мовчати про це не можна.
        $missing = count($hashes) - count($contexts);
        if ($missing > 0) {
            fwrite(STDERR, sprintf("УВАГА: контексту немає для %d рядків із %d.\n", $missing, count($hashes)));
        }
        ' "$ROWS_FILE" "$BDO_API_BASE" "$BDO_API_KEY" "$CONTEXT_FILE" "$SCRIPT_DIR/cli/api/http-request.sh" "$TERMS_FILE"
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


// Приклади · СПІЛЬНИЙ блок, а не копія в кожному рядку.
//
// Заміряно 2026-08-28 на живій пачці (29 рядків): 57 прикладів, з них лише 13
// унікальних · 77% були дослівними повторами, бо рядки пачки належать до однієї
// родини предметів. Ці байти не зникають після виклику: OpenCode зберігає
// підставлений payload у транскрипті диригента, і кожен наступний крок пересилає
// його заново. У тій сесії 24 такі частини важили 2 160 245 байтів · 69% усього
// транскрипту. Дедуплікація прибирає 61% байтів прикладів, не втрачаючи ЖОДНОГО
// прикладу.
//
// Стеля існує, і про відкинуте пишеться прямо: мовчазне обрізання читалось би як
// «прикладів більше не було».
$exampleLimit = (int) (getenv("BDO_SHARED_EXAMPLES") ?: 12);
$sharedExamples = [];
$seenExample = [];
$exampleDropped = 0;
foreach ($examplesByHash as $list) {
    foreach ((array) $list as $example) {
        $key = json_encode($example, JSON_UNESCAPED_UNICODE);
        if (isset($seenExample[$key])) continue;
        $seenExample[$key] = true;
        if (count($sharedExamples) >= $exampleLimit) { $exampleDropped++; continue; }
        $sharedExamples[] = $example;
    }
}


// Бюджет на приклади в БАЙТАХ, а не в штуках.
//
// Заміряно 2026-08-28 на живій пачці (патч 7, `knowledge`, 20 рядків):
// приклади · 8 351 байт із 14 007, тобто 59% payload. Розподіл різко
// нерівний: 230, 240, 254, 388, 402, 405, 459, 472, 484, 625, 1675, 2693.
// Два найдовші важать 52% усіх прикладів · це цілі довгі описи предметів,
// які як few-shot дають не більше за короткі, але витісняють їх з бюджету.
//
// Перевірена гіпотеза, яка НЕ підтвердилась: прибрати приклади для рядків,
// повністю покритих глосарієм. Таких немає структурно · `en` прикладу є цілим
// рядком гри, а не назвою терміна, тому збіг із `canonical_source` дорівнює
// нулю (заміряно: 0 із 12).
//
// Тому відбір іде від КОРОТШИХ: за той самий бюджет модель бачить більше
// різних прикладів. Відкинуте називається прямо · мовчазне обрізання читалось
// би як «прикладів більше не було».
$budget = (int) (getenv("BDO_EXAMPLES_BUDGET") ?: 4000);
if ($budget > 0) {
    usort($sharedExamples, static fn (array $a, array $b): int
        => strlen(json_encode($a, JSON_UNESCAPED_UNICODE)) <=> strlen(json_encode($b, JSON_UNESCAPED_UNICODE)));
    $kept = [];
    $used = 0;
    $skipped = 0;
    foreach ($sharedExamples as $example) {
        $size = strlen(json_encode($example, JSON_UNESCAPED_UNICODE));
        if ($used + $size > $budget && $kept !== []) { $skipped++; continue; }
        $kept[] = $example;
        $used += $size;
    }
    if ($skipped > 0) {
        fwrite(STDERR, sprintf("Приклади: лишено %d із %d у межах %d байтів (відкинуто %d найдовших)\n",
            count($kept), count($sharedExamples), $budget, $skipped));
    }
    $sharedExamples = $kept;
}


// Поняття гри · лише ті, що реально є в тексті ЦІЄЇ пачки.
//
// Перелік має 83 записи; класти всі в кожен payload означало б додавати ту саму
// вагу в транскрипт диригента назавжди (D10). Тому зіставлення робиться тут, у
// коді: ціле слово, з урахуванням регістру для скорочень (`MAP` це Monster AP,
// а `map` · звичайна карта з власною карткою глосарія).
//
// У payload іде лише `term`, `ua` і короткий `gist` (до 200 символів).
// `definition` НЕ кладеться свідомо: він написаний для людини й важить до 4000
// символів. Обрізати його теж не можна · модель прочитає обрізане як повне.
$conceptsFile = getenv("BDO_STATE_DIR") ?: dirname(__DIR__, 2)."/state";
$conceptsFile .= "/game-concepts.json";
$sharedConcepts = [];
if (is_file($conceptsFile)) {
    $all = json_decode((string) file_get_contents($conceptsFile), true)["concepts"] ?? [];
    $haystack = "";
    foreach ($rows as $row) $haystack .= $row->sourceText()."\n";
    $limit = (int) (getenv("BDO_CONCEPTS_MAX") ?: 25);
    $skipped = 0;
    foreach ($all as $concept) {
        $term = (string) ($concept["term"] ?? "");
        if ($term === "") continue;
        $flags = "u".(empty($concept["case_sensitive"]) ? "i" : "");
        if (preg_match("/(?<![\p{L}\p{N}])".preg_quote($term, "/")."(?![\p{L}\p{N}])/".$flags, $haystack) !== 1) {
            continue;
        }
        if (count($sharedConcepts) >= $limit) { $skipped++; continue; }
        $entry = ["term" => $term];
        foreach (["ua", "gist"] as $field) {
            if (isset($concept[$field]) && $concept[$field] !== "") $entry[$field] = $concept[$field];
        }
        $sharedConcepts[] = $entry;
    }
    if ($skipped > 0) {
        fwrite(STDERR, sprintf("Поняття: у тексті знайдено на %d більше за стелю %d (BDO_CONCEPTS_MAX)\n", $skipped, $limit));
    }
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
    // Російський довідковий текст · ЛИШЕ підказка про сенс, ніколи не джерело.
    //
    // API віддає його в кожному рядку (`fields=...,reference,...`), але до
    // моделі він не доходив жодного разу: `worker-payload` про поле просто не
    // знав. Через це головна задача режиму покращення · перекласти наново те,
    // що бот Bosia зробив саме з цього російського тексту · виконувалась
    // наосліп, без доступу до єдиного джерела, яке пояснює, ЩО автор мав на
    // увазі в неоднозначному англійському рядку.
    //
    // Поле вмикається лише там, де воно потрібне за задачею (`improve`).
    // Ризик названий прямо: російський текст поруч підвищує шанс русизму, тому
    // промпт воркера забороняє перекладати з нього, а детектор русизмів і QA
    // лишаються механічною перевіркою. `exportable: false` у самому API
    // означає, що в гру цей текст не потрапляє ніколи.
    if ($argv[5] === "--with-reference") {
        $reference = $row->raw()["reference"]["ru"]["text"] ?? "";
        if (is_string($reference) && $reference !== "") $item["reference_ru"] = $reference;
    }
    if (!empty($examplesByHash[$hash])) $stats["examples"]++;
    $payload[] = $item;
}
// Терміни пачки · спільний блок поруч із прикладами. Модель бачить не лише
// відповідник, а й силу правила; коли глосарій наповнять описами, вони
// доїдуть сюди без жодної зміни коду.
$sharedTerms = [];
if ($argv[6] !== "" && is_file($argv[6])) {
    $sharedTerms = json_decode((string) file_get_contents($argv[6]), true) ?: [];
    $termLimit = (int) (getenv("BDO_SHARED_TERMS") ?: 40);
    if (count($sharedTerms) > $termLimit) {
        fwrite(STDERR, sprintf("Термінів понад стелю: %d, лишаю %d (BDO_SHARED_TERMS)\n",
            count($sharedTerms) - $termLimit, $termLimit));
        $sharedTerms = array_slice($sharedTerms, 0, $termLimit);
    }
}
$out = ["examples" => $sharedExamples, "items" => $payload];
if ($sharedTerms !== []) $out = ["terms" => $sharedTerms] + $out;
if ($sharedConcepts !== []) $out = ["concepts" => $sharedConcepts] + $out;
echo json_encode($out, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
// Підсумок у stderr: диригент звітує з нього, замість перечитувати payload.
// stdout лишається чистим JSON, тому підстановку в промпт це не ламає.
fwrite(STDERR, sprintf(
    "payload воркера: %d рядків | глосарій %d | без відповідника %d | нерозпізнані назви %d | приклади %d спільних (рядків із прикладами %d, відкинуто понад стелю %d) | межі довжини %d\n",
    count($payload), $stats["glossary"], $stats["pending"], $stats["unresolved"],
    count($sharedExamples), $stats["examples"], $exampleDropped, $stats["limits"]));
' "$ROWS_FILE" "$CONTEXT_FILE" "$WITH_CURRENT" "$SCRIPT_DIR/lib/autoload.php" "$WITH_REFERENCE" "$TERMS_FILE"
