#!/usr/bin/env bash
# Побудувати компактний payload для translation-qa.
#
#   ./qa-payload.sh rows.json candidate.json [--with-current]  # + поточний ШІ-текст
#   ./qa-payload.sh rows.json candidate.json [--with-current]  # + поточний ШІ-текст --context FILE   # приклади з іншого файла
#
# Друкує JSON-масив: identity_hash, source_text, candidate, glossary, keep.
# QA працює під constrained decoding, а обмежена відповідь не може містити
# викликів інструментів, тому QA НЕ читає файли сам: усе, що йому потрібно,
# приходить цим payload.
#
# Принцип входу: QA має бачити ТІ САМІ сигнали, що бачив воркер. Інакше він
# судить у гірших умовах, ніж той, кого перевіряє, і вигадує претензії до
# канонічності · виміряно, що саме такі сумніви дали 121 із 162 не-PASS
# вердиктів на живому патчі. Тому сюди входять і `unresolved`, і `examples`.
#
# `examples` беруться з `context.json` теки пачки, який пише
# `cli/prepare/worker-payload.sh --with-context`. Свого запиту до API цей скрипт не робить:
# платити вдруге за ті самі приклади сенсу немає, а без файла поле просто
# відсутнє.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ROWS_FILE="${1:?Потрібен rows.json з API}"
CANDIDATE_FILE="${2:?Потрібен candidate.json від translation-worker}"
shift 2

CONTEXT_FILE=""
WITH_CURRENT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --context) CONTEXT_FILE="${2:?--context потребує шлях до файла}"; shift 2 ;;
        --with-current) WITH_CURRENT="--with-current"; shift ;;
        *) echo "Невідомий прапорець: $1" >&2; exit 1 ;;
    esac
done
TERMS_FILE=""
if [ -z "$CONTEXT_FILE" ]; then
    BATCH_DIR="$("$SCRIPT_DIR/cli/batch/batch-dir.sh" 2>/dev/null || true)"
    test -n "$BATCH_DIR" && test -f "$BATCH_DIR/context.json" && CONTEXT_FILE="$BATCH_DIR/context.json"
    # Терміни пачки збирає worker-payload одним запитом; QA читає той самий файл.
    test -n "${BATCH_DIR:-}" && test -f "$BATCH_DIR/terms.json" && TERMS_FILE="$BATCH_DIR/terms.json"
fi

php -r '
require $argv[3];
use Bdo\Translate\Batch\Candidate;
use Bdo\Translate\Batch\RowSet;

$rows = RowSet::fromFile($argv[1]);
$candidate = Candidate::fromFile($argv[2]);

$examplesByHash = [];
if ($argv[4] !== "" && file_exists($argv[4])) {
    $examplesByHash = json_decode(file_get_contents($argv[4]), true) ?: [];
}

$payload = [];

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

$stats = ["current" => 0, "glossary" => 0, "pending" => 0, "unresolved" => 0, "examples" => 0, "limits" => 0];
foreach ($rows as $row) {
    $hash = $row->identityHash();
    if (!$candidate->has($hash)) throw new RuntimeException("Немає перекладу для $hash");
    $item = [
        "identity_hash" => $hash,
        "source_text" => $row->sourceText(),
        "candidate" => $candidate->text($hash),
    ];
    if ($row->semanticType() !== null) $item["semantic_type"] = $row->semanticType();
    $glossary = $row->glossary();
    if ($glossary !== []) { $item["glossary"] = $glossary; $stats["glossary"]++; }
    $keep = $row->keepTokens();
    if ($keep !== []) $item["keep"] = $keep;
    // Ті самі сигнали, що бачив воркер: інакше QA судить у гірших умовах,
    // ніж той, кого він перевіряє, і вигадує претензії до канонічності.
    $pending = $row->pendingTerms();
    if ($pending !== []) { $item["canonical_pending"] = $pending; $stats["pending"]++; }
    // Назва поза каталогом глосарію. Для QA це ЗАБОРОНА вигадувати претензію до
    // канонічності, а не підстава знизити вердикт: рішення власника 2026-08-16 ·
    // нова назва предмета не є дефектом, і в ШІ-шарі вона в модерацію не йде.
    // Без цієї позначки QA бачив назву, якої не знає, і мав рівно два виходи ·
    // мовчки PASS або сумнів у стилі «потрібне узгодження щодо власних назв».
    $unresolved = $row->unresolvedEntities();
    if ($unresolved !== []) { $item["unresolved"] = $unresolved; $stats["unresolved"]++; }
    $limits = $row->limits();
    if ($limits !== null) { $item["limits"] = $limits; $stats["limits"]++; }
    if ($row->isNonTranslatable()) $item["non_translatable"] = true;
    // Поточний ШІ-переклад · лише в режимі покращення.
    //
    // Питання цього режиму звучить «чи новий текст кращий за наявний», а QA
    // фізично не міг на нього відповісти: у payload не було чим міряти
    // «краще». Аудит 2026-08-27 показав, що слово `current` не траплялось у
    // цьому файлі жодного разу, тож QA судив новий текст проти англійського в
    // ізоляції й повертав PASS на переклад, не кращий за той, який замінює.
    //
    // Іншим режимам поле не дається: там рядок перекладається з чистого
    // англійського, і зайвий контекст лише підвищує шанс, що QA почне
    // порівнювати з ним замість джерела.
    if ($argv[5] === "--with-current") {
        $current = $row->raw()["layers"]["machine"]["text"] ?? "";
        if (is_string($current) && $current !== "" && $current !== $item["candidate"]) {
            $item["current"] = $current;
            $stats["current"]++;
        }
    }
    if (!empty($examplesByHash[$hash])) $stats["examples"]++;
    $payload[] = $item;
}
// Ті самі терміни, що бачив воркер: інакше QA судить за іншим правилом, ніж
// той, кого перевіряє.
$sharedTerms = [];
if (($argv[6] ?? "") !== "" && is_file($argv[6])) {
    $sharedTerms = json_decode((string) file_get_contents($argv[6]), true) ?: [];
    $termLimit = (int) (getenv("BDO_SHARED_TERMS") ?: 40);
    if (count($sharedTerms) > $termLimit) $sharedTerms = array_slice($sharedTerms, 0, $termLimit);
}
$out = ["examples" => $sharedExamples, "items" => $payload];
if ($sharedTerms !== []) $out = ["terms" => $sharedTerms] + $out;
echo json_encode($out, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR), "\n";
fwrite(STDERR, sprintf(
    "payload QA: %d рядків | глосарій %d | без відповідника %d | нерозпізнані назви %d | приклади %d | межі довжини %d\n",
    count($payload), $stats["glossary"], $stats["pending"], $stats["unresolved"], $stats["examples"], $stats["limits"]));
' "$ROWS_FILE" "$CANDIDATE_FILE" "$SCRIPT_DIR/lib/autoload.php" "$CONTEXT_FILE" "$WITH_CURRENT" "$TERMS_FILE"
