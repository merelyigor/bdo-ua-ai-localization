#!/usr/bin/env bash
# Промпт ролі не сміє спиратися на поле, якого її payload не несе.
#
# 2026-09-05 (D79) `roles/translation-repair.md` казав моделі «`semantic_type` і
# `domain` кажуть, що саме перед тобою» і «сильніші за нього `glossary`, `terms`
# і `examples` цієї пачки», а будівники його payload (`cli/heal/heal-plan.sh`,
# `cli/prepare/names-payload.sh`) не клали з цього НІЧОГО, крім `glossary`.
# Роль правила назву предмета й репліку квесту з однаковим знанням про них ·
# тобто без нього. Розходження не давало жодної помилки: модель просто не
# знаходила поля й мовчки працювала наосліп.
#
# Це і є клас, а не випадок: промпти й payload лежать у різних файлах, і ніщо
# їх не звіряло. Тут звіряє.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Роль -> файли, які будують її payload. Роль без рядка тут перевіряється лише
# на те, що вона взагалі згадана нижче · інакше новий будівник тихо випав би.
declare -a PAIRS=(
    "translation-worker|cli/prepare/worker-payload.sh"
    "translation-qa|cli/prepare/qa-payload.sh"
    "translation-repair|cli/heal/heal-plan.sh"
    "translation-names|cli/prepare/names-payload.sh"
)

# Поля payload, згадка яких у промпті є ОБІЦЯНКОЮ даних. Службові слова
# («items», «id», «text») сюди не входять: вони описують форму відповіді.
FIELDS='semantic_type domain concepts examples terms glossary glossary_hint keep limits orders defects current source_text'

checked=0
for pair in "${PAIRS[@]}"; do
    role="${pair%%|*}"
    builder="${pair##*|}"
    prompt="$ROOT/roles/${role}.md"
    test -s "$prompt" || fail "немає промпта ролі ${role}"
    test -s "$ROOT/$builder" || fail "немає будівника payload ${builder}"

    for field in $FIELDS; do
        # Згадка в промпті рахується лише в зворотних лапках · так поле
        # називають, коли посилаються на ДАНІ, а не на слово в реченні.
        grep -Fq "\`${field}\`" "$prompt" || continue
        checked=$((checked + 1))
        # Спільні блоки payload будує окремий клас, тому шукаємо і поле, і його.
        if grep -Fq "\"${field}\"" "$ROOT/$builder"; then
            continue
        fi
        if [ "$field" = concepts ] && grep -Fq 'Payload\Concepts::forTexts' "$ROOT/$builder"; then
            continue
        fi
        if [ "$field" = semantic_type ] && grep -Fq 'semanticType()' "$ROOT/$builder"; then
            continue
        fi
        if [ "$field" = domain ] && grep -Fq 'domain()' "$ROOT/$builder"; then
            continue
        fi
        fail "промпт ролі ${role} посилається на «${field}», а ${builder} цього поля не кладе · модель шукатиме те, чого немає (D79)"
    done
done

test "$checked" -ge 12 \
    || fail "перевірено лише ${checked} посилань · схоже, промпти перестали називати поля зворотними лапками, і перевірка стала порожньою"

# Зворотна межа: роль, яку кличе драйвер, мусить існувати в конфізі й мати
# промпт. Без цього поділ ролей ламав би прогін уже на живій пачці.
for role in $(grep -oE 'child [a-z_]+ (translation-[a-z-]+)' "$ROOT/cli/run/run-drive.sh" | awk '{print $3}' | sort -u); do
    test -s "$ROOT/roles/${role}.md" || fail "драйвер кличе роль ${role}, а промпта роль не має"
    php -r '
        $c = json_decode((string) file_get_contents($argv[1]), true);
        exit(isset($c["roles"][$argv[2]]) ? 0 : 1);
    ' "$ROOT/config/roles.json" "$role" || fail "драйвер кличе роль ${role}, якої немає в config/roles.json"
done

# Те, що прохід по назвах лишається ВУЗЬКИМ, перевіряється на ДАНИХ у
# `tests/names-pass.sh`: там будівник справді виконується, і `jq` дивиться в
# готовий payload. Grep по коду тут був би слабшим за задачу · перевіряв би
# написання, а не результат.

echo "prompt/payload contract: OK · перевірено ${checked} посилань на поля, кожна роль драйвера має промпт і конфіг."
