#!/usr/bin/env bash
# Механічна перевірка самих правил цього репозиторію.
#
#   ./check-rules.sh
#
# Аналог `run_rule_checks()` з основного проєкту. Перевіряє те, що інакше
# застаріває мовчки:
#   1. AGENTS.md лишається картою, а не довідником (ліміт рядків).
#   2. Кожен файл, на який AGENTS.md посилається, існує. Правило, що веде в
#      неіснуючий файл, гірше за відсутнє: агент іде вигадувати замість читати.
#   3. Вказівники CLAUDE.md / QWEN.md / .cursorrules ведуть на AGENTS.md і
#      однакові між собою · щоб не завелося чотири версії правил.
#   4. Хуки увімкнені. Правило про формат коміта без хука існує лише на папері.
#   5. У tracked-файлах немає секретів і персональних даних власника · це
#      публічний репозиторій.
set -uo pipefail

cd "$(cd "$(dirname "$0")" && pwd)" || exit 1

status=0
fail() { printf 'ERROR: %s\n' "$1" >&2; status=1; }
ok() { printf 'OK: %s\n' "$1"; }

# 1. Карта лишається картою.
lines="$(wc -l < AGENTS.md | tr -d ' ')"
if [ "$lines" -gt 200 ]; then
    fail "AGENTS.md розрісся до $lines рядків (ліміт 200); деталі · у docs/"
else
    ok "AGENTS.md · $lines рядків із 200"
fi

# 2. Посилання на файли існують.
missing=0
while IFS= read -r ref; do
    test -e "$ref" || { fail "AGENTS.md посилається на неіснуючий файл: $ref"; missing=$((missing + 1)); }
done < <(grep -oE '`[a-zA-Z0-9_./*-]+\.(md|txt|sh|ts|json|php)`' AGENTS.md | tr -d '`' | grep -v '[*]' | sort -u)
[ "$missing" -eq 0 ] && ok 'усі файли зі згадок AGENTS.md існують'

# 3. Вказівники.
pointers=0
for f in CLAUDE.md QWEN.md .cursorrules; do
    if [ ! -f "$f" ]; then
        fail "немає вказівника $f"
        continue
    fi
    grep -q 'AGENTS.md' "$f" || fail "$f не веде на AGENTS.md"
    pointers=$((pointers + 1))
done
if [ "$pointers" -eq 3 ]; then
    uniq_count="$(md5 -q CLAUDE.md QWEN.md .cursorrules 2>/dev/null | sort -u | wc -l | tr -d ' ')"
    [ "$uniq_count" = '1' ] || fail 'вказівники CLAUDE.md / QWEN.md / .cursorrules розійшлися'
    [ "$uniq_count" = '1' ] && ok 'три вказівники однакові й ведуть на AGENTS.md'
fi

# 4. Хуки.
test -x .githooks/pre-commit || fail 'немає виконуваного .githooks/pre-commit'
test -x .githooks/commit-msg || fail 'немає виконуваного .githooks/commit-msg'
hooks_path="$(git config core.hooksPath || true)"
if [ "$hooks_path" != '.githooks' ]; then
    fail "core.hooksPath='$hooks_path' замість '.githooks'. Увімкни: git config core.hooksPath .githooks"
else
    ok 'хуки увімкнені'
fi

# 5. Публічність: ні секретів, ні персональних даних у tracked-файлах.
leak="$(git ls-files -z | xargs -0 grep -nIhE \
    'sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[a-zA-Z0-9._%+-]+@(gmail|ukr|yahoo|outlook)\.[a-z]+|/Users/[a-z]+/' \
    2>/dev/null | head -3)"
if [ -n "$leak" ]; then
    fail 'у tracked-файлах є щось схоже на секрет або персональні дані:'
    printf '%s\n' "$leak" >&2
else
    ok 'секретів і персональних даних у tracked-файлах немає'
fi
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    fail '.env відслідковується git · прибери: git rm --cached .env'
else
    ok '.env не відслідковується'
fi

if [ "$status" -eq 0 ]; then
    echo 'Правила в порядку.'
else
    echo 'Є проблеми вище.' >&2
fi
exit "$status"
