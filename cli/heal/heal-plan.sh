#!/usr/bin/env bash
# Довести пачку до повного PASS, витративши мінімум викликів моделі.
#
#   ./heal-plan.sh rows.json candidate.json verdicts.json [validate.json]
#
# Друкує в stdout план дій і готує файли; сам модель НЕ викликає - виклик
# translation-repair лишається за диригентом у видимій субагентській сесії.
#
# СХОДИНКИ ЛІКУВАННЯ, від найдешевшої до найдорожчої. Рядок піднімається на
# наступну сходинку, лише якщо попередня його не полагодила:
#
#   1. `repaired_text` від API. Сервер уже полагодив рядок сам і повернув текст
#      у validate. Це безкоштовно й детерміновано, а ми досі це викидали.
#   2. `fix` від QA, пропущений фільтром cli/quality/qa-fixes.sh (дрібна правка, >=85%
#      схожості, без русизмів, токени й довжина цілі). Нуль викликів моделі.
#   3. translation-repair - лише те, що не полагодили сходинки 1-2.
#   4. Карантин - лише те, що не полагодила навіть модель за N спроб.
#
# ЦИКЛ ОБМЕЖЕНИЙ ОДНИМ КОЛОМ ЛІКУВАННЯ. Послідовність фіксована:
#   QA -> repair проблемних -> контрольний QA по них -> запис.
# Після BDO_HEAL_MAX_ATTEMPTS (типово 1) рядок більше не йде в repair: те, що
# не вилікувалось, іде в модерацію, де його подивиться людина.
#
# Чому саме одне коло. На прогоні 2026-08-16 пачка з 20 рядків з'їла 11
# субагентських сесій (5 QA, 3 repair, 2 terminology): цикл ганявся, доки
# кожен рядок не стане PASS. Друге й третє коло дають одиниці врятованих
# рядків, а коштують кількох хвилин кожне. Дешевше показати такий рядок
# власнику в модерації, ніж домагатися PASS від моделі.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json}"
CAND_FILE="${2:?Потрібен candidate.json}"
VERDICT_FILE="${3:?Потрібен verdicts.json від translation-qa}"
VALIDATE_FILE="${4:-}"
MAX_ATTEMPTS="${BDO_HEAL_MAX_ATTEMPTS:-1}"

for f in "$ROWS_FILE" "$CAND_FILE" "$VERDICT_FILE"; do
    test -f "$f" || { echo "Немає файлу: $f" >&2; exit 1; }
done
mkdir -p "$SCRIPT_DIR/state"

# Крок 2 виконує наявний фільтр: він уже вміє відсіювати зіпсовані fix.
BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
if [ -z "$BATCH_DIR" ]; then
    echo "Пачку не розпочато: ./bdo batch new rows.json" >&2
    echo "Без теки пачки файли лікування змішалися б із чужими." >&2
    exit 1
fi
# Належність файлів пачці перевіряємо ДО будь-якої роботи й окремим скриптом:
# так повідомлення лишається читабельним, а перевірку може викликати й диригент.
"$SCRIPT_DIR/cli/batch/batch-assert.sh" "$ROWS_FILE" "$CAND_FILE" >/dev/null

QA_FIXES="$BATCH_DIR/heal-qa-fixes.json"
"$SCRIPT_DIR/cli/quality/qa-fixes.sh" "$VERDICT_FILE" "$ROWS_FILE" "$CAND_FILE" > "$QA_FIXES" 2>/dev/null || true

php -r '
require $argv[8];
use Bdo\Translate\Api\ErrorCodes;
use Bdo\Translate\Api\Response;
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Quality\Defects;
use Bdo\Translate\Quality\VerdictSet;

$rows = RowSet::fromFile($argv[1]);
$candidate = Candidate::fromFile($argv[2]);

$verdicts = VerdictSet::fromFile($argv[3]);
$validate = $argv[4] !== "" && file_exists($argv[4]) ? Response::fromFile($argv[4], "validate") : null;
$qaFixes = file_exists($argv[5]) ? (json_decode(file_get_contents($argv[5]), true) ?: []) : [];
$attemptsFile = $argv[6];
$maxAttempts = max(1, (int) $argv[7]);
$mergedFile = $argv[9];
$repairFile = $argv[10];

// Лічильник спроб привʼязаний до ключа пачки, тому нова пачка починає з нуля
// без ручного скидання: перша ж забута пачка інакше приїхала б у карантин із
// чужими лічильниками.
$batchKey = $rows->key();
$state = file_exists($attemptsFile) ? (json_decode(file_get_contents($attemptsFile), true) ?: []) : [];
$attempts = (($state["batch"] ?? "") === $batchKey) ? ($state["attempts"] ?? []) : [];

// --- сходинка 1: те, що вже полагодив сам сервер ---
$serverFixed = [];
foreach ($validate?->serverRepairs() ?? [] as $hash => $text) {
    if ($rows->has($hash)) $serverFixed[$hash] = $text;
}

// --- сходинка 2: дрібні правки QA, що пройшли фільтр ---
$qaFixed = [];
foreach ($qaFixes as $f) {
    $hash = $f["identity_hash"] ?? "";
    if (isset($serverFixed[$hash])) continue;   // сервер сильніший за модель
    $qaFixed[$hash] = (string) ($f["text"] ?? "");
}

// --- що взагалі треба лікувати ---
$defects = [];
foreach ($verdicts->nonPass() as $v) {
    $hash = $v["identity_hash"] ?? "";
    $defects[$hash][] = trim((string) ($v["issue"] ?? "")) ?: "QA: " . ($v["status"] ?? "?");
}
// Механічні перевірки - самостійне джерело дефектів: QA їх пропускає.
foreach ($candidate->all() as $hash => $text) {
    foreach (Defects::inTranslation($rows->getOrEmpty($hash), $text) as $defect) {
        $defects[$hash][] = $defect;
    }
}
foreach ($validate?->rejections() ?? [] as $hash => $why) {
    $defects[$hash][] = $why;
}

// --- розкладка по сходинках ---
$merged = [];
$forRepair = [];
$hopeless = [];
$permanent = [];
foreach (array_keys($defects) as $hash) {
    if (isset($serverFixed[$hash])) { $merged[$hash] = ["сервер", $serverFixed[$hash]]; continue; }
    if (isset($qaFixed[$hash]))     { $merged[$hash] = ["QA-fix", $qaFixed[$hash]]; continue; }
    // Постійна відмова API моделі не лікується. `source_equivalent` на назві
    // продукту означає, що воркер вчинив правильно, не перекладаючи її, і
    // repair поверне рівно той самий текст · виміряно 2026-08-23.
    if (array_filter($defects[$hash], static fn (string $d): bool => ErrorCodes::isPermanent($d)) !== []) {
        $permanent[$hash] = true;
        continue;
    }
    $done = (int) ($attempts[$hash] ?? 0);
    if ($done >= $maxAttempts) { $hopeless[$hash] = $done; continue; }
    $forRepair[$hash] = array_values(array_unique($defects[$hash]));
}

// Злитий кандидат пишемо завжди: він або з правками, або копія вхідного.
$fixes = [];
foreach ($merged as $hash => [$source, $text]) $fixes[$hash] = $text;
file_put_contents($mergedFile, json_encode(
    $candidate->withFixes($fixes)->toList(), JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

// Payload для repair: лише проблемні рядки й лише потрібні поля.
$payload = [];
foreach ($forRepair as $hash => $why) {
    $row = $rows->getOrEmpty($hash);
    $item = [
        "identity_hash" => $hash,
        "source_text" => $row->sourceText(),
        "current" => $candidate->text($hash),
        "defects" => $why,
    ];
    $keep = $row->keepTokens();
    if ($keep !== []) $item["keep"] = $keep;
    $terms = $row->glossary();
    if ($terms !== []) $item["glossary"] = $terms;
    $limits = $row->limits();
    if ($limits !== null) $item["limits"] = $limits;
    $payload[] = $item;
    $attempts[$hash] = (int) ($attempts[$hash] ?? 0) + 1;
}
file_put_contents($repairFile, json_encode($payload, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
file_put_contents($attemptsFile, json_encode(
    ["batch" => $batchKey, "attempts" => $attempts],
    JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT
));

// --- звіт ---
$total = $candidate->count();
$broken = count($defects);
printf("Рядків у пачці: %d | з дефектами: %d\n", $total, $broken);
printf("  вилікувано сервером (repaired_text): %d\n", count(array_filter($merged, fn ($m) => $m[0] === "сервер")));
printf("  вилікувано дрібним fix QA:           %d\n", count(array_filter($merged, fn ($m) => $m[0] === "QA-fix")));
printf("  у translation-repair:                %d\n", count($forRepair));
printf("  API не приймає, модель не поможе:    %d\n", count($permanent));
printf("  у модерацію (після %d кола лікування): %d\n", $maxAttempts, count($hopeless));
foreach ($hopeless as $hash => $done) printf("    %s  спроб: %d\n", substr($hash, 0, 12), $done);

echo "\nЗлитий кандидат: $mergedFile\n";
if ($forRepair !== []) {
    echo "Payload для repair: $repairFile\n";
    printf("\nВИРОК: віддай %s агенту translation-repair, потім КОНТРОЛЬНИЙ QA лише по цих %d рядках - і одразу cli/batch/batch-commit.sh.\n",
        basename($repairFile), count($forRepair));
    echo "Третього кола не буде: те, що лишиться не-PASS, іде в модерацію.\n";
} elseif ($hopeless !== []) {
    echo "\nВИРОК: коло лікування вичерпано. cli/batch/batch-commit.sh: PASS у ШІ-шар, решта в модерацію.\n";
} else {
    echo "\nВИРОК: дефектів не лишилось. Злитий кандидат готовий до cli/batch/batch-commit.sh.\n";
}
' "$ROWS_FILE" "$CAND_FILE" "$VERDICT_FILE" "$VALIDATE_FILE" "$QA_FIXES" \
  "$BATCH_DIR/heal-attempts.json" "$MAX_ATTEMPTS" "$SCRIPT_DIR/lib/autoload.php" \
  "$BATCH_DIR/heal-merged.json" "$BATCH_DIR/heal-repair-payload.json"

# Схему під ПІДМНОЖИНУ ставимо тут, а не залишаємо це на диригента. Активна
# схема worker/repair лишається від кроку 5, тобто від ПОВНОЇ пачки, і repair
# під нею мусить видати рівно стільки обʼєктів, скільки рядків було в пачці.
# Виміряно 2026-08-20 (сесія ses_fe058c4beffeS2a37CphPJbVfz): у repair пішло 7
# рядків, а вийшло 18 обʼєктів рівно з 7 унікальними identity · модель добивала
# довжину повторами, бо enum не давав вигадати чужий хеш. Інструментів вона не
# викликала: це не та поломка, що була в QA, а саме несвіжа схема.
REPAIR_PAYLOAD="$BATCH_DIR/heal-repair-payload.json"
if [ -s "$REPAIR_PAYLOAD" ]; then
    HASHES="$(php -r '
        $rows = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
        echo implode(",", array_column(is_array($rows) ? $rows : [], "identity_hash"));
    ' "$REPAIR_PAYLOAD" 2>/dev/null || true)"
    if [ -n "$HASHES" ]; then
        SUBSET="$BATCH_DIR/heal-repair-subset.json"
        # cli/batch/subset-rows.sh лишає формат API (`data.rows`), якого чекає RowSet;
        # сам payload плаский, і cli/prepare/build-schema.sh його не прочитає.
        # Ставимо ОБИДВІ схеми: repair і контрольного QA. Вони живуть у різних
        # файлах (`current-response-schema.json` і `current-qa-schema.json`),
        # тому не конфліктують, зате контрольний QA після repair одразу отримує
        # правильну довжину. Інакше він успадкував би QA-схему повної пачки й
        # повторив ту саму поломку, що repair: добив би довжину дублікатами.
        if "$SCRIPT_DIR/cli/batch/subset-rows.sh" "$ROWS_FILE" "$HASHES" "$SUBSET" >/dev/null 2>&1 \
           && "$SCRIPT_DIR/cli/prepare/build-schema.sh" "$SUBSET" >/dev/null 2>&1 \
           && "$SCRIPT_DIR/cli/prepare/build-schema.sh" --qa "$SUBSET" >/dev/null 2>&1; then
            echo "Схеми repair і контрольного QA переставлено на підмножину: $SUBSET"
            echo "Наступна пачка перезапише їх сама (кроки build-schema на її rows)."
        else
            echo "УВАГА: не вдалося поставити схему підмножини · зроби вручну:" >&2
            echo "  ./bdo subset $ROWS_FILE $HASHES $BATCH_DIR/heal-repair-subset.json" >&2
            echo "  ./bdo schema build $BATCH_DIR/heal-repair-subset.json" >&2
            echo "  ./bdo schema qa $BATCH_DIR/heal-repair-subset.json" >&2
            exit 1
        fi
    fi
fi
