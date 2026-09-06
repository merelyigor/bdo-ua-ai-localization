#!/usr/bin/env bash
# Термінолог отримує УРИВОК навколо терміна, а не весь опис предмета.
#
# Заміряно 2026-09-06 на живому прогоні: 136 термінів дали payload 111 КБ,
# `in=43 839`, `out=17 722`, 621 секунду · найважчий виклик усього флоу,
# більший за воркер і QA разом. Причина не в кількості термінів, а в тому, що
# кожен запис ніс ПОВНИЙ `source_text` рядка, а описи предметів BDO довгі.
#
# Термінологу потрібне МІСЦЕ, де слово вжите: саме воно каже, це назва предмета
# чи дієслово в прозі. Тому вікно навколо згадки · і воно мусить бути чесно
# позначене трикрапкою, інакше модель прочитає уривок як повний рядок.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Сам відбір вікна ----------------------------------------------------
php -r '
require $argv[1];
use Bdo\Translate\Payload\Excerpt;

$long = str_repeat("а", 400)." Epheria Carrack ".str_repeat("б", 400);

$out = Excerpt::around($long, "Epheria Carrack", 240);
if (mb_strlen($out) > 242 + 2) { fwrite(STDERR, "вікно довше за бюджет: ".mb_strlen($out)."\n"); exit(1); }
if (! str_contains($out, "Epheria Carrack")) { fwrite(STDERR, "сам термін не потрапив у вікно\n"); exit(1); }
if (! str_starts_with($out, "…") || ! str_ends_with($out, "…")) {
    fwrite(STDERR, "обрізаний край не позначено трикрапкою: ".mb_substr($out, 0, 20)."\n"); exit(1);
}
// Контекст потрібен З ОБОХ боків: «Move» у назві кнопки й «move» у реченні
// виглядають однаково, а означають різне.
$before = mb_substr($out, 1, mb_strpos($out, "Epheria") - 1);
if (mb_strlen($before) < 50) { fwrite(STDERR, "ліворуч від терміна майже немає контексту\n"); exit(1); }

// Короткий рядок не чіпаємо взагалі · різати нема чого.
$short = "Iron Sword";
if (Excerpt::around($short, "Iron", 240) !== $short) { fwrite(STDERR, "короткий рядок обрізано без потреби\n"); exit(1); }

// Термін не знайдено дослівно (відмінок, інший регістр) · беремо початок:
// назва майже завжди на початку, і це чесніше за порожнечу.
$miss = Excerpt::around($long, "чого-тут-немає", 240);
if (! str_starts_with($miss, "а")) { fwrite(STDERR, "без збігу взято не початок тексту\n"); exit(1); }
if (! str_ends_with($miss, "…")) { fwrite(STDERR, "обрізання без збігу не позначено\n"); exit(1); }

// Регістр не має ховати збіг.
if (! str_contains(Excerpt::around($long, "epheria carrack", 240), "Epheria")) {
    fwrite(STDERR, "збіг не знайдено через регістр\n"); exit(1);
}
' "$ROOT/lib/autoload.php" || fail 'вікно навколо терміна працює не так, як обіцяно'

# --- 2. Будівник payload СПРАВДІ ним користується ---------------------------
# Перевірка на даних, а не на написанні: беремо рядок із довгим описом і
# дивимось у готовий payload.
H1="$(printf 1 | shasum -a 256 | awk '{print $1}')"
php -r '
$long = str_repeat("опис предмета ", 120)." Epheria Carrack ".str_repeat("хвіст ", 120);
file_put_contents($argv[1], json_encode(["data" => ["rows" => [[
    "identity_hash" => $argv[2],
    "source_hash" => hash("sha256", "x"),
    "source_text" => $long,
    "classification" => ["domain" => "item", "semantic_type" => "name"],
    "glossary" => ["terms" => [[
        "canonical_source" => "Epheria Carrack",
        "ukrainian" => null,
        "severity" => "mandatory",
    ]]],
]]]], JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE));' "$TMP/rows.json" "$H1"

out="$(BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/prepare/terminology-payload.sh" "$TMP/rows.json" --no-resolve 2>/dev/null)"
test -n "$out" || fail 'будівник payload термінолога нічого не віддав'
php -r '
require $argv[1];
use Bdo\Translate\Payload\Items;
$items = Items::rows(json_decode($argv[2], true));
if ($items === []) { fwrite(STDERR, "у payload немає термінів\n"); exit(1); }
$src = (string) ($items[0]["source_text"] ?? "");
if (mb_strlen($src) > 300) {
    fwrite(STDERR, "у payload лежить ПОВНИЙ опис (".mb_strlen($src)." символів) · саме це дало 111 КБ і 621 с\n");
    exit(1);
}
if (! str_contains($src, "Epheria Carrack")) { fwrite(STDERR, "уривок не містить самого терміна\n"); exit(1); }
if (! str_contains($src, "…")) { fwrite(STDERR, "обрізання не позначене трикрапкою\n"); exit(1); }
' "$ROOT/lib/autoload.php" "$out" || fail 'payload термінолога не звузився до уривка'

# --- 2б. Хеш у модель НЕ йде, а identity все одно повертається --------------
#
# Заміряно 2026-09-06 на виклику зі 113 термінів: `identity_hash` займав 10.5%
# payload, а схема відповіді вимагала переписати його назад полем
# `source_identity` · близько 16% виходу на посимвольне копіювання 64
# шістнадцяткових знаків. Рівно той клас, який для інших ролей закрив D59.
php -r '
require $argv[1];
use Bdo\Translate\Payload\Items;
foreach (Items::rows(json_decode($argv[2], true)) as $item) {
    foreach ($item as $k => $v) {
        if (is_string($v) && preg_match("~^[0-9a-f]{64}$~", $v)) {
            fwrite(STDERR, "у payload термінолога лежить хеш у полі «{$k}» · модель переписуватиме 64 знаки (D59)\n");
            exit(1);
        }
    }
}' "$ROOT/lib/autoload.php" "$out" || fail 'хеш повернувся в payload термінолога'

# Відповідь каталогу теж не має тягнути хеш у модель: `resolve.source_identity`
# це той самий хеш, лише загорнутий у рядок JSON.
grep -Fq '"source_identity"' "$ROOT/cli/prepare/terminology-payload.sh" \
    && fail 'у payload знову береться resolve.source_identity · це той самий хеш для моделі'

# Схема відповіді теж не має його просити.
php -r '
$s = json_decode((string) file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
$props = $s["properties"]["items"]["items"]["properties"] ?? [];
if (isset($props["source_identity"])) {
    fwrite(STDERR, "схема відповіді знову вимагає source_identity від моделі\n"); exit(1);
}' "$ROOT/roles/schema/translation-terminology.json" || fail 'схема просить у моделі те, що знає код'

# Але identity МУСИТЬ повертатись у пропозицію · її потрібно для API.
php -r '
require $argv[1];
use Bdo\Translate\Batch\RowSet;
use Bdo\Translate\Payload\TermIndex;
$index = TermIndex::forRows(RowSet::fromFile($argv[2]));
$out = TermIndex::attachIdentity([
    ["canonical_source" => "Epheria Carrack", "status" => "ready"],
    ["canonical_source" => "чого-в-пачці-не-було", "status" => "no_answer"],
], $index);
if (($out[0]["source_identity"]["identity_hash"] ?? "") !== $argv[3]) {
    fwrite(STDERR, "identity не повернулась у пропозицію: ".json_encode($out[0], JSON_UNESCAPED_UNICODE)."\n"); exit(1);
}
// Чужому терміну хеш не вигадуємо: мовчазна підстановка гірша за відсутність.
if (isset($out[1]["source_identity"])) {
    fwrite(STDERR, "терміну, якого в пачці не було, приписано чужу identity\n"); exit(1);
}' "$ROOT/lib/autoload.php" "$TMP/rows.json" "$H1" || fail 'код не відновлює identity за canonical_source'

# І рушій мусить це РОБИТИ, а не лише вміти.
grep -Fq 'TermIndex::attachIdentity(' "$ROOT/cli/run/run-drive.sh" \
    || fail 'рушій не повертає identity в пропозиції термінів · артефакт для власника буде неповний'

# --- 3. Промпт не має обіцяти повного рядка ---------------------------------
grep -Fq 'УРИВОК рядка навколо цього терміна' "$ROOT/roles/translation-terminology.md" \
    || fail 'промпт термінолога досі каже, що source_text · весь рядок'

echo 'terminology excerpt: OK · вікно навколо терміна, край позначено, промпт каже правду.'
