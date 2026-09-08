#!/usr/bin/env bash
# Один короткий прохід по НАЗВАХ перед записом (пункт C плану QA_SCOPE_AND_ROLES).
#
# Фінальна валідація відхиляє рядок кодом `glossary_violation` і каже точно,
# чого бракує (`details.glossary[].expected`). Досі такий рядок ішов у
# модерацію, де сервер відмовляв тим самим правилом (D56), і повертався в
# наступну пачку (D58). Тут рушій дає repair один прохід із єдиним наказом
# «ужий «X» для «Y»» і повертає пачку до запису; другого проходу не буває.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"; mkdir -p "$STATE"

# 1. Машина станів знає прохід і дорогу назад.
php -r 'require $argv[1];
    use Bdo\Translate\Pipeline\StateMachine;
    StateMachine::assertTransition("ready_to_commit", "names_pass");
    StateMachine::assertTransition("names_pass", "ready_to_commit");
    StateMachine::assertTransition("retry_scheduled", "names_pass");
    try { StateMachine::assertTransition("committing", "names_pass"); fwrite(STDERR, "committing -> names_pass дозволено\n"); exit(1); } catch (RuntimeException) {}' \
    "$ROOT/lib/autoload.php" || fail 'машина станів не знає проходу по назвах або дозволяє його з committing'

H1="$(printf 1 | shasum -a 256 | awk '{print $1}')"
H2="$(printf 2 | shasum -a 256 | awk '{print $1}')"
php -r 'file_put_contents($argv[1], json_encode(["data" => ["rows" => [
    ["identity_hash" => $argv[2], "source_hash" => hash("sha256", "Move"), "source_text" => "Move",
     // Класифікація є в кожному живому рядку, тому вона є й у фікстурі: без неї
     // перевірка «прохід знає, що перед ним» доводила б лише порожнечу.
     "classification" => ["domain" => "ui", "semantic_type" => "label"],
     "glossary" => ["terms" => [["canonical_source" => "Move", "ukrainian" => "Переміщення", "ukrainian_layer" => "manual", "severity" => "mandatory"]]]],
    ["identity_hash" => $argv[3], "source_hash" => hash("sha256", "Iron Sword"), "source_text" => "Iron Sword"],
]]], JSON_THROW_ON_ERROR));' "$STATE/rows.json" "$H1" "$H2"

# Відповідь validate: перший рядок без затвердженої назви, другий чистий.
php -r 'file_put_contents($argv[1], json_encode(["success" => true, "data" => ["results" => [
    ["index" => 0, "identity_hash" => $argv[2], "status" => "rejected", "code" => "glossary_violation",
     "message" => "Текст розходиться з глосарієм: не видно узгодженої назви «Переміщення».",
     "details" => ["glossary" => [["termId" => 79353, "canonical" => "Move", "expected" => "Переміщення", "issue" => "missing_translation", "severity" => "mandatory"]]]],
    ["index" => 1, "identity_hash" => $argv[3], "status" => "ok"],
]], "meta" => ["items" => 2, "rejected" => 1]], JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE));' "$STATE/validate.json" "$H1" "$H2"

# 2. Сам payload: лише рядок із наказом, наказ · єдиний дефект.
php -r 'file_put_contents($argv[1], json_encode([["identity_hash" => $argv[2], "text" => "Рух"], ["identity_hash" => $argv[3], "text" => "Залізний меч"]], JSON_THROW_ON_ERROR));' \
    "$STATE/final-candidate.json" "$H1" "$H2"
payload="$(bash "$ROOT/cli/prepare/names-payload.sh" "$STATE/rows.json" "$STATE/final-candidate.json" "$STATE/validate.json" 2>/dev/null)"
test "$(jq '.items | length' <<<"$payload")" = 1 || fail "у payload мусив бути 1 рядок: $payload"
jq -e --arg h "$H1" '.items[0].identity_hash == $h and .items[0].current == "Рух" and .items[0].orders == ["ужий «Переміщення» для «Move»"]' <<<"$payload" >/dev/null \
    || fail "payload не несе єдиного наказу: $payload"

# ПРОХІД МУСИТЬ ЛИШАТИСЬ ВУЗЬКИМ · перевіряється на ДАНИХ, а не на коді.
#
# Заміряно 2026-09-05 на трьох живих пачках: вхід 5 200 токенів, вихід 2 251,
# 53 секунди · на задачу, весь зміст якої в рядку «ужий «X» для «Y»». Причина
# була в повному глосарії рядка, який лежав у payload усупереч комментарю
# самого файла. Назва, потрібна для виконання, стоїть у наказі; решту захищає
# фінальна валідація ПІСЛЯ проходу.
jq -e '[.items[] | has("glossary")] | any | not' <<<"$payload" >/dev/null \
    || fail "у прохід по назвах повернувся глосарій рядка: $payload"
jq -e '.items[0] | has("semantic_type") and has("domain")' <<<"$payload" >/dev/null \
    || fail "прохід не знає, що саме перед ним · промпт ці поля називає (D79): $payload"
# Англійського джерела теж бути не має: воно дублює текст і відкриває шлях до
# «перекладу наново», якого ця роль робити НЕ повинна.
jq -e '[.items[] | has("source_text")] | any | not' <<<"$payload" >/dev/null \
    || fail "у прохід по назвах повернулось англійське джерело: $payload"

# Довгі хеші до моделі НЕ доходять: на межі виклику вони стають `r1…rN` (D59).
# Форма payload проходу змінилась (конверт `items` замість голого списку), тому
# підміна перевіряється саме на ній · інакше вона мовчки перестала б діяти й
# модель знову передруковувала б по 64 символи на рядок.
php -r '
require $argv[1];
use Bdo\Translate\Model\RowAlias;
$payload = json_decode($argv[2], true);
$alias = RowAlias::fromPayload($payload);
if ($alias->isEmpty()) { fwrite(STDERR, "підміна хешів не впізнала payload проходу\n"); exit(1); }
$out = json_encode($alias->aliasPayload($payload), JSON_UNESCAPED_UNICODE);
if (preg_match("/[0-9a-f]{64}/", $out) === 1) {
    fwrite(STDERR, "у payload для моделі лишився повний хеш: $out\n"); exit(1);
}
if (! str_contains($out, "\"id\":\"r1\"")) {
    fwrite(STDERR, "короткого ключа r1 немає: $out\n"); exit(1);
}' "$ROOT/lib/autoload.php" "$payload" || fail 'модель бачитиме довгі хеші у проході по назвах (D59)'

# 2б. МЕЖА: наказ віддається лише для назви, затвердженої ЛЮДИНОЮ.
#
#     Перевірено на PROD 2026-09-04: 131 391 запис глосарія із 136 022 має
#     `ukrainian_layer: machine` при `severity: mandatory`. Рядок `ad739b68…`
#     («…spotted on the move») отримав mandatory-вимогу «Переміщення» для
#     англійського `move` у прозі саме з машинної назви. Змусити модель
#     підставити її дослівно означає закріпити машинну здогадку як стандарт.
for layer in machine ''; do
    php -r '$d=json_decode(file_get_contents($argv[1]),true);
        $t=["canonical_source"=>"Move","ukrainian"=>"Переміщення","severity"=>"mandatory"];
        if ($argv[2] !== "") $t["ukrainian_layer"]=$argv[2];
        $d["data"]["rows"][0]["glossary"]["terms"]=[$t];
        file_put_contents($argv[1],json_encode($d,JSON_THROW_ON_ERROR|JSON_UNESCAPED_UNICODE));' "$STATE/rows.json" "$layer"
    out="$(bash "$ROOT/cli/prepare/names-payload.sh" "$STATE/rows.json" "$STATE/final-candidate.json" "$STATE/validate.json" 2>"$TMP/err")"
    test "$(jq '.items | length' <<<"$out")" = 0 || fail "походження назви «${layer:-невідоме}» мусило пропустити наказ: $out"
    grep -q 'пропущено 1' "$TMP/err" || fail "пропуск не названо вголос (${layer:-невідоме}): $(cat "$TMP/err")"
done
# Людська назва наказ дає · інакше межа перетворилась би на глухий вимикач.
php -r '$d=json_decode(file_get_contents($argv[1]),true);
    $d["data"]["rows"][0]["glossary"]["terms"]=[["canonical_source"=>"Move","ukrainian"=>"Переміщення","ukrainian_layer"=>"manual","severity"=>"mandatory"]];
    file_put_contents($argv[1],json_encode($d,JSON_THROW_ON_ERROR|JSON_UNESCAPED_UNICODE));' "$STATE/rows.json"
test "$(bash "$ROOT/cli/prepare/names-payload.sh" "$STATE/rows.json" "$STATE/final-candidate.json" "$STATE/validate.json" 2>/dev/null | jq '.items | length')" = 1 || fail 'людська назва не дала наказу'

# 3. Рушій: із ready_to_commit пачка іде в names_pass до repair, і лише раз.
cat > "$TMP/.env" <<ENV
BDO_ENV=DEV
BDO_API_BASE_DEV=http://127.0.0.1:1
BDO_API_KEY_DEV=test
ENV
BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-new.sh" "$STATE/rows.json" >/dev/null
B="$(BDO_STATE_DIR="$STATE" bash "$ROOT/cli/batch/batch-dir.sh")"
php -r '$m=json_decode(file_get_contents($argv[1]),true);$m["state"]="ready_to_commit";$m["mode"]="patch";$m["channel"]="machine";
    file_put_contents($argv[1],json_encode($m,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));' "$B/manifest.json"
cp "$STATE/final-candidate.json" "$B/final-candidate.json"
php -r 'file_put_contents($argv[1], json_encode([
    ["identity_hash" => $argv[2], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""],
    ["identity_hash" => $argv[3], "status" => "PASS", "severity" => "none", "issue" => "", "fix" => ""]], JSON_THROW_ON_ERROR));' \
    "$B/final-verdicts.json" "$H1" "$H2"
drive() { TRANSLATE_ENV_FILE="$TMP/.env" BDO_PIPELINE_OFFLINE=1 BDO_AUTO_CLEAN=0 BDO_FINAL_VALIDATE_STUB="$STATE/validate.json" \
    BDO_STATE_DIR="$STATE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null | tail -1; }

out="$(drive)"
# Прохід по назвах виконує ОКРЕМА роль (рішення 2026-09-05): у неї свій вузький
# промпт «підстав назву», тоді як `translation-repair` вільно переписує текст.
# Одна роль на дві різні задачі й дала роздутий payload і дві однакові картки
# на екрані.
jq -e '.state == "names_pass" and .next.kind == "child" and .next.role == "translation-names"' <<<"$out" >/dev/null \
    || fail "пачка не пішла в прохід по назвах окремою роллю: $out"
test "$(jq '.items | length' "$B/names-payload.json")" = 1 || fail 'payload проходу має не 1 рядок'
grep -q '"child_dispatch:translation-names:1"' "$B/journal.jsonl" || fail 'журнал не бачить проходу по назвах'
# Схема під ПІДМНОЖИНУ: один рядок, а не вся пачка.
test "$(jq '.properties.items.items.properties.identity_hash.enum | length' "$STATE/current-response-schema.json")" = 1 \
    || fail 'схема repair побудована не під підмножину проходу'

# 4. Відповідь repair зливається у фінальний текст, пачка повертається до запису.
php -r 'file_put_contents($argv[1], json_encode([["identity_hash" => $argv[2], "text" => "Переміщення"]], JSON_THROW_ON_ERROR));' "$B/names-fixes.json" "$H1"
out="$(drive)"
jq -e '.state == "ready_to_commit" and .next.reason == "names_fixed"' <<<"$out" >/dev/null \
    || fail "після відповіді repair пачка не повернулась до запису: $out"
jq -e --arg h "$H1" '.[] | select(.identity_hash == $h) | .text == "Переміщення"' "$B/final-candidate.json" >/dev/null \
    || fail 'виправлена назва не потрапила у фінальний кандидат'
jq -e --arg h "$H2" '.[] | select(.identity_hash == $h) | .text == "Залізний меч"' "$B/final-candidate.json" >/dev/null \
    || fail 'чистий рядок зіпсовано злиттям'
jq -e '.steps.names.artifact == "final-candidate.json"' "$B/manifest.json" >/dev/null || fail 'manifest не записав крок names'

# 5. Другого проходу не буває: та сама відмова validate більше не веде в names_pass.
#    Пачка йде на запис, а запис у 127.0.0.1:1 законно падає · нас цікавить лише
#    те, що repair не викликано вдруге. Голе `x="$(cmd)"` під set -e тут
#    зʼїло б цю відмову мовчки (§12), тому код виходу приймається явно.
out="$(drive)" || true
jq -e '.state != "names_pass" and (.next.role // "") != "translation-repair"' <<<"$out" >/dev/null \
    || fail "прохід по назвах повторився: $out"

# 6. Вимикач і межа: без validate або з BDO_NAMES_PASS=off проходу немає · це у коді, не в промпті.
grep -Fq 'BDO_NAMES_PASS:-on' "$ROOT/cli/run/run-drive.sh" || fail 'немає вимикача проходу по назвах'
grep -Fq 'names-pass.done' "$ROOT/cli/run/run-drive.sh" || fail 'немає межі «один прохід на пачку»'
# Репарувальник мусить знати, що означає наказ · це виміряний дефект промпта, а не смак.
grep -Fq 'Дефект виду «ужий «X» для «Y»» означає' "$ROOT/roles/translation-repair.md" \
    || fail 'промпт repair не пояснює наказ «ужий»'
# Межа стоїть у КОДІ, а не в промпті: machine-вимога не стає наказом.
php -r '$d=json_decode(file_get_contents($argv[1]),true);$d["data"]["rows"][0]["glossary"]["terms"][0]["ukrainian_layer"]="machine";file_put_contents($argv[1],json_encode($d,JSON_UNESCAPED_UNICODE));' "$STATE/rows.json"
machine_payload="$(bash "$ROOT/cli/prepare/names-payload.sh" "$STATE/rows.json" "$STATE/final-candidate.json" "$STATE/validate.json" 2>/dev/null)" \
    || fail 'прохід по назвах упав на машинному походженні'
test "$(jq '.items | length' <<<"$machine_payload")" = 0 \
    || fail 'машинна назва потрапила в наказ проходу по назвах'

echo 'names pass: OK · один прохід по назвах перед записом, без повтору.'
