#!/usr/bin/env bash
# Єдиний недеструктивний quality gate bdo-ua-ai-localization.
#
# Профілі:
#   preflight  середовище, layout і правила перед роботою
#   docs       rules, plans, env contract, links і secret scan
#   shell      bash syntax, ShellCheck і PHP syntax
#   agents     OpenCode config, prompts, model allowlist і routing guard
#   runtime    локальна Ollama-модель, явно й окремо
#   api        read-only Agent API smoke, явно й окремо
#   full       docs + shell + agents, без зовнішніх model/API calls
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
cd "$ROOT"

readonly RULE_FILES=(AGENTS.md .cursorrules CLAUDE.md QWEN.md)
readonly RULE_REFERENCE='docs/AI_AGENT_RULES_REFERENCE.md'
readonly RULE_MAP_MAX_LINES=200

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$1"; }
note() { printf '   %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }
run() { printf '   $ %s\n' "$*"; "$@" || fail "$1 завершився з ненульовим кодом"; }

changed_files() {
    {
        git diff --name-only --diff-filter=ACMR
        git diff --name-only --diff-filter=ACMR --cached
        git ls-files --others --exclude-standard
    } | sort -u
}

public_files() {
    {
        git ls-files
        git ls-files --others --exclude-standard
    } | awk '!/(^|\/)(output|state|state-auto|node_modules)(\/|$)/ && !/(^|\/)\.env($|\.)/' | sort -u
}

check_rules() {
    step 'Rule-файли та норматив'
    local file lines duplicate bad_number
    for file in "${RULE_FILES[@]}"; do
        test -f "$file" || fail "немає $file"
    done
    for file in "${RULE_FILES[@]:1}"; do
        cmp -s AGENTS.md "$file" || fail "$file не ідентичний AGENTS.md"
    done
    test -f "$RULE_REFERENCE" || fail "немає $RULE_REFERENCE"
    lines="$(wc -l < AGENTS.md | tr -d ' ')"
    test "$lines" -le "$RULE_MAP_MAX_LINES" || fail "AGENTS.md має $lines рядків із лімітом $RULE_MAP_MAX_LINES"
    duplicate="$(perl -ne 'print "$1\n" if /^- §(\d+\.\d+)/' "$RULE_REFERENCE" | sort | uniq -d | sed -n '1p')"
    test -z "$duplicate" || fail "дублікат номера §$duplicate"
    bad_number="$(perl -ne '$s=$1 if /^## §(\d+)\b/; print "$.:$_" if /^- §(\d+)\.\d+/ && $1 != $s' "$RULE_REFERENCE" | sed -n '1p')"
    test -z "$bad_number" || fail "номер правила не відповідає секції: $bad_number"
    # Розподіл прав на Git · рішення власника, а не стильова деталь, тому воно не
    # має права тихо зникнути при наступному переписуванні карти правил.
    grep -Fq 'git push` робить ВИКЛЮЧНО власник' AGENTS.md \
        || fail 'у AGENTS.md немає правила «git push робить виключно власник»'
    grep -Fq 'git push` робить ТІЛЬКИ власник' .opencode/critical-rules.md \
        || fail 'у .opencode/critical-rules.md немає правила про push'
    grep -Fq '§4.2 `git push` виконує ВИКЛЮЧНО власник' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §4.2 про push"
    note "4 дзеркала ідентичні; AGENTS.md: $lines/$RULE_MAP_MAX_LINES рядків"
    note 'правило про push присутнє в карті, критичних правилах і нормативі'
}

# Документи й промпти, посилання в яких мусять вести на наявний файл.
#
# `docs/plans/**` навмисно поза перевіркою: план законно називає файли, яких ще
# немає · це і є план. `docs/FLOW_STATE.md` перевіряється, бо його «Команди» й
# «Механічні гарантії» описують чинний стан, а не історію.
linked_docs() {
    {
        git ls-files '*.md'
        git ls-files --others --exclude-standard '*.md'
    } | awk '!/^(archive|docs\/plans)\//' | sort -u
}

# Шлях може бути записаний відносно свого документа, кореня repo або жити в
# одному з відомих каталогів. Без цього `critical-rules.md` із `docs/README.md`
# читалось би як неіснуючий файл, хоча він лежить у `.opencode/`.
resolve_reference() {
    local ref="$1" dir="$2" candidate
    for candidate in \
        "$ref" "$dir/$ref" "$dir/plans/$ref" \
        ".opencode/$ref" ".opencode/agents/$ref" \
        "docs/$ref" "docs/plans/$ref" "scripts/$ref" \
        "archive/legacy-script-flow/$ref"
    do
        test -e "$candidate" && return 0
    done
    return 1
}

check_references() {
    step 'Посилання в документах і промптах'
    # Довідники СЕРВЕРНОГО проєкту: доступні через TRANSLATE_PROJECT_ROOT, а не тут.
    local -r external='docs/AGENT_TRANSLATION_API.md YYYY-MM-DD_SLUG.md'
    local doc ref plan base checked=0
    while IFS= read -r doc; do
        test -f "$doc" || continue
        while IFS= read -r ref; do
            case " $external " in *" $ref "*) continue ;; esac
            resolve_reference "$ref" "$(dirname "$doc")" \
                || fail "$doc посилається на відсутній $ref"
            checked=$((checked + 1))
        done < <(perl -ne 'while (/`([A-Za-z0-9_.\/-]+\.(?:md|sh|ts|php))`/g) { print "$1\n" }' "$doc" | sort -u)
    done < <(linked_docs)
    note "перевірено $checked посилань у документах і промптах"

    step 'Заморожений код не подається як робочий шлях'
    local instruction frozen hit
    # Ці файли КАЖУТЬ агентові, що робити. Виклик замороженого скрипта звідси ·
    # саме той випадок, коли документація тихо розходиться з рішенням власника.
    for instruction in README.md AGENTS.md .cursorrules CLAUDE.md QWEN.md \
        UI_SUBAGENT_WORKFLOW.md docs/PROJECT_OVERVIEW.md docs/README.md \
        .opencode/critical-rules.md .opencode/agents/*.md
    do
        test -f "$instruction" || continue
        for frozen in translate-patch.sh translate-menu.sh agent-call.sh merge-verdicts.sh; do
            # `|| true`: під `pipefail` порожній grep дав би ненульовий статус
            # пайпа, і `set -e` вбив би gate замість того, щоб визнати «чисто».
            hit="$(grep -n -- "\./$frozen" "$instruction" | sed -n '1p' || true)"
            test -z "$hit" || fail "$instruction подає заморожений $frozen як команду: $hit"
        done
    done
    note 'жоден інструктивний файл не кличе archive/legacy-script-flow'

    step 'Структура планів'
    test -f docs/plans/README.md || fail 'немає реєстру docs/plans/README.md'
    test -f docs/plans/BACKLOG.md || fail 'немає docs/plans/BACKLOG.md'
    for plan in docs/plans/active/*.md docs/plans/backlog/*.md; do
        test -e "$plan" || continue
        base="$(basename "$plan")"
        grep -Fq "$base" docs/plans/README.md || fail "$base не зареєстрований у docs/plans/README.md"
        grep -q '^\- \*\*Статус:\*\* \(active\|backlog\)$' "$plan" || fail "$plan не має коректного статусу"
        grep -q '^\- \*\*Створено:\*\* [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$' "$plan" || fail "$plan не має дати створення"
        grep -Fq '**Реєстр:** [docs/plans/README.md](../README.md)' "$plan" || fail "$plan не посилається на реєстр"
    done
    note 'активні/backlog плани узгоджені з реєстром'
}

check_env_contract() {
    step 'ENV contract'
    git check-ignore -q .env || fail '.env не ігнорується'
    git check-ignore -q private/.env.local || fail 'nested .env.local не ігнорується'
    git check-ignore -q .env.example && fail '.env.example помилково ігнорується'
    git ls-files --error-unmatch .env >/dev/null 2>&1 && fail '.env відслідковується Git'
    test -f .env.example || fail 'немає .env.example'
    # Порожнім мусить бути будь-який ключ · і в новій формі, і в старій парі.
    if grep -E '^(BDO_API_KEY|BDO_API_KEY_LOCALHOST|BDO_API_KEY_PROD)=.+' .env.example >/dev/null; then
        fail '.env.example містить непорожній API key'
    fi
    # Ціль прогону · одна константа. Шаблон без неї означає, що агент знову
    # мусив би виводити середовище з формулювання запиту.
    grep -Eq '^BDO_ENV=(PROD|DEV)$' .env.example || fail '.env.example не задає BDO_ENV=PROD або BDO_ENV=DEV'
    grep -Eq '^BDO_API_BASE=' .env.example || fail '.env.example не задає BDO_API_BASE'
    grep -Eq '^BDO_API_KEY=$' .env.example || fail '.env.example не має порожнього BDO_API_KEY'
    note '.env* приватні; .env.example задає одну ціль і порожній ключ'
}

check_public_safety() {
    step 'Tracked/new content: secrets і приватні дані'
    local pattern file sample
    pattern='sk-[A-Za-z0-9]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abpsr]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}|\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}|\$argon2(id|i|d)\$|/Users/[A-Za-z0-9._-]+/|[A-Za-z0-9._%+-]+@(gmail|ukr|yahoo|outlook)\.[A-Za-z]{2,}'
    while IFS= read -r file; do
        test -f "$file" || continue
        if LC_ALL=C grep -Iq . "$file" 2>/dev/null && grep -EIl "$pattern" "$file" >/dev/null 2>&1; then
            fail "підозріле чутливе значення у $file (вміст не виводиться)"
        fi
    done < <(public_files)
    sample='sk-''AAAAAAAAAAAAAAAAAAAA'
    printf '%s\n' "$sample" | grep -Eq "$pattern" || fail 'negative test: API key pattern не спрацював'
    sample='$2b$12$''AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    printf '%s\n' "$sample" | grep -Eq "$pattern" || fail 'negative test: credential hash pattern не спрацював'
    sample='identity_hash=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    if printf '%s\n' "$sample" | grep -Eq "$pattern"; then
        fail 'negative test: technical identity_hash помилково класифікований як credential'
    fi
    note 'secret detector ловить key/hash fixtures і дозволяє technical identity_hash'
}

check_whitespace() {
    step 'Whitespace і conflict markers'
    git diff --check
    git diff --cached --check
    note 'git diff --check: чисто'
}

check_docs() {
    check_rules
    check_references
    check_env_contract
    check_public_safety
    check_whitespace
}

check_shell() {
    step 'Bash syntax'
    local file count=0
    while IFS= read -r file; do
        test -f "$file" || continue
        case "$file" in *.sh|.githooks/*)
            bash -n "$file" || fail "bash -n: $file"
            count=$((count + 1))
        esac
    done < <(public_files)
    note "bash -n: $count файлів"

    step 'ShellCheck'
    have shellcheck || fail 'shellcheck недоступний'
    while IFS= read -r file; do
        test -f "$file" || continue
        case "$file" in *.sh|.githooks/*) shellcheck -x -S warning "$file" || fail "shellcheck: $file" ;; esac
    done < <(public_files)
    note 'ShellCheck: пройдено'

    step 'PHP syntax'
    have php || fail 'php недоступний'
    count=0
    while IFS= read -r file; do
        test -f "$file" || continue
        case "$file" in *.php) php -l "$file" >/dev/null || fail "php -l: $file"; count=$((count + 1)) ;; esac
    done < <(public_files)
    note "php -l: $count файлів"
}

check_agents() {
    step 'OpenCode agents і routing guard'
    have jq || fail 'jq недоступний'
    jq -e . opencode.json >/dev/null || fail 'opencode.json невалідний JSON'
    run bash .opencode/validate-translation-agents.sh
}

check_runtime() { run ./check-runtime.sh; }
# Ціль НЕ підставляється: її задає BDO_ENV у `.env`, і нав'язати тут `local`
# означало б показати результат не того середовища, у якому працює прогін.
check_api() { run ./test-api.sh; }

report_preflight() {
    step 'Стан робочого дерева'
    note "root: $ROOT"
    note "branch: $(git branch --show-current 2>/dev/null || printf '(detached)')"
    git status --short | sed 's/^/     /'
    step 'Інструменти'
    local tool
    for tool in git bash php jq curl shellcheck perl; do
        if have "$tool"; then note "OK $tool"; else note "ВІДСУТНІЙ $tool"; fi
    done
    run ./paths.sh
    # Ціль прогону першою: агент, який не знає середовища, або питає власника
    # про те, що написано у файлі, або йде в чуже. Ключ тут не друкується.
    step 'Ціль прогону'
    if [ -f .env ] || [ -n "${TRANSLATE_ENV_FILE:-}" ]; then
        bash ./select-env.sh 2>&1 >/dev/null | sed 's/^/   /'
    else
        note 'немає .env · скопіюй .env.example і задай BDO_ENV, BDO_API_BASE, BDO_API_KEY'
    fi
    check_rules
    check_env_contract
}

profile="${1:-}"
case "$profile" in
    preflight) report_preflight ;;
    docs) check_docs ;;
    shell) check_rules; check_shell; check_whitespace ;;
    agents) check_rules; check_agents; check_whitespace ;;
    runtime) check_rules; check_runtime ;;
    api) check_rules; check_api ;;
    full) check_docs; check_shell; check_agents ;;
    *) printf 'Usage: %s {preflight|docs|shell|agents|runtime|api|full}\n' "$0" >&2; exit 2 ;;
esac

printf '\nAgent gate passed: %s\n' "$profile"
