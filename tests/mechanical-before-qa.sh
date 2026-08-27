#!/usr/bin/env bash
# Механіка виносить вирок ДО виклику QA, а контрольний QA більше не окремий крок.
#
# Клас дефекту. `Defects::inTranslation` рахувався лише в `cli/heal/heal-plan.sh`,
# тобто після того, як QA вже подивився ВСІ рядки. Заміряно 2026-08-27 на пачці
# `20260827_204715`: усі 50 кандидатів містили російську літеру `ё`, механіка
# засудила б їх за мілісекунди, а замість цього пройшов повний QA на 50 рядках,
# далі repair на 37 і контрольний QA на 37.
#
# Друга частина · злиття контрольного QA із суддею (рішення власника
# 2026-08-27): вилікуваний рядок читали двічі, хоча суддя однаково читає текст,
# а механічні дефекти рахуються на фінальному тексті в `judge-payload`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

hash_for() { printf '%064d' "$1"; }
DIRTY="$(hash_for 1)"
CLEAN="$(hash_for 2)"

cat > "$TMP/rows.json" <<JSON
{"data":{"rows":[
  {"identity_hash":"$DIRTY","source_hash":"a","source_text":"Dark Sail"},
  {"identity_hash":"$CLEAN","source_hash":"b","source_text":"Iron Sword"}
]}}
JSON
cat > "$TMP/clean.json" <<JSON
[{"identity_hash":"$DIRTY","text":"Парус Тёмного"},
 {"identity_hash":"$CLEAN","text":"Залізний меч"}]
JSON

# 1. Дефектний рядок отримує готовий вердикт, чистий · їде до QA.
left="$(bash "$ROOT/cli/quality/mechanical-split.sh" "$TMP/rows.json" "$TMP/clean.json" \
    "$TMP/pre.json" "$TMP/subset.json" 2>/dev/null)"
test "$left" = 1 || fail "у підмножині для QA мусив лишитись 1 чистий рядок, маємо: $left"
jq -e --arg h "$DIRTY" '.[0].identity_hash == $h and .[0].status == "REJECT" and .[0].severity == "critical"' "$TMP/pre.json" >/dev/null \
    || fail 'механічний вердикт не має форми відповіді QA'
jq -e '.[0].issue | contains("механічний дефект")' "$TMP/pre.json" >/dev/null \
    || fail 'вердикт не називає причини'
jq -e --arg h "$CLEAN" '.data.rows | length == 1 and .[0].identity_hash == $h' "$TMP/subset.json" >/dev/null \
    || fail 'у підмножині для QA не той рядок'

# 2. Усі рядки дефектні · QA не потрібен зовсім. Саме цей випадок стався на
#    живій пачці й коштував повного проходу на 50 рядках.
cat > "$TMP/all-dirty.json" <<JSON
[{"identity_hash":"$DIRTY","text":"Парус Тёмного"},
 {"identity_hash":"$CLEAN","text":"Меч 光明"}]
JSON
left="$(bash "$ROOT/cli/quality/mechanical-split.sh" "$TMP/rows.json" "$TMP/all-dirty.json" \
    "$TMP/pre2.json" "$TMP/subset2.json" 2>/dev/null)"
test "$left" = 0 || fail "усі рядки дефектні, а підмножина для QA не порожня: $left"
jq -e 'length == 2' "$TMP/pre2.json" >/dev/null || fail 'не всі дефектні рядки отримали вердикт'

# 3. Рушій справді ходить цим шляхом, а не лише має скрипт у дереві.
grep -Fq 'dispatch_qa' "$ROOT/cli/run/run-drive.sh" || fail 'рушій не викликає розділювач перед QA'
grep -Fq 'mechanical_only' "$ROOT/cli/run/run-drive.sh" || fail 'рушій не вміє пропустити QA на суцільному дефекті'
grep -Fq 'merge_pre_verdicts' "$ROOT/cli/run/run-drive.sh" || fail 'механічні вердикти не зливаються з відповіддю QA'
grep -Fq 'qa_scope="$B/qa-subset.json"' "$ROOT/cli/run/run-drive.sh" || fail 'QA перевіряється не проти того набору, який бачив'

# 4. Після лікування рядок іде ОДРАЗУ до судді: окремого контрольного QA немає.
#    Стан `awaiting_control_qa` лишається легальним для пачок, що вже в ньому.
awk '/^healing\)/,/^awaiting_control_qa\)/' "$ROOT/cli/run/run-drive.sh" > "$TMP/healing.txt"
grep -Fq 'judge_or_commit' "$TMP/healing.txt" || fail 'після лікування пачка не йде до судді'
grep -Fq 'child awaiting_control_qa' "$TMP/healing.txt" && fail 'лікування досі диспетчерить контрольний QA'
grep -Fq 'awaiting_control_qa' "$ROOT/lib/Pipeline/StateMachine.php" || fail 'стан прибрано з машини · старі пачки застрягнуть'
# ГОЛОВНА перевірка цього блоку, і саме її бракувало 2026-08-28: код почав робити
# перехід `healing -> awaiting_judge`, а машина станів його не дозволяла. Пачка
# власника стала намертво, хоча grep-перевірки вище були зелені · вони питали про
# ТЕКСТ, а не про дозволений перехід. Питати треба машину.
php -r 'require $argv[1];
    use Bdo\Translate\Pipeline\StateMachine;
    StateMachine::assertTransition("healing", "awaiting_judge");
    StateMachine::assertTransition("healing", "ready_to_commit");
    StateMachine::assertTransition("awaiting_control_qa", "awaiting_judge");' "$ROOT/lib/autoload.php" \
    || fail 'машина станів не дозволяє переходів, які робить рушій після лікування'

# 5. QA мусить повертати готовий текст, інакше злиття з repair не має сенсу.
grep -Fq 'обовʼязковий для КОЖНОГО рядка зі статусом' "$ROOT/.opencode/agent-templates/translation-qa.md" \
    || fail 'QA і далі дає fix лише за бажанням'
# Причини відмов FixPolicy мусить бачити не лише stderr пачки, яку зітре автоочистка.
grep -Fq 'fix-policy.jsonl' "$ROOT/cli/quality/qa-fixes.sh" || fail 'відмови FixPolicy ніде не журналюються'

# 6. Дебаг сесії мусить існувати як команда, а не як разовий SQL у голові.
#    2026-08-28 я дивився на стан пачки й лічильники токенів, побачив «нічого не
#    рухається» і сказав «сесія мовчить». Насправді сесія двічі отримала відмову
#    guard на спробі пропатчити код · ні стан, ні токени цього не показують.
test -x "$ROOT/cli/audit/session-tail.sh" || fail 'немає інструмента для дебагу сесії'
grep -Fq '"session ' "$ROOT/cli/command-registry.json" || fail 'команда session не в реєстрі'
grep -Fq 'session)    sh_run cli/audit/session-tail.sh' "$ROOT/bdo" || fail 'dispatcher не знає команди session'
grep -Fq 'state.error' "$ROOT/cli/audit/session-tail.sh" || fail 'дебаг сесії не показує причин відмов'

echo 'mechanical before qa: OK'
