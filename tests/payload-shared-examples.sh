#!/usr/bin/env bash
# Приклади живуть у СПІЛЬНОМУ блоці payload, а не копією в кожному рядку.
#
# Клас дефекту · вартість, яку ніхто не бачив. Підставлений payload не зникає
# після виклику: OpenCode зберігає його в частині повідомлення, і кожен
# наступний крок диригента пересилає той самий текст заново. Заміряно
# 2026-08-28 по базі сесій: 24 частини по 50+ КБ важили 2 160 245 байтів · 69%
# усього транскрипту диригента, а рахунок сесії дійшов до $1,22.
#
# У самому payload 67% ваги давали `examples`, і з 57 прикладів живої пачки
# унікальних було лише 13 · решта дослівні повтори, бо рядки пачки належать до
# однієї родини предметів. Спільний блок прибирає повтори, не втрачаючи ЖОДНОГО
# прикладу: на живому payload це дало 85 084 -> 49 572 байти (-42%).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

H1="$(printf '%064d' 1)"; H2="$(printf '%064d' 2)"; H3="$(printf '%064d' 3)"
mkdir -p "$TMP/state/batches/b" "$TMP/state"
printf 'b\n' > "$TMP/state/current-batch"
cat > "$TMP/rows.json" <<JSON
{"data":{"rows":[
 {"identity_hash":"$H1","source_hash":"a","source_text":"Iron Sword"},
 {"identity_hash":"$H2","source_hash":"b","source_text":"Iron Shield"},
 {"identity_hash":"$H3","source_hash":"c","source_text":"Iron Helmet"}
]}}
JSON
# Той самий приклад для трьох рядків · рівно те, що дає граф згадок на практиці.
cat > "$TMP/state/batches/b/context.json" <<JSON
{"$H1":[{"en":"Iron Ore","ua":"Залізна руда"}],
 "$H2":[{"en":"Iron Ore","ua":"Залізна руда"}],
 "$H3":[{"en":"Iron Ore","ua":"Залізна руда"},{"en":"Steel Ore","ua":"Сталева руда"}]}
JSON

# shellcheck disable=SC2120  # прапорці передаються не в кожному виклику
build() { BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/worker-payload.sh" "$TMP/rows.json" "$@" 2>"$TMP/err.txt"; }

out="$(build)" || fail "worker-payload впав: $(cat "$TMP/err.txt")"
printf '%s' "$out" | jq -e 'has("examples") and has("items")' >/dev/null \
    || fail 'payload не має спільного блоку examples і масиву items'
printf '%s' "$out" | jq -e '.examples | length == 2' >/dev/null \
    || fail "унікальних прикладів мусить бути 2, маємо: $(printf '%s' "$out" | jq -c '.examples|length')"
printf '%s' "$out" | jq -e '[.items[] | has("examples")] | any | not' >/dev/null \
    || fail 'приклади лишились дубльованими всередині рядків'
printf '%s' "$out" | jq -e '.items | length == 3' >/dev/null || fail 'загубились рядки'
# Жоден приклад не втрачено: обидва унікальні на місці.
printf '%s' "$out" | jq -e '[.examples[].en] | sort == ["Iron Ore","Steel Ore"]' >/dev/null \
    || fail 'дедуплікація загубила приклад'

# Бюджет на приклади: відбір іде від КОРОТШИХ, щоб за ті самі байти модель
# бачила більше різних прикладів. Заміряно на живій пачці: приклади · 59%
# payload, і два найдовші важили 52% усіх прикладів.
cat > "$TMP/state/batches/b/context.json" <<JSON
{"$H1":[{"en":"short one","ua":"короткий"},{"en":"$(printf 'x%.0s' {1..900})","ua":"довгий"}],
 "$H2":[{"en":"short two","ua":"другий"}]}
JSON
out="$(BDO_EXAMPLES_BUDGET=200 build)" || fail 'payload із бюджетом прикладів не зібрався'
printf '%s' "$out" | jq -e '[.examples[].ua] | index("довгий") == null' >/dev/null \
    || fail 'найдовший приклад не відкинуто попри бюджет'
printf '%s' "$out" | jq -e '.examples | length >= 1' >/dev/null || fail 'бюджет викинув геть усе'
grep -q 'відкинуто .* найдовших' "$TMP/err.txt" || fail 'про відкинуті приклади не сказано у звіті'
# Бюджет 0 вимикає відбір · власник може повернути стару поведінку одним рядком.
out="$(BDO_EXAMPLES_BUDGET=0 build)" || fail 'вимкнений бюджет ламає payload'
printf '%s' "$out" | jq -e '[.examples[].ua] | index("довгий") != null' >/dev/null \
    || fail 'вимкнений бюджет усе одно ріже приклади'
# Повертаємо початковий контекст для решти перевірок.
cat > "$TMP/state/batches/b/context.json" <<JSON
{"$H1":[{"en":"Iron Ore","ua":"Залізна руда"}],
 "$H2":[{"en":"Iron Ore","ua":"Залізна руда"}],
 "$H3":[{"en":"Iron Ore","ua":"Залізна руда"},{"en":"Steel Ore","ua":"Сталева руда"}]}
JSON

# Стеля існує й про відкинуте пишеться ПРЯМО: мовчазне обрізання читалось би як
# «прикладів більше не було».
out="$(BDO_SHARED_EXAMPLES=1 build)" || fail 'payload зі стелею 1 не зібрався'
printf '%s' "$out" | jq -e '.examples | length == 1' >/dev/null || fail 'стеля прикладів не діє'
grep -q 'відкинуто понад стелю 1' "$TMP/err.txt" || fail 'відкинутий приклад не названо у звіті'

# QA бачить payload тієї самої форми, інакше промпти двох ролей розійдуться.
printf '[{"identity_hash":"%s","text":"Залізний меч"},{"identity_hash":"%s","text":"Залізний щит"},{"identity_hash":"%s","text":"Залізний шолом"}]' \
    "$H1" "$H2" "$H3" > "$TMP/candidate.json"
qa="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/qa-payload.sh" "$TMP/rows.json" "$TMP/candidate.json" 2>"$TMP/qa-err.txt")" \
    || fail "qa-payload впав: $(cat "$TMP/qa-err.txt")"
printf '%s' "$qa" | jq -e 'has("examples") and has("items")' >/dev/null \
    || fail 'qa-payload лишився зі старою формою'

# Терміни пачки · теж спільний блок. Береться з одного пачкового запиту
# `POST /rows/context` (сервер 3.7.5) замість запиту на кожен рядок.
cat > "$TMP/state/batches/b/terms.json" <<'JSON'
[{"canonical_source":"Iron Ore","ukrainian":"Залізна руда","policy":"profile_default","severity":"mandatory","entity_type":"item"},
 {"canonical_source":"Steel Ore","ambiguous":true}]
JSON
out="$(build)" || fail 'payload із термінами не зібрався'
printf '%s' "$out" | jq -e '.terms | length == 2' >/dev/null || fail 'терміни пачки не дійшли в payload'
printf '%s' "$out" | jq -e '.terms[0].severity == "mandatory"' >/dev/null || fail 'сила правила терміна загубилась'
printf '%s' "$out" | jq -e '.terms[1].ambiguous == true' >/dev/null || fail 'ознака неоднозначності загубилась'
# `definition` сьогодні порожній у всіх термінів, але тільки-но глосарій його
# отримає · він мусить доїхати без жодної зміни коду.
cat > "$TMP/state/batches/b/terms.json" <<'JSON'
[{"canonical_source":"Iron Ore","definition":"Руда, з якої плавлять залізо.","wiki_url":"https://example/ore"}]
JSON
out="$(build)" || fail 'payload з описом терміна не зібрався'
printf '%s' "$out" | jq -e '.terms[0].definition and .terms[0].wiki_url' >/dev/null \
    || fail 'опис із вікі не доходить до моделі'
qa2="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/qa-payload.sh" "$TMP/rows.json" "$TMP/candidate.json" 2>/dev/null)"
printf '%s' "$qa2" | jq -e '.terms[0].definition' >/dev/null \
    || fail 'QA судить без тих самих термінів, що бачив воркер'

# Недоступний контекст ЗУПИНЯЄ крок, а не робить «слабший payload».
#
# 2026-08-28 на пачці 20260828_100456 цей запит мовчки не вдався, затверджені
# терміни глосарію до моделі не доїхали, і 11 із 24 рядків модерації · це один
# і той самий `Cheongsa Island` у трьох варіантах, хоча відповідник «Острів
# Ліхтарів» був затверджений і повертався API.
cat > "$TMP/http-fail.sh" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
chmod +x "$TMP/http-fail.sh"
: > "$TMP/state/batches/b/context.json"
set +e
BDO_CONTEXT_HTTP="$TMP/http-fail.sh" BDO_API_BASE=https://example.invalid BDO_API_KEY=x \
    BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/worker-payload.sh" "$TMP/rows.json" \
    >"$TMP/broken.json" 2>"$TMP/broken-err.txt"
code=$?
set -e
test "$code" -ne 0 || fail 'payload зібрався без контексту з термінами'
grep -q 'Контекст пачки недоступний' "$TMP/broken-err.txt" || fail 'причина зупинки не названа'
rm -f "$TMP/broken.json" "$TMP/state/batches/b/context.json"
# Далі тести знову працюють зі зібраним контекстом.
cp "$TMP/context-backup.json" "$TMP/state/batches/b/context.json" 2>/dev/null || true

# Рушій мусить перетворити цю зупинку на повтор, а не впасти з порожнім файлом.
# Живий прогін тут не відтворити (крок онлайновий), тому перевіряється звʼязок:
# код виходу враховано, недобудований payload прибрано, причина названа.
grep -Fq 'if ! "$SCRIPT_DIR/cli/prepare/worker-payload.sh"' "$ROOT/cli/run/run-drive.sh" \
    || fail 'run drive ігнорує код виходу worker-payload'
grep -Fq 'context_unavailable' "$ROOT/cli/run/run-drive.sh" \
    || fail 'run drive не називає недоступний контекст окремою причиною'
grep -Fq 'rm -f "$B/worker-payload.json.new"' "$ROOT/cli/run/run-drive.sh" \
    || fail 'недобудований payload лишається на диску'

# Приклад, що суперечить затвердженому терміну, до моделі не їде.
#
# Рішення власника 2026-08-28. Приклади · це попередні переклади, серед яких
# лишились варіанти, зроблені ДО затвердження терміна. Модель бачила два
# джерела одразу і хоч що вибрала б, одне з двох порушувала: на пачці
# 20260828_131740 QA на цьому сперечалась із глосарієм у двох рядках.
php -r '
require $argv[1];
use Bdo\Translate\Quality\GlossaryExamples as G;
$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };
$terms = [
    ["canonical_source" => "Cheongsa Island", "ukrainian" => "Острів Ліхтарів"],
    ["canonical_source" => "Her", "ukrainian" => "Вона"],
];
// Суперечність: термін є в оригіналі, затвердженого відповідника в перекладі немає.
if (G::contradicts("A shop on Cheongsa Island", "Крамниця на Острові Чхонса", $terms) !== "Cheongsa Island") {
    $fail("суперечливий приклад не помічено");
}
// Відмінювання суперечністю не є.
if (G::contradicts("A shop on Cheongsa Island", "Крамниця на Острові Ліхтарів", $terms) !== null) {
    $fail("відмінок затвердженого терміна визнано суперечністю");
}
// Терміна в оригіналі немає · приклад не чіпаємо.
if (G::contradicts("A simple sword", "Простий меч", $terms) !== null) {
    $fail("приклад без терміна відкинуто");
}
// Однослівні назви поза фільтром: у глосарії поруч живуть Her -> Вона,
// Week -> Місяць, GO -> ВПЕ, і вимагати їх у кожному прикладі означає стерти
// здорові дані. Пропустити суперечність дешевше, ніж викинути правильний приклад.
if (G::contradicts("Her husband waits", "Її чоловік чекає", $terms) !== null) {
    $fail("однослівний термін почав викидати приклади");
}
$filtered = G::filter([
    "h1" => [["en" => "A shop on Cheongsa Island", "ua" => "Крамниця на Острові Чхонса"]],
    "h2" => [["en" => "A shop on Cheongsa Island", "ua" => "Крамниця на Острові Ліхтарів"]],
], $terms);
if ($filtered["dropped"] !== 1) $fail("відкинуто не один приклад: ".$filtered["dropped"]);
if (isset($filtered["examples"]["h1"])) $fail("суперечливий приклад лишився в payload");
if (! isset($filtered["examples"]["h2"])) $fail("здоровий приклад зник із payload");
if ($filtered["terms"] !== ["Cheongsa Island"]) $fail("причина відкидання не названа");
' "$ROOT/lib/autoload.php" || fail 'фільтр прикладів за глосарієм не тримає контракт'

grep -Fq 'GlossaryExamples::filter' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'payload воркера не фільтрує приклади за глосарієм'
grep -Fq 'відкинуто %d, що суперечать затвердженим термінам' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'відкидання прикладів мовчазне'

# Підозрілий запис глосарію не подається моделі як закон.
#
# Помилковий запис коштує дорожче за відсутній: він псує КОЖЕН рядок, де
# трапився термін. 2026-08-28 у робочій вибірці знайшлись `Week -> Місяць`,
# `GO -> ВПЕ` і `Her -> Вона`; глосарій ми не змінюємо, тому позначені записи
# просто не їдуть у payload, поки їх не перевірить людина.
php -r '
require $argv[1];
use Bdo\Translate\Quality\GlossarySuspects;
$fail = static function (string $m): void { fwrite(STDERR, "FAIL: $m\n"); exit(1); };
$found = GlossarySuspects::find([
    ["canonical_source" => "Week", "ukrainian" => "Місяць", "seen" => 2],
    ["canonical_source" => "Day", "ukrainian" => "День", "seen" => 1],
    // Займенник МОЖЕ мати затверджений відповідник: власник глосарію перевірив
    // `Her -> Вона` окремо й підтвердив. Наше колишнє правило було хибним.
    ["canonical_source" => "Her", "ukrainian" => "Вона", "seen" => 1],
    ["canonical_source" => "Bilson", "ukrainian" => "Kiraki", "seen" => 0],
    ["canonical_source" => "<PAOldColor> Value Pack", "ukrainian" => "<PAOldColor>Value Pack", "seen" => 0],
    ["canonical_source" => "We are Family", "ukrainian" => "We are family", "seen" => 0],
    ["canonical_source" => "AP", "ukrainian" => "AP", "seen" => 9],
    ["canonical_source" => "Bilson ", "ukrainian" => "Bilson", "policy" => "keep_source", "seen" => 0],
    ["canonical_source" => "Cheongsa Island", "ukrainian" => "Острів Ліхтарів", "seen" => 6],
    ["canonical_source" => "Sunset Coral Essence", "ukrainian" => "Есенція корала заходу сонця", "seen" => 1],
]);
$byName = [];
foreach ($found as $s) $byName[$s["canonical_source"]] = $s["reason"];
$expected = [
    "Week" => "time_unit_mismatch",
    "Bilson" => "latin_target_mismatch",
    "<PAOldColor> Value Pack" => "markup_or_space_only",
    "We are Family" => "case_only",
];
foreach ($expected as $name => $reason) {
    if (($byName[$name] ?? null) !== $reason) $fail("$name не позначено як $reason");
}
// Здорові записи не чіпаємо: хибне звинувачення затвердженого терміна гірше за
// пропущене, бо забирає в моделі правильний закон. `AP -> AP` і `keep_source` ·
// свідоме «не перекладати», а `Her -> Вона` перевірений людиною.
foreach (["Day", "AP", "Her", "Bilson ", "Cheongsa Island", "Sunset Coral Essence"] as $name) {
    if (isset($byName[$name])) $fail("здоровий термін $name потрапив у підозрілі");
}
// Потокова перевірка мусить давати ТОЙ САМИЙ вирок: повний каталог у памʼять не
// влазить, і саме `perTerm` бачить 136 тисяч записів.
foreach ($expected as $name => $reason) {
    $one = GlossarySuspects::perTerm(["canonical_source" => $name, "ukrainian" => (string) array_column(
        array_filter($found, static fn (array $f): bool => $f["canonical_source"] === $name), "ukrainian")[0]]);
    if (($one["reason"] ?? null) !== $reason) $fail("потокова перевірка розійшлась із пакетною на $name");
}
' "$ROOT/lib/autoload.php" || fail 'детектор підозрілих термінів не тримає контракт'

grep -Fq 'Терміни під підозрою пропущено' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'payload мовчки подає підозрілі терміни як закон'
grep -Fq 'glossary-suspects.json' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'payload не читає позначки підозрілих термінів'
grep -Fq 'empty($mark["withhold"])' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'payload прибирає терміни, не питаючи про позначку withhold'

# Один пачковий запит замість запиту на кожен рядок.
grep -Fq '/rows/context' "$ROOT/cli/prepare/worker-payload.sh" || fail 'контекст береться не пачковим запитом'
grep -Fq 'max_context_rows' "$ROOT/cli/prepare/worker-payload.sh" || fail 'ліміт пачки контексту зашитий у клієнт замість /me'

# Обидва промпти мусять знати нову форму, інакше слабка модель шукатиме масив.
for role in worker qa; do
    grep -Fq '`items` · масив рядків' "$ROOT/roles/translation-$role.md" \
        || fail "child $role не знає, що payload має ключі examples та items"
    grep -Fq '`terms` · терміни цієї пачки' "$ROOT/roles/translation-$role.md" \
        || fail "child $role не знає блоку terms"
done

# Поняття гри: у payload ідуть ЛИШЕ ті, що є в тексті пачки, і лише короткий
# `gist`. Повний `definition` (до 4000 символів) свідомо не кладеться · він для
# людини, а обрізати його не можна: модель прочитає обрізане як повне.
cat > "$TMP/state/game-concepts.json" <<'JSON'
{"fetched_at":"2026-08-28T00:00:00+00:00","concepts":[
 {"term":"AP","ua":"AP","gist":"Сила атаки.","case_sensitive":true},
 {"term":"MAP","ua":"Monster AP","gist":"Сила атаки по монстрах.","case_sensitive":true},
 {"term":"Set Effect","ua":"Ефект комплекту","gist":"Бонус за повний набір."},
 {"term":"Node","ua":"Вузол","gist":"Точка на карті світу."}
]}
JSON
cat > "$TMP/concept-rows.json" <<JSON
{"data":{"rows":[
 {"identity_hash":"$H1","source_hash":"a","source_text":"Increases AP and Set Effect applies."},
 {"identity_hash":"$H2","source_hash":"b","source_text":"Open the map and walk."}
]}}
JSON
out="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/prepare/worker-payload.sh" "$TMP/concept-rows.json" --no-context 2>/dev/null)" \
    || fail 'payload із поняттями не зібрався'
printf '%s' "$out" | jq -e '[.concepts[].term] | sort == ["AP","Set Effect"]' >/dev/null \
    || fail "у payload не ті поняття: $(printf '%s' "$out" | jq -c '[.concepts[].term]')"
# Регістр вирішує: `map` з малої НЕ є поняттям `MAP` (Monster AP).
printf '%s' "$out" | jq -e '[.concepts[].term] | index("MAP") == null' >/dev/null \
    || fail 'поняття MAP зіставлено зі словом map з малої літери'
# Поняття, якого в тексті немає, у payload не потрапляє.
printf '%s' "$out" | jq -e '[.concepts[].term] | index("Node") == null' >/dev/null \
    || fail 'у payload потрапило поняття, якого немає в тексті пачки'
# Довгий опис для людини в payload не їде.
printf '%s' "$out" | jq -e '[.concepts[] | has("definition")] | any | not' >/dev/null \
    || fail 'повний definition потрапив у payload'
# Обидва промпти мусять пояснювати блок і його СИЛУ: підказка, не закон.
for role in worker qa; do
    grep -Fq '`concepts` · поняття гри' "$ROOT/roles/translation-$role.md" \
        || fail "child $role не знає блоку concepts"
    grep -Fq 'СИЛЬНОЮ ПІДКАЗКОЮ, а не затвердженим відповідником' "$ROOT/roles/translation-$role.md" \
        || fail "child $role вважає поняття затвердженим відповідником"
done
# Перелік тягнеться ОДИН раз на прогін, а не на кожну пачку.
grep -Fq 'glossary-concepts.sh' "$ROOT/cli/run/run-drive.sh" || fail 'рушій не оновлює перелік понять'
grep -Fq 'BDO_CONCEPTS_TTL_HOURS' "$ROOT/cli/api/glossary-concepts.sh" || fail 'перелік понять не кешується'

# Черга термінів без опису: рахуємо, але НІЧОГО не надсилаємо. Рішення власника
# 2026-08-28 · часу на довгу модерацію немає, глосарій наповнений, тому новий
# термін не пропонуємо взагалі, а опис до наявного лише тоді, коли впевненість
# у релевантності саме для BDO вища за 50%.
# Три стани, і плутати їх означає зіпсувати чужі дані: опис є · опису немає ·
# сервер про нього не сказав. Останній МОВЧКИ пропускається, а не вважається
# порожнім, інакше пропозиція піде поверх написаного людиною.
cat > "$TMP/queue-terms.json" <<'JSON'
[{"canonical_source":"Tears of the Falling Moon","ukrainian":"Сльози Старого Місяця","entity_type":"item","has_definition":false},
 {"canonical_source":"Set Effect","ukrainian":"Ефект комплекту","definition":"опис уже є","has_definition":true},
 {"canonical_source":"Ancient Relic","ukrainian":"Стародавня реліквія"},
 {"canonical_source":"Unknown Thing"}]
JSON
cat > "$TMP/queue-rows.json" <<JSON
{"data":{"rows":[{"identity_hash":"$H1","source_hash":"a","source_text":"Set Effect of Tears of the Falling Moon is active."}]}}
JSON
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/api/term-notes-queue.sh" "$TMP/queue-terms.json" "$TMP/queue-rows.json" 2>/dev/null \
    || fail 'черга термінів без опису не збирається'
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/api/term-notes-queue.sh" "$TMP/queue-terms.json" "$TMP/queue-rows.json" 2>/dev/null || true
jq -e '[.terms[].canonical_source] == ["Tears of the Falling Moon"]' "$TMP/state/term-notes-queue.json" >/dev/null \
    || fail "у черзі не ті терміни: $(jq -c '[.terms[].canonical_source]' "$TMP/state/term-notes-queue.json")"
jq -e '.terms[0].seen == 2' "$TMP/state/term-notes-queue.json" >/dev/null \
    || fail 'частота терміна не накопичується між пачками'
jq -e '.terms[0].samples | length >= 1' "$TMP/state/term-notes-queue.json" >/dev/null \
    || fail 'у черзі немає живого рядка, з якого писати опис'
# Термін, про опис якого сервер не сказав, у чергу НЕ потрапляє й про це видно.
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/api/term-notes-queue.sh" "$TMP/queue-terms.json" "$TMP/queue-rows.json" 2>"$TMP/queue-err.txt" || true
grep -q 'не сказав, чи є в них опис' "$TMP/queue-err.txt" \
    || fail 'невідомий стан опису пропущено мовчки'
jq -e '[.terms[].canonical_source] | index("Ancient Relic") == null' "$TMP/state/term-notes-queue.json" >/dev/null \
    || fail 'термін з невідомим станом опису потрапив у чергу · так псуються чужі дані'
# Прапорець будується лише тоді, коли API справді відповів про поле.
grep -Fq 'array_key_exists("definition", $term)' "$ROOT/cli/prepare/worker-payload.sh" \
    || fail 'payload не розрізняє «опису немає» і «сервер не сказав»'
# Найдорожче правило: черга НІЧОГО не надсилає в API.
grep -Fq 'http-request.sh' "$ROOT/cli/api/term-notes-queue.sh" && fail 'черга термінів звертається до API'
grep -Fq 'term-notes-queue.sh' "$ROOT/cli/run/run-drive.sh" || fail 'рушій не наповнює чергу термінів'

# Описувач термінів: завдання будується лише з придатних кандидатів, а
# надсилання відсіює низьку впевненість. Поріг 60 · рішення власника 2026-08-28.
cat > "$TMP/state/term-notes-queue.json" <<JSON
{"updated_at":"x","terms":[
 {"canonical_source":"Tears of the Falling Moon","ukrainian":"Сльози Старого Місяця","seen":5,
  "samples":["Tears of the Falling Moon glows."],"identity_hash":"$H1","snapshot_id":7},
 {"canonical_source":"No Identity","ukrainian":"Без ідентичності","seen":9,"samples":["x"]}]}
JSON
BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/api/term-notes-describe.sh" > "$TMP/describe.json" 2>/dev/null \
    || fail 'завдання на опис термінів не будується'
jq -e '.next.role == "translation-glossary"' "$TMP/describe.json" >/dev/null \
    || fail 'завдання не адресоване ролі translation-glossary'
jq -e '.next.prompt == ("payload:" + .next.payload_path)' "$TMP/describe.json" >/dev/null \
    || fail 'у завданні немає готового prompt'
# Термін без identity/snapshot надіслати неможливо · у завдання він не йде.
jq -e '[.items[].canonical_source] == ["Tears of the Falling Moon"]' "$TMP/state/term-notes-payload.json" >/dev/null \
    || fail 'у завдання потрапив термін, пропозицію для якого сервер не прийме'
# Низька впевненість НЕ надсилається, і причина названа.
printf '{"items":[{"canonical_source":"Tears of the Falling Moon","gist":"g","definition":"d","confidence":45}]}' \
    > "$TMP/state/term-notes-response.json"
out="$(BDO_STATE_DIR="$TMP/state" bash "$ROOT/cli/api/term-notes-submit.sh" 2>/dev/null)" || true
printf '%s' "$out" | grep -q 'Пропозицій надіслано: 0' || fail "опис із впевненістю 45 надіслано: $out"
printf '%s' "$out" | grep -q 'низька впевненість 1' || fail 'причину пропуску не названо'
# Найдорожче правило: перед записом стан терміна перечитується з API.
grep -Fq 'glossary/terms?q=' "$ROOT/cli/api/term-notes-submit.sh" \
    || fail 'відправник не перечитує свіжий стан терміна перед пропозицією'
grep -Fq 'array_key_exists("definition", $term)' "$ROOT/cli/api/term-notes-submit.sh" \
    || fail 'відправник приймає відсутність поля за порожній опис'

# Описи вмикаються САМІ й лише за потреби · власник нічого не каже диригенту.
DRIVE="$TMP/drive"; mkdir -p "$DRIVE/batches/b"
printf 'b\n' > "$DRIVE/current-batch"
cat > "$DRIVE/batches/b/manifest.json" <<'JSON'
{"id":"b","state":"selected","rows":1,"mode":"patch","patch":"7","channel":"machine","steps":{},"attempts":{}}
JSON
cat > "$DRIVE/batches/b/rows.json" <<JSON
{"data":{"rows":[{"identity_hash":"$H1","source_hash":"a","source_text":"x"}]},"meta":{"snapshot_id":7}}
JSON
php -r '$t=[];for($i=1;$i<=6;$i++){$t[]=["canonical_source"=>"Term $i","ukrainian"=>"Термін $i","seen"=>$i,"samples"=>["зразок"],"identity_hash"=>$argv[2],"snapshot_id"=>7];}
    file_put_contents($argv[1], json_encode(["updated_at"=>"x","terms"=>$t], JSON_UNESCAPED_UNICODE));' \
    "$DRIVE/term-notes-queue.json" "$H1"
out="$(BDO_STATE_DIR="$DRIVE" bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null)" || true
printf '%s' "$out" | jq -e '.next.role == "translation-glossary"' >/dev/null \
    || fail "описи не вмикаються самі при повній черзі: $(printf '%s' "$out" | head -c 120)"
# Порожня черга · крок не вмикається взагалі, пачка йде своїм шляхом.
rm -f "$DRIVE/term-notes-queue.json" "$DRIVE/term-notes-payload.json"
out="$(BDO_STATE_DIR="$DRIVE" BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null)" || true
printf '%s' "$out" | jq -e '.next.role != "translation-glossary"' >/dev/null \
    || fail 'описи вмикаються навіть тоді, коли описувати нічого'
# Завдання без відповіді не зациклює пачку. Стан пачки повертаємо на `selected`:
# попередній виклик уже провів її до воркера, а гілка описів живе саме тут.
cat > "$DRIVE/batches/b/manifest.json" <<'JSON'
{"id":"b","state":"selected","rows":1,"mode":"patch","patch":"7","channel":"machine","steps":{},"attempts":{}}
JSON
printf '{"items":[]}' > "$DRIVE/term-notes-payload.json"
out="$(BDO_STATE_DIR="$DRIVE" BDO_PIPELINE_OFFLINE=1 bash "$ROOT/cli/run/run-drive.sh" 2>/dev/null)" || true
printf '%s' "$out" | jq -e '.next.role != "translation-glossary"' >/dev/null \
    || fail 'завдання без відповіді видається знову й зациклює пачку'
if [ -f "$DRIVE/term-notes-payload.json" ]; then fail 'застаріле завдання не прибрано'; fi

# Нагадування про свіжу сесію · єдине, що прибирає вже накопичений транскрипт.
grep -Fq 'BDO_SESSION_HINT_BATCHES' "$ROOT/cli/run/run-drive.sh" \
    || fail 'рушій не нагадує почати нову сесію після N пачок'

# Вага payload, що осідає в транскрипті, рахується точно · це не оцінка.
grep -Fq 'session-load.json' "$ROOT/cli/run/run-drive.sh" || fail 'вага staged payload ніде не рахується'
grep -Fq 'BDO_SESSION_HINT_BYTES' "$ROOT/cli/run/run-drive.sh" || fail 'поріг нагадування не залежить від ваги payload'
# Суддя бачить ту саму форму, що воркер і QA: одна форма · одне правило.
grep -Fq '"examples" => $sharedExamples' "$ROOT/cli/prepare/judge-payload.sh" \
    || fail 'payload судді лишився з дубльованими прикладами'

echo 'payload shared examples: OK'
