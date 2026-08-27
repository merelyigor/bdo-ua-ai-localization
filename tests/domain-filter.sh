#!/usr/bin/env bash
# Категорія рядків доходить від слова власника до query string.
#
# Заміряно на проді 2026-08-27, патч 1: 29 820 рядків без ШІ-шару розподілені
# вкрай нерівно · `premium_shop` 18 036, `ui` 3 063, `dialogue` один. Тобто 60%
# усієї роботи лежить в одній категорії, і брати її окремо має практичний сенс.
# API фільтр `domain=` підтримував завжди; бракувало лише поверхні в наборі.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Фільтр збирається правильно і валідується ДО мережі.
php -r '
require $argv[1];
use Bdo\Translate\Pipeline\RunSpec;
$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };

$got = RunSpec::filterFor("patch", "1", "premium_shop");
if ($got !== "patch=1&missing=machine&domain=premium_shop") $fail("невірний фільтр patch: $got");
$got = RunSpec::filterFor("improve", "1", "quest");
if (! str_contains($got, "machine_provenance=legacy") || ! str_contains($got, "domain=quest")) {
    $fail("режим покращення втратив provenance або категорію: $got");
}
// Порожня категорія нічого не додає: щоденний випадок · увесь патч.
if (str_contains(RunSpec::filterFor("patch", "1"), "domain=")) $fail("порожня категорія потрапила у фільтр");

// Вигадана категорія мусить впасти ТУТ, а не піти в query string.
try {
    RunSpec::filterFor("patch", "1", "вигадка");
    $fail("вигадану категорію прийнято");
} catch (InvalidArgumentException $e) {
    if (! str_contains($e->getMessage(), "Невідома категорія")) $fail("незрозуміла помилка: ".$e->getMessage());
}
// Перелік мусить збігатися з тим, що знає промпт диригента.
$domains = RunSpec::domains();
// Тринадцять, а не дванадцять: `market` забули з першого дня, і команда падала
// б «Невідома категорія» на реальному домені. Живу звірку робить `gate api`.
foreach (["item", "quest", "knowledge", "entity", "skill_effect", "premium_shop",
          "dialogue", "ui", "title", "world", "mission", "market", "unknown"] as $expected) {
    if (! in_array($expected, $domains, true)) $fail("у переліку немає категорії $expected");
}
if (count($domains) !== 13) $fail("очікували 13 категорій, маємо ".count($domains));
' "$ROOT/lib/autoload.php" || fail 'фільтр категорії зламаний'

# 2. Категорія доходить через dispatcher, а не губиться в аргументах.
#    Саме на цьому 2026-08-25 згорів патч-аргумент: скрипт його підтримував,
#    guard пропускав, документація описувала, а `bdo` не передавав далі.
out="$(BDO_STATE_DIR="$(mktemp -d)" "$ROOT/bdo" mode status patch 1 premium_shop 2>/dev/null | tail -1)"
printf '%s' "$out" | grep -q '"domain":"premium_shop"' || fail "dispatcher загубив категорію: $out"
printf '%s' "$out" | grep -q 'domain=premium_shop' || fail "категорія не дійшла у фільтр: $out"
out="$(BDO_STATE_DIR="$(mktemp -d)" "$ROOT/bdo" mode status patch 1 2>/dev/null | tail -1)"
printf '%s' "$out" | grep -q '"domain":null' || fail "без категорії домен мусить бути null: $out"

# 3. Промпти мусять знати ту саму тринадцятку українською.
for primary in патч ручний пропозиції покращення-ші; do
    file="$ROOT/.opencode/agents/$primary.md"
    grep -Fq 'магазин перлів `premium_shop`' "$file" || fail "$primary не знає відповідності категорій"
    # `market` бракувало і в коді, і в промпті: обидва місця мусить тримати тест.
    grep -Fq '`market`' "$file" || fail "$primary не знає категорії market"
    grep -Fq 'Питання ПРО КАТЕГОРІЇ' "$file" || fail "$primary не розпізнає запит про категорії"
    # Диригент 2026-08-27 написав у звіті два вигаданих числа поспіль.
    grep -Fq 'ЖОДНОГО числа від себе' "$file" || fail "$primary дозволяє числа по памʼяті"
done

# 4. QA в режимі покращення бачить поточний переклад · без нього він не має чим
#    міряти «краще», хоча саме це є питанням режиму.
grep -Fq -- '--with-current' "$ROOT/cli/prepare/qa-payload.sh" || fail 'qa-payload не приймає поточний переклад'
grep -Fq 'qa_args+=(--with-current)' "$ROOT/cli/run/run-drive.sh" || fail 'рушій не дає QA поточний переклад у improve'

echo 'domain filter: OK'
