#!/usr/bin/env bash
# Рядок із НАКАЗОВОЮ підказкою API дістає додаткову спробу ремонту.
#
# Клас дефекту. Одне коло лікування · виміряне рішення 2026-08-16 для вироків
# QA: смакові зауваження другим колом майже не рятуються, а коштують хвилин.
# Але відмова API з полем `expected` має іншу природу й іншу ціну.
#
# Природа: це не думка про стиль, а точна вказівка «ужий «Човен» для «Ship»».
# Ціна: такий рядок не потрапляє НІКУДИ. У шар його не пускає валідація, а
# канал модерації перевіряє глосарій тим самим правилом і теж відмовляє · рядок
# падає в карантин. Заміряно 2026-09-04 на `20260904_055351`: 15 рядків із 50
# згоріли саме так (D53).
#
# Тому перевіряємо ПОВЕДІНКУ на межі: рядок зі смаковим дефектом після першої
# спроби йде до людини, а рядок із наказовою підказкою · ще раз у ремонт.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

H_TASTE='1111111111111111111111111111111111111111111111111111111111111111'
H_API='2222222222222222222222222222222222222222222222222222222222222222'
H_BOTH='3333333333333333333333333333333333333333333333333333333333333333'

# Форма rows.json · та сама, що віддає API: `data.rows`.
cat > "$WORK/rows.json" <<JSON
{"data": {"rows": [
  {"identity_hash": "$H_TASTE", "source_text": "Iron Sword", "record_id": 1, "key0": "a", "key1": "b", "source_language": "en"},
  {"identity_hash": "$H_API", "source_text": "Ship of Chorong Merchant Guild", "record_id": 2, "key0": "a", "key1": "c", "source_language": "en"},
  {"identity_hash": "$H_BOTH", "source_text": "Epheria Carrack: Balance", "record_id": 3, "key0": "a", "key1": "d", "source_language": "en"}
]}}
JSON
cat > "$WORK/candidate.json" <<JSON
[
  {"identity_hash": "$H_TASTE", "text": "Залізний меч"},
  {"identity_hash": "$H_API", "text": "Корабель гільдії"},
  {"identity_hash": "$H_BOTH", "text": "Корвет Еферії: Щільні вітрила"}
]
JSON
# QA дала смаковий REVIEW першому рядку; другий QA пропустила.
cat > "$WORK/verdicts.json" <<JSON
[
  {"identity_hash": "$H_TASTE", "status": "REVIEW", "severity": "minor", "issue": "звучить сухо", "fix": ""},
  {"identity_hash": "$H_API", "status": "PASS", "severity": "none", "issue": "", "fix": ""},
  {"identity_hash": "$H_BOTH", "status": "REJECT", "severity": "critical", "issue": "Candidate використовує «Корвет Еферії: Щільні вітрила», що є повною помилкою: неправильний тип корабля, неправильна друга частина назви, і взагалі рядок не відповідає джерелу за змістом", "fix": ""}
]
JSON
# Відмова API з наказовою підказкою · саме та форма, яку віддає живий сервер.
cat > "$WORK/validate.json" <<JSON
{"data": {"results": [
  {"identity_hash": "$H_API", "status": "rejected", "code": "glossary_violation",
   "message": "Текст розходиться з глосарієм",
   "details": {"glossary": [
     {"termId": 1, "canonical": "Ship", "expected": "Човен", "issue": "missing_translation", "severity": "mandatory"},
     {"termId": 2, "canonical": "Chorong Merchant Guild", "expected": "Торговець з ліхтарем", "issue": "missing_translation", "severity": "mandatory"}
   ]}},
  {"identity_hash": "$H_BOTH", "status": "rejected", "code": "glossary_violation",
   "message": "Текст розходиться з глосарієм",
   "details": {"glossary": [
     {"termId": 3, "canonical": "Epheria Carrack: Balance", "expected": "Галеон Еферії: Баланс", "issue": "missing_translation", "severity": "mandatory"}
   ]}}
]}}
JSON
echo '{}' > "$WORK/qa-fixes.json"

# Пачка потрібна справжня: `heal-plan.sh` перевіряє належність файлів пачці
# окремим скриптом і без цього не працює. Свій `BDO_STATE_DIR` тримає прогін
# власника осторонь.
export BDO_STATE_DIR="$WORK/state"
mkdir -p "$BDO_STATE_DIR"
php "$ROOT/cli/bdo.php" batch-new "$WORK/rows.json" >/dev/null 2>&1 \
    || fail 'не вдалося створити тестову пачку'
BATCH_DIR="$(php "$ROOT/cli/bdo.php" batch-dir)"
REPAIR="$BATCH_DIR/heal-repair-payload.json"

plan() {
    php "$ROOT/cli/bdo.php" heal-plan "$WORK/rows.json" "$WORK/candidate.json" \
        "$WORK/verdicts.json" "$WORK/validate.json" 2>&1
}

in_repair() {
    php -r '
    $p = json_decode((string) file_get_contents($argv[1]), true) ?: [];
    foreach ($p as $item) { if (($item["identity_hash"] ?? "") === $argv[2]) { exit(0); } }
    exit(1);' "$REPAIR" "$1"
}

# 1. Перше коло: у ремонт ідуть обидва рядки.
out="$(plan)" || fail "перше коло впало: $out"
in_repair "$H_TASTE" || fail "смаковий дефект не потрапив у перше коло ремонту"
in_repair "$H_API" || fail "відмова API не потрапила в перше коло ремонту"

# 2. Підказка мусить бути НАКАЗОВОЮ, інакше модель вгадує назву з речення.
php -r '
$p = json_decode((string) file_get_contents($argv[1]), true) ?: [];
foreach ($p as $item) {
    if (($item["identity_hash"] ?? "") !== $argv[2]) { continue; }
    $text = implode(" ", (array) ($item["defects"] ?? []));
    if (! str_contains($text, "ужий «Човен» для «Ship»")) {
        fwrite(STDERR, "у payload ремонту немає наказової підказки: ".$text."\n");
        exit(1);
    }
    exit(0);
}
fwrite(STDERR, "рядка немає в payload\n"); exit(1);' "$REPAIR" "$H_API" \
    || fail 'відмова API дійшла до ремонту без поля expected'

# 2б. Наказова вказівка мусить бути ПЕРШОЮ в списку дефектів.
#
#     У реальній пачці вирок QA буває на 400 символів прози, і точна вказівка
#     тоне в кінці абзацу. Заміряно 2026-09-04: коли вказівка була єдиною,
#     локальна модель виконала її 15 разів із 15; у живих пачках, де вона йшла
#     після прози, рядки однаково падали в карантин.
php -r '
$p = json_decode((string) file_get_contents($argv[1]), true) ?: [];
foreach ($p as $item) {
    if (($item["identity_hash"] ?? "") !== $argv[2]) { continue; }
    $defects = (array) ($item["defects"] ?? []);
    if ($defects === [] || ! str_contains((string) $defects[0], "ужий «")) {
        fwrite(STDERR, "перший дефект не є наказовою вказівкою: ".json_encode($defects, JSON_UNESCAPED_UNICODE)."\n");
        exit(1);
    }
    exit(0);
}
fwrite(STDERR, "рядка немає в payload\n"); exit(1);' "$REPAIR" "$H_BOTH" \
    || fail 'наказова вказівка не стоїть першою серед дефектів'

# 3. БЮДЖЕТ СПРОБ ЗМІНЕНО (рішення власника 2026-09-21): автономність важливіша
#    за вартість викликів. Раніше тут стояло «смаковий рядок вичерпав спробу
#    після ПЕРШОГО кола» · виміряне рішення 2026-08-16, коли головним
#    аргументом був час. Власник зняв цей аргумент прямо: «нехай скільки влізе
#    викликається моделі і ролі, головне зняти ручну роботу». Одне коло
#    означало, що кожен недоремонтований рядок ставав роботою людини на сервісі
#    · саме це дало 265 рядків у модерації на сесії `20260919_061647`.
#
#    Тому перевіряється не число, а ДВІ властивості, які мусять пережити будь-яку
#    зміну бюджету:
#      · наказова підказка API завжди дістає на одне коло БІЛЬШЕ за смакову;
#      · бюджет скінченний · інакше безнадійний випадок крутився б вічно.
#    Саме число береться з живого коду, щоб тест не став другим джерелом правди.
BUDGET="$(grep -oE "BDO_HEAL_MAX_ATTEMPTS'\\) \\?: '[0-9]+'" "$ROOT/lib/Cli/Command/Heal/HealPlanCommand.php" | grep -oE "[0-9]+")"
test -n "$BUDGET" || fail 'у коді не знайдено типового бюджету кіл ремонту'
test "$BUDGET" -ge 1 || fail 'бюджет спроб ремонту нечитабельний'

# Перше коло вже пройдено вище. Докручуємо смаковий рядок рівно до його межі.
round=1
while [ "$round" -lt "$BUDGET" ]; do
    out="$(plan)" || fail "коло $((round + 1)) впало: $out"
    in_repair "$H_TASTE" || fail "смаковий дефект вичерпався на колі $round із $BUDGET"
    round=$((round + 1))
done

# Наступне коло: смаковий бюджет вичерпано, наказова підказка ще має запас.
out="$(plan)" || fail "коло після межі впало: $out"
in_repair "$H_TASTE" && fail "смаковий дефект пішов за межу бюджету $BUDGET"
in_repair "$H_API" || fail 'рядок із наказовою підказкою НЕ отримав додаткового кола'

# 4. Ще одне коло: додаткове коло одне, не нескінченність.
out="$(plan)" || fail "останнє коло впало: $out"
in_repair "$H_API" && fail 'додаткових кіл виявилось більше одного · бюджет перестав бути скінченним'

# 5. РЕМОНТ ВІДДАЄ АДРЕСУ ПРАВКИ, А НЕ ТЕКСТ (рішення власника 2026-09-18).
#
#    Промпт і раніше просив «правильні частини не переписуй», але тримало це
#    лише прохання: на тестовій пачці 20260918_222153 одна з шести правок мала
#    схожість 65.6% · ремонт замінив ціле речення, і суддя пропустив гірший
#    текст у шар. Тепер межу тримає код, тому перевіряємо всі три його місця:
#    промпт, схему відповіді й крок накладання в драйвері.
grep -Fq '"find"' "$ROOT/roles/translation-repair.md" \
    || fail 'промпт ремонту не вимагає find/replace · модель знову передруковуватиме рядок'
if grep -Fq '"text"' "$ROOT/roles/translation-repair.md"; then
    fail 'промпт ремонту досі згадує поле text · контракт роздвоєний'
fi
DRIVE="$ROOT/lib/Cli/Command/Run/RunDriveCommand.php"
grep -Fq "new ApplyEditsCommand(), [\$this->workspace->path('heal-merged.json')" "$DRIVE" \
    || fail 'драйвер накладає ремонт не адресною правкою · merge повертає довіру до моделі'
grep -Fq "'--edits', \$this->workspace->path('heal-repair-subset.json')" "$DRIVE" \
    || fail 'драйвер ставить ремонту схему не з --edits · роль зможе віддати повний текст'

# 5. КОЛО МУСИТЬ ЗАМИКАТИСЬ У ДРАЙВЕРІ. Бюджет вище нічого не дає, поки після
#    ремонту ніхто не переобраховує дефекти: до 2026-09-21 драйвер ішов із
#    `healing()` одразу до судді, тому друге коло існувало лише в плані й
#    жодного разу не виконувалось на прогоні. Перевіряємо чотири стани
#    переходу, кожен окремою причиною відмови.
flat_drive="$(tr '\n' ' ' < "$DRIVE" | tr -s ' ')"
case "$flat_drive" in
    *"return \$this->repairRoundOrJudge(\$output);"*) ;;
    *) fail 'драйвер після лікування не заходить у коло ремонту · бюджет спроб недосяжний' ;;
esac
case "$flat_drive" in
    *"'translation-repair', \$repairPath"*) ;;
    *) fail 'коло ремонту не викликає роль ремонту · переобрахунок нікуди не веде' ;;
esac
case "$flat_drive" in
    *"Items::count(\$repairPath) === 0"*) ;;
    *) fail 'коло ремонту не вміє завершитись на порожньому наборі · прогін зациклиться' ;;
esac
case "$flat_drive" in
    *"getenv('BDO_HEAL_ROUNDS') === 'off'"*) ;;
    *) fail 'коло ремонту неможливо вимкнути · діагностика прогону втрачає керування' ;;
esac

echo "OK: бюджет кіл ремонту $BUDGET, наказова підказка API дає рівно одне додаткове коло, бюджет скінченний; коло замикається в драйвері; ремонт відповідає адресою правки."
