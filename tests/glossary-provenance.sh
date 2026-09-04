#!/usr/bin/env bash
# Машинна назва не є законом · ні в payload, ні в промптах.
#
# Заміряно 2026-09-04: із 136 022 записів каталогу 131 391 має
# `ukrainian_layer: machine`, а `manual` · 172. Тобто «затверджений
# відповідник», який промпт називав законом, у 96,6% випадків є машинною
# здогадкою такої самої моделі. Наслідок був видний у вердиктах QA того ж дня:
#
#   REVIEW/minor · Недотримання glossary: 'Timing' перекладено як 'Час',
#   хоча в контексті 'Perfect timing' це допустимо, але glossary вимагає…
#
# Тобто рядок знижено за невживання МАШИННОЇ назви, і в тому ж реченні модель
# сама визнала candidate допустимим. Клас дефекту · «машинний вихід, поданий як
# закон» (той самий, що D60), тепер закритий із трьох боків: payload розділяє
# блоки, промпти трактують їх різно, а цей тест не дає поділу зникнути.
#
# Друга частина · поле `issue`. Модель писала в нього міркування абзацами
# («хоча», «але», «це означає»), і це і вихідні токени, і шум для людини.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Розділення за походженням · у КОДІ, а не в промпті.
php -r '
require $argv[1];
use Bdo\Translate\Batch\Row;
$row = new Row(["identity_hash" => str_repeat("a", 64), "source_text" => "Perfect timing", "glossary" => ["terms" => [
    ["canonical_source" => "Timing", "ukrainian" => "Час", "ukrainian_layer" => "machine"],
    ["canonical_source" => "Panokseon", "ukrainian" => "Паноксон", "ukrainian_layer" => "manual"],
    ["canonical_source" => "Ghost", "ukrainian" => "Привид"],
]]]);
$split = $row->glossaryByLayer();
if (array_keys($split["machine"]) !== ["Timing"]) { fwrite(STDERR, "машинний блок: ".json_encode($split["machine"], 448)."\n"); exit(1); }
// Відсутнє поле НЕ означає «машинне»: невідомий стан лишається на боці людини,
// інакше поділ тихо перетворив би весь каталог у підказки.
if (array_keys($split["human"]) !== ["Panokseon", "Ghost"]) { fwrite(STDERR, "людський блок: ".json_encode($split["human"], 448)."\n"); exit(1); }
// Повний перелік для механіки не змінився: виправлення регістру детерміноване.
if (count($row->glossary()) !== 3) { fwrite(STDERR, "повний глосарій зламано\n"); exit(1); }
' "$ROOT/lib/autoload.php" || fail 'Row::glossaryByLayer() ділить глосарій неправильно'

# 2. Payload віддає ДВА блоки, і машинна назва не потрапляє в `glossary`.
php -r '
$h = str_repeat("b", 64);
file_put_contents($argv[1], json_encode(["data" => ["rows" => [[
    "identity_hash" => $h, "source_hash" => hash("sha256", "Perfect timing"), "source_text" => "Perfect timing",
    "glossary" => ["terms" => [
        ["canonical_source" => "Timing", "ukrainian" => "Час", "ukrainian_layer" => "machine", "severity" => "mandatory"],
        ["canonical_source" => "Panokseon", "ukrainian" => "Паноксон", "ukrainian_layer" => "manual", "severity" => "mandatory"],
    ]],
]]]], JSON_UNESCAPED_UNICODE));
file_put_contents($argv[2], json_encode([["identity_hash" => $h, "text" => "Ідеальний момент"]], JSON_UNESCAPED_UNICODE));
' "$TMP/rows.json" "$TMP/cand.json"

for payload in worker qa; do
    case "$payload" in
        worker) out="$(BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/prepare/worker-payload.sh" "$TMP/rows.json" --no-context 2>/dev/null)" ;;
        qa)     out="$(BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/prepare/qa-payload.sh" "$TMP/rows.json" "$TMP/cand.json" 2>/dev/null)" ;;
    esac
    printf '%s' "$out" | php -r '
    $d = json_decode((string) stream_get_contents(STDIN), true);
    $item = ($d["items"] ?? [])[0] ?? [];
    $who = $argv[1];
    if (($item["glossary"] ?? []) !== ["Panokseon" => "Паноксон"]) {
        fwrite(STDERR, "[$who] у законі опинилось не те: ".json_encode($item["glossary"] ?? null, 448)."\n"); exit(1);
    }
    if (($item["glossary_hint"] ?? []) !== ["Timing" => "Час"]) {
        fwrite(STDERR, "[$who] машинна назва не пішла в підказку: ".json_encode($item["glossary_hint"] ?? null, 448)."\n"); exit(1);
    }
    ' "$payload" || fail "payload $payload не розділяє глосарій за походженням"
done

# 3. Спільний блок `terms` несе походження · без нього поділ на рівні пачки німий.
grep -Fq '"ukrainian_layer", "policy"' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'worker-payload не передає ukrainian_layer у спільні терміни'

# 4. Промпти трактують блоки РІЗНО, і це саме те, чого бракувало.
grep -Fq 'Невживання такої назви' "$ROOT/roles/translation-qa.md" \
    || fail 'промпт QA не знімає вердикт за невживання машинної назви'
grep -Fq 'Невживання назви з `glossary_hint` теж дає `PASS`' "$ROOT/roles/translation-qa.md" \
    || fail 'промпт QA не називає PASS для машинної назви прямо'
grep -Fq 'glossary_hint' "$ROOT/roles/translation-worker.md" \
    || fail 'промпт воркера не знає про машинну підказку'
grep -Fq 'glossary_hint' "$ROOT/roles/translation-repair.md" \
    || fail 'промпт ремонтника не знає про машинну підказку'
grep -Fq 'підставою для `moderation` НЕ є' "$ROOT/roles/translation-judge.md" \
    || fail 'суддя досі може віддати рядок людині за машинну назву'

# 5. `issue` · одне речення без міркувань. Правило мусить бути в промпті ДОСЛІВНО,
#    бо саме його відсутність дала абзаци суперечки із самим собою.
grep -Fq 'ОДНЕ коротке речення' "$ROOT/roles/translation-qa.md" \
    || fail 'промпт QA не обмежує issue одним реченням'
for word in 'хоча' 'однак' 'це означає'; do
    grep -Fq "$word" "$ROOT/roles/translation-qa.md" \
        || fail "промпт QA не забороняє слово-маркер міркування «$word»"
done

echo 'glossary provenance: OK · закон і машинний стандарт розділені в коді, payload і промптах.'
