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
    note "4 дзеркала ідентичні; AGENTS.md: $lines/$RULE_MAP_MAX_LINES рядків"
}

check_references() {
    step 'Посилання карти та структура планів'
    local ref plan base
    while IFS= read -r ref; do
        test -e "$ref" || fail "AGENTS.md посилається на відсутній $ref"
    done < <(perl -ne 'while (/`([A-Za-z0-9_.\/-]+\.(?:md|txt|sh|ts|json|php))`/g) { print "$1\n" }' AGENTS.md | sort -u)
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
    note 'посилання карти й активні/backlog плани узгоджені'
}

check_env_contract() {
    step 'ENV contract'
    git check-ignore -q .env || fail '.env не ігнорується'
    git check-ignore -q private/.env.local || fail 'nested .env.local не ігнорується'
    git check-ignore -q .env.example && fail '.env.example помилково ігнорується'
    git ls-files --error-unmatch .env >/dev/null 2>&1 && fail '.env відслідковується Git'
    test -f .env.example || fail 'немає .env.example'
    if grep -E '^(BDO_API_KEY_LOCALHOST|BDO_API_KEY_PROD)=.+' .env.example >/dev/null; then
        fail '.env.example містить непорожній API key'
    fi
    note '.env* приватні; .env.example публічний і без ключів'
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
check_api() { BDO_API_ENV="${BDO_API_ENV:-local}" run ./test-api.sh; }

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
