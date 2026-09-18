#!/usr/bin/env bash
# Шлях рядка крізь пачку лишає слід · один запис замість шести файлів.
#
# НАВІЩО. Питання «чому цей рядок опинився в модерації» доводилось збирати
# руками з `model-items.json`, `clean.json`, `healed.json`,
# `final-candidate.json`, `verdicts.json` і `judge-verdicts.json`. Двічі за
# сесію 2026-09-18 під це писався окремий скрипт, а пачка з вироком «суддя: у
# ШІ-шар 0, до людини 6» не лишила сліду ЧОМУ.
#
# Перевіряється ПОВЕДІНКА класу на справжніх файлах і те, що слід пише саме той
# крок, який знає маршрут · `BatchCommitCommand`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Слід відповідає на питання, заради якого його й заводили -------------
php -r '
require $argv[1];
use Bdo\Translate\Pipeline\Lineage;
$dir = $argv[2];
$h1 = str_repeat("a", 64);   // писала модель, ремонт переписав
$h2 = str_repeat("b", 64);   // закрила памʼять, ніхто не чіпав
file_put_contents($dir."/model-items.json", json_encode([["identity_hash" => $h1, "text" => "з моделі"]]));
file_put_contents($dir."/clean.json", json_encode([
    ["identity_hash" => $h1, "text" => "Пас Апейрон"],
    ["identity_hash" => $h2, "text" => "Залізний меч"],
]));
file_put_contents($dir."/healed.json", json_encode([
    ["identity_hash" => $h1, "text" => "Пояс Апейрон"],
    ["identity_hash" => $h2, "text" => "Залізний меч"],
]));
file_put_contents($dir."/final-candidate.json", json_encode([
    ["identity_hash" => $h1, "text" => "Пояс Апейрон"],
    ["identity_hash" => $h2, "text" => "Залізний меч"],
]));

$lineage = Lineage::forBatch($dir);
$lineage->add($h1, "s1", ["status" => "REVIEW", "severity" => "minor", "issue" => "русизм", "fix" => "Пояс Апейрон"],
    ["destination" => "ai_layer", "confidence" => 82], [], "pass");
$lineage->add($h2, "s2", ["status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""], null, [], "pass");
if ($lineage->count() !== 2) { fwrite(STDERR, "FAIL: у сліді не два рядки\n"); exit(1); }
if (! $lineage->write($dir)) { fwrite(STDERR, "FAIL: слід не записано\n"); exit(1); }

$rows = [];
foreach (file($dir."/lineage.jsonl", FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    $row = json_decode($line, true);
    $rows[$row["identity_hash"]] = $row;
}
$a = $rows[$h1]; $b = $rows[$h2];
// Рядок моделі: ремонт його переписав, суддя відправив у шар.
if ($a["origin"] !== "worker") { fwrite(STDERR, "FAIL: рядок моделі позначено як памʼять\n"); exit(1); }
if ($a["repair"]["changed"] !== true) { fwrite(STDERR, "FAIL: ремонт переписав рядок, а слід цього не каже\n"); exit(1); }
// НАСКІЛЬКИ переписав · без числа важку заміну видно лише тому, хто піде
// звіряти файли руками. На тестовій пачці 2026-09-18 одна з шести правок мала
// 65.6% і замінила добрий переклад гіршим.
if (! isset($a["repair"]["similarity"]) || ! is_numeric($a["repair"]["similarity"])) {
    fwrite(STDERR, "FAIL: слід не каже, НАСКІЛЬКИ ремонт переписав рядок\n"); exit(1);
}
if ($a["repair"]["similarity"] >= 100) {
    fwrite(STDERR, "FAIL: переписаний рядок має схожість 100% · число нічого не міряє\n"); exit(1);
}
// JSON повертає 100.0 як ціле 100 · порівнюємо ЧИСЛА, а не типи, інакше
// перевірка падала б на справному коді.
if ((float) $b["repair"]["similarity"] !== 100.0) {
    fwrite(STDERR, "FAIL: незмінений рядок мусить мати схожість 100%, маємо ".json_encode($b["repair"]["similarity"])."\n"); exit(1);
}
if ($a["names"]["changed"] !== false) { fwrite(STDERR, "FAIL: підстановка назв рядка не чіпала, а слід каже інше\n"); exit(1); }
if (($a["judge"]["destination"] ?? "") !== "ai_layer" || ($a["judge"]["confidence"] ?? 0) !== 82) {
    fwrite(STDERR, "FAIL: рішення судді не дійшло до сліду\n"); exit(1);
}
if ($a["qa"]["fix"] !== true) { fwrite(STDERR, "FAIL: наявність fix від QA не зафіксована\n"); exit(1); }
// Рядок памʼяті: моделі не було, судді не було, ніхто нічого не міняв.
if ($b["origin"] !== "memory") { fwrite(STDERR, "FAIL: рядок памʼяті позначено як роботу моделі\n"); exit(1); }
if ($b["judge"] !== null) { fwrite(STDERR, "FAIL: суддя зʼявився там, де його не було\n"); exit(1); }
if ($b["repair"]["changed"] !== false || $b["names"]["changed"] !== false) {
    fwrite(STDERR, "FAIL: незмінений рядок виглядає переписаним\n"); exit(1);
}
// ТЕКСТІВ У СЛІДІ НЕМАЄ НАВМИСНО · інакше тека пачки подвоїлась би.
if (str_contains(file_get_contents($dir."/lineage.jsonl"), "Пояс Апейрон")) {
    fwrite(STDERR, "FAIL: слід тягне тексти рядків · вага теки пачки подвоїться\n"); exit(1);
}
' "$ROOT/lib/autoload.php" "$TMP" || fail 'слід рядка не відповідає на питання про маршрут'

# --- 2. Пише його саме той крок, який знає маршрут ---------------------------
# САБОТАЖ: прибрати виклик `Lineage::forBatch` або `->write(` · блок червоніє.
COMMIT="$ROOT/lib/Cli/Command/Batch/BatchCommitCommand.php"
grep -Fq 'Lineage::forBatch(' "$COMMIT" \
    || fail 'крок запису не збирає сліду · маршрут знову доведеться реконструювати'
grep -Fq '$lineage->add(' "$COMMIT" \
    || fail 'слід не поповнюється в циклі рішення про маршрут'
grep -Fq '$lineage->write(' "$COMMIT" \
    || fail 'слід нікуди не скидається'
# Слід потрібен і на ТЕСТОВОМУ прогоні: питання «чому рядок пішов до людини»
# виникає саме там. Тому запис стоїть ПЕРЕД гілкою `$doWrite`.
# Змінні в голці екрануємо: у подвійних лапках PHP підставив би `$doWrite`
# порожнім рядком, голка стала б `if () {`, не знайшлась би ніколи · і
# перевірка мовчки проходила б на будь-якому коді.
php -r '
$src = file_get_contents($argv[1]);
$write = strpos($src, "\$lineage->write(");
if ($write === false) { fwrite(STDERR, "FAIL: немає запису сліду\n"); exit(1); }
$lastBranch = strrpos($src, "if (\$doWrite) {");
if ($lastBranch === false) { fwrite(STDERR, "FAIL: не знайшов гілки справжнього запису\n"); exit(1); }
if ($write > $lastBranch) {
    fwrite(STDERR, "FAIL: слід пишеться лише при справжньому записі · на тестовому прогоні його не буде\n");
    exit(1);
}
' "$COMMIT" || fail 'слід недоступний на тестовому прогоні'

echo 'lineage: OK · шлях рядка лишає один запис, і пише його крок, який знає маршрут'
