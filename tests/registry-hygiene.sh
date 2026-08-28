#!/usr/bin/env bash
# Реєстри проєкту не мають тихо гнити.
#
# Клас дефекту. За добу 2026-08-28 той самий сценарій «правило є, механічної
# перевірки немає» повторився чотири рази (D1, D3, D6, D7 у реєстрі дефектів), а
# відкриті питання жили лише в чаті й губились між сесіями. Реєстри це
# виправляють, але тільки поки вони заповнені: порожня колонка «Регресія» або
# зниклий файл повертають проєкт рівно туди, звідки він вийшов.
#
# Тому перевіряється не наявність файлів, а їхня ПРИДАТНІСТЬ: кожен рядок
# дефекту називає або тест, або прямо каже, що перевірки немає.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

DEFECTS="$ROOT/docs/plans/DEFECTS.md"
CHECKLIST="$ROOT/docs/CHECKLIST.md"
test -f "$DEFECTS" || fail 'немає docs/plans/DEFECTS.md · реєстр дефектів'
test -f "$CHECKLIST" || fail 'немає docs/CHECKLIST.md · чекліст перевірок'

# 1. Реєстр не порожній і має рядки у сталій формі `| D<номер> | …`.
rows="$(grep -c '^| D[0-9]\+ ' "$DEFECTS" || true)"
test "${rows:-0}" -ge 1 || fail 'у реєстрі дефектів немає жодного рядка'

# 2. Кожен рядок має статус із дозволеного переліку й НЕПОРОЖНЮ регресію.
awk -F'|' '
/^\| D[0-9]+ / {
    id = $2; st = $7; reg = $8
    gsub(/[ \t]/, "", id); gsub(/[ \t]/, "", st)
    gsub(/^[ \t]+|[ \t]+$/, "", reg)
    if (st != "відкритий" && st != "закритий" && st != "прийнятий") {
        printf "FAIL: %s має невідомий статус «%s»\n", id, st > "/dev/stderr"; bad = 1
    }
    if (reg == "") {
        printf "FAIL: %s не називає регресії; порожня колонка означає, що дефект повернеться непоміченим\n", id > "/dev/stderr"; bad = 1
    }
    # Закритий дефект без доведеної перевірки · саме та пастка, заради якої
    # реєстр і заведено.
    if (st == "закритий" && reg ~ /немає перевірки/) {
        printf "FAIL: %s закритий, але перевірки немає · такий рядок лишається відкритим\n", id > "/dev/stderr"; bad = 1
    }
}
END { exit bad ? 1 : 0 }' "$DEFECTS" || fail 'реєстр дефектів заповнений неправильно'

# 3. Тести, названі в регресіях, мусять існувати: посилання на зниклий файл
#    гірше за його відсутність · воно створює хибну впевненість.
grep -o 'tests/[a-z0-9.-]*\.\(sh\|mjs\|php\)' "$DEFECTS" | sort -u | while read -r t; do
    test -f "$ROOT/$t" || fail "реєстр дефектів посилається на неіснуючий $t"
done

# 4. Чекліст веде до живих команд і реєстрів.
for needle in './bdo review' './bdo session' 'plans/DEFECTS.md' 'FLOW_STATE.md' './bdo gate full'; do
    grep -Fq "$needle" "$CHECKLIST" || fail "чекліст не згадує $needle"
done

# 5. Команда огляду існує і зареєстрована · інакше чекліст радить те, чого немає.
test -x "$ROOT/cli/audit/project-review.sh" || fail 'немає cli/audit/project-review.sh'
grep -Fq '"review"' "$ROOT/cli/command-registry.json" || fail 'команда review не в реєстрі команд'
grep -Fq 'review)     sh_run cli/audit/project-review.sh' "$ROOT/bdo" || fail 'dispatcher не знає команди review'

# 6. Правило ведення реєстру живе в правилах, а не лише в голові агента.
grep -Fq 'DEFECTS.md' "$ROOT/AGENTS.md" || fail 'AGENTS.md не вимагає вести реєстр дефектів'

echo 'registry hygiene: OK'
