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
    # Переклад робиться в OpenCode через готові primary-режими.
    # Це не стилістика: передавання payload у субагента текстом дало чотири
    # прогони підряд із нулем записаних рядків. Правило не має права зникнути з
    # промпта диригента при наступному переписуванні.
    grep -Fq 'ПЕРЕКЛАД РОБИТЬСЯ В OPENCODE' bdo \
        || fail 'у `bdo help flow` немає рядка «ПЕРЕКЛАД РОБИТЬСЯ В OPENCODE»'
    # Джерело правди про діапазон · сам валідатор, а не друга копія числа тут.
    local fetch_min fetch_max primary
    fetch_min="$(sed -n 's/.*BATCH < \([0-9]\{1,3\}\).*/\1/p' cli/api/fetch-rows.sh | sed -n '1p')"
    fetch_max="$(sed -n 's/.*BATCH > \([0-9]\{1,3\}\).*/\1/p' cli/api/fetch-rows.sh | sed -n '1p')"
    test -n "$fetch_min" && test -n "$fetch_max" \
        || fail 'не вдалося прочитати діапазон розміру пачки з cli/api/fetch-rows.sh'
    for primary in патч ручний пропозиції покращення; do
        test -f ".opencode/agents/$primary.md" || fail "немає primary-режиму $primary"
        grep -Fq 'Виконай `./bdo platform` до будь-якого іншого `./bdo`' ".opencode/agents/$primary.md" \
            || fail "$primary не має обовʼязкового platform preflight"
        grep -Fq 'Виконай `./bdo env`.' ".opencode/agents/$primary.md" \
            || fail "$primary не має обовʼязкового env preflight"
        # Власний префікс запуску ламає WSL-міст: перехід у WSL робить guard.
        grep -Fq 'Ніколи не дописуй' ".opencode/agents/$primary.md" \
            || fail "$primary не забороняє власний wsl/bash/cd префікс перед ./bdo"
        grep -Fq 'Перед кожним `mode start` повтори `./bdo env`.' ".opencode/agents/$primary.md" \
            || fail "$primary не оновлює ціль перед mode start"
        grep -Fq './bdo run drive' ".opencode/agents/$primary.md" \
            || fail "$primary не використовує run drive"
        # Розмір пачки в промпті vs діапазон, який реально приймає fetch.
        #
        # 2026-08-25 промпти лишились на `15` після того, як `fetch-rows.sh`
        # звузився до 20-100. Кожна НОВА пачка вмирала, і мовчки. Розбіжність
        # між промптом і валідатором має падати тут, а не на живому прогоні.
        local prompt_size
        prompt_size="$(sed -n 's/.*`\.\/bdo mode start [a-z]* \([0-9]\{1,3\}\) [^`]*`.*/\1/p' ".opencode/agents/$primary.md" | sed -n '1p')"
        test -n "$prompt_size" || fail "$primary не називає розміру пачки в mode start"
        test "$prompt_size" -ge "$fetch_min" && test "$prompt_size" -le "$fetch_max" \
            || fail "$primary радить пачку $prompt_size поза діапазоном fetch $fetch_min-$fetch_max"
        grep -Fq 'Власник змінює лише `.env`; CLI виконуй сам' ".opencode/agents/$primary.md" \
            || fail "$primary не містить UX-контракт власника"
        grep -Fq 'СПОЧАТКУ ВИЗНАЧ ТИП ЗАПИТУ' ".opencode/agents/$primary.md" \
            || fail "$primary не має простого маршрутизатора запитів"
        grep -Fq '«Перевір патчі», «переклади в ШІ-шар» або «скільки рядків без ШІ-перекладу» -> `./bdo patches all machine`' ".opencode/agents/$primary.md" \
            || fail "$primary не маршрутизує запит про доступні рядки через API"
        grep -Fq 'Друга колонка · номер у грі; не передавай її як snapshot.' ".opencode/agents/$primary.md" \
            || fail "$primary плутає номер патча у грі зі snapshot_id"
        grep -Fq 'Явне «перекладай патч N» уже є підтвердженням; не перепитуй.' ".opencode/agents/$primary.md" \
            || fail "$primary повторно просить уже надане підтвердження"
        grep -Fq 'reason=child_retry_budget_exhausted' ".opencode/agents/$primary.md" \
            || fail "$primary не знає terminal retry budget"
        grep -Fq 'власника не питай' ".opencode/agents/$primary.md" \
            || fail "$primary перекладає provider retry на власника"
        grep -Fq 'МЕЖА ПРОЄКТУ' ".opencode/agents/$primary.md" \
            || fail "$primary не обмежує доступ до серверного проєкту"
        grep -Fq 'docs/API_CHANGE_HANDOFF.md' ".opencode/agents/$primary.md" \
            || fail "$primary не має handoff для зміни API"
    done
    local prompt_include
    prompt_include="$(rg -n '^[[:space:]]*(@include|!include|include:)|[Пп]рочитай .*\.md' \
        .opencode/agents .opencode/agent-templates | sed -n '1p' || true)"
    test -z "$prompt_include" \
        || fail "runtime prompt залежить від зовнішнього include/read: $prompt_include"
    grep -Fq 'Переклад робиться В OPENCODE' .opencode/critical-rules.md \
        || fail 'у critical-rules.md немає правила «переклад робиться в OpenCode»'
    grep -Fq 'Межа серверного проєкту' .opencode/critical-rules.md \
        || fail 'critical-rules не обмежує серверний проєкт режимом read-only'
    grep -Fq 'API_CHANGE_HANDOFF.md' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не визначає handoff серверної API-зміни'
    grep -Fq 'найслабшу дозволену модель' AGENTS.md \
        || fail 'AGENTS.md не вимагає prompt compatibility зі слабкими моделями'
    grep -Fq 'Prompts сумісні зі слабкою моделлю' .opencode/critical-rules.md \
        || fail 'critical-rules не має контракту prompt compatibility'
    grep -Fq '§8.8 Primary і child prompts' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не визначає prompt design для слабких моделей'
    grep -Fq 'Не винось спільні правила prompt-ів у runtime include' AGENTS.md \
        || fail 'AGENTS.md не вимагає самодостатніх runtime prompts'
    grep -Fq 'Runtime prompt самодостатній' .opencode/critical-rules.md \
        || fail 'critical-rules дозволяє ненадійну runtime-композицію prompts'
    grep -Fq '§8.9 Кожен runtime primary/child prompt' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не забороняє runtime include prompts'
    local forbidden_server_command
    for forbidden_server_command in docker artisan mysql psql sqlite3; do
        grep -Fq "\"*$forbidden_server_command*\": \"deny\"" opencode.json \
            || fail "opencode.json не блокує $forbidden_server_command"
        grep -Fq "\"*$forbidden_server_command*\": \"deny\"" templates/opencode.json \
            || fail "templates/opencode.json не блокує $forbidden_server_command"
    done
    test -f docs/WINDOWS_WSL2.md || fail 'немає канонічної Windows/WSL2 інструкції'
    # Native Windows flow лишається забороненим і після появи WSL-моста: у WSL
    # виконується САМ toolkit, а міст лише доставляє туди вже дозволену команду.
    grep -Fq 'На Windows toolkit виконується ТІЛЬКИ всередині WSL2' .opencode/critical-rules.md \
        || fail 'critical-rules не забороняє native Windows flow'
    grep -Fq 'wsl.exe --cd' .opencode/plugin/translation-execution-guard.ts \
        || fail 'execution-guard втратив WSL-міст, описаний у critical-rules'
    grep -Fq '[WINDOWS_WSL2.md](WINDOWS_WSL2.md)' docs/README.md \
        || fail 'docs/README.md не посилається на Windows/WSL2 інструкцію'
    grep -Fq 'Переклад робиться В OPENCODE' AGENTS.md \
        || fail 'у AGENTS.md немає правила «переклад робиться в OpenCode»'
    grep -Fq 'Власник НЕ запускає bash/CLI-команди' AGENTS.md \
        || fail 'у AGENTS.md немає UX-контракту власника'
    grep -Fq 'gate full && ./bdo api' AGENTS.md \
        || fail 'у AGENTS.md немає фінальної gate full/API-перевірки'
    grep -Fq 'Головний UX-контракт власника' .opencode/critical-rules.md \
        || fail 'у critical-rules.md немає UX-контракту власника'
    note "4 дзеркала ідентичні; AGENTS.md: $lines/$RULE_MAP_MAX_LINES рядків"
    note 'чотири OpenCode-режими, UX-контракт і run drive присутні в prompts, правилах і help flow'
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
    } | awk '!/^docs\/plans\//' | sort -u
}

# Шлях може бути записаний відносно свого документа, кореня repo або жити в
# одному з відомих каталогів. Без цього `critical-rules.md` із `docs/README.md`
# читалось би як неіснуючий файл, хоча він лежить у `.opencode/`.
resolve_reference() {
    local ref="$1" dir="$2" candidate
    for candidate in \
        "$ref" "$dir/$ref" "$dir/plans/$ref" \
        ".opencode/$ref" ".opencode/agents/$ref" \
        "docs/$ref" "docs/plans/$ref" "scripts/$ref"
    do
        test -e "$candidate" && return 0
    done
    return 1
}

check_references() {
    step 'Посилання в документах і промптах'
    # Імена, які НЕ мусять існувати в дереві:
    #   - довідники СЕРВЕРНОГО проєкту (доступні через TRANSLATE_PROJECT_ROOT);
    #   - шаблон імені файла плану;
    #   - чотири скрипти видаленого 2026-08-22 скриптового флоу. Журнал і плани
    #     називають їх як ІСТОРІЮ, і це правильно: рішення видалити зафіксоване
    #     разом із хешем, з якого їх можна відновити. Забороняє подавати їх як
    #     команду окрема перевірка нижче.
    #
    # Один рядок навмисно: перевірка нижче робить `case " $external " in *" $ref "*`,
    # тобто шукає імʼя, оточене ПРОБІЛАМИ. Перенос рядка всередині списку робить
    # перше імʼя наступного рядка невидимим для match.
    local -r external='docs/AGENT_TRANSLATION_API.md YYYY-MM-DD_SLUG.md translate-patch.sh translate-menu.sh agent-call.sh merge-verdicts.sh'
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

    step 'Видалений скриптовий флоу не подається як робочий шлях'
    local instruction frozen hit
    # Ці файли КАЖУТЬ агентові, що робити. Після видалення скриптового флоу
    # (2026-08-22) виклик його скрипта звідси означав би команду до файла, якого
    # в репозиторії немає · тобто інструкцію, що гарантовано впаде.
    for instruction in README.md AGENTS.md .cursorrules CLAUDE.md QWEN.md \
        UI_SUBAGENT_WORKFLOW.md docs/PROJECT_OVERVIEW.md docs/README.md \
        .opencode/critical-rules.md .opencode/agents/*.md
    do
        test -f "$instruction" || continue
        for frozen in translate-patch.sh translate-menu.sh agent-call.sh merge-verdicts.sh; do
            # `|| true`: під `pipefail` порожній grep дав би ненульовий статус
            # пайпа, і `set -e` вбив би gate замість того, щоб визнати «чисто».
            hit="$(grep -n -- "\./$frozen" "$instruction" | sed -n '1p' || true)"
            test -z "$hit" || fail "$instruction подає видалений $frozen як команду: $hit"
        done
    done
    note 'жоден інструктивний файл не кличе видалені скрипти'

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
    # Порожнім мусить бути будь-який ключ, під будь-яким із прийнятих імен.
    if grep -E '^[[:space:]]*BDO_API_KEY(_PROD|_DEV|_LOCALHOST)?=.+' .env.example >/dev/null; then
        fail '.env.example містить непорожній API key'
    fi
    # Ціль прогону · одна константа, і в публічному шаблоні вона PROD: dev-стенд
    # є лише в того, хто розробляє сам проєкт.
    grep -Eq '^BDO_ENV=PROD$' .env.example || fail '.env.example не задає BDO_ENV=PROD'
    grep -Eq '^BDO_API_KEY_PROD=$' .env.example || fail '.env.example не має порожнього BDO_API_KEY_PROD'
    # Адреса production живе в коді, а не в шаблоні: константа, розмножена по
    # копіях `.env`, розходиться від описки, і жодна перевірка цього не бачить.
    grep -Eq "^readonly BDO_API_BASE_PROD_DEFAULT=" cli/system/select-env.sh \
        || fail 'cli/system/select-env.sh не має дефолта BDO_API_BASE_PROD_DEFAULT'
    if grep -Eq '^[[:space:]]*BDO_API_BASE(_PROD|_DEV)?=' .env.example; then
        fail '.env.example задає адресу API активним рядком · вона мусить бути прикладом у комментарі'
    fi
    # Шаблонів більше одного (`.env.minimal.example`), і кожен наступний · це
    # новий шанс залишити в публічному файлі справжній ключ. Тому ті самі три
    # вимоги перевіряються для КОЖНОГО `*.example`, а не лише для основного.
    local template count=0
    for template in .env*.example; do
        test -f "$template" || continue
        count=$((count + 1))
        git check-ignore -q "$template" && fail "$template помилково ігнорується · його не побачить коміт"
        if grep -E '^[[:space:]]*BDO_API_KEY(_PROD|_DEV|_LOCALHOST)?=.+' "$template" >/dev/null; then
            fail "$template містить непорожній API key"
        fi
        if grep -Eq '^[[:space:]]*BDO_API_BASE(_PROD|_DEV)?=' "$template"; then
            fail "$template задає адресу API активним рядком"
        fi
    done
    note ".env* приватні; шаблонів $count · PROD, порожній ключ, адреси в коді"
}

# Приватна інфраструктура власника не потрапляє в публічні файли (§2). Перевірка
# НАВМИСНО загальна · будь-який `.dev`-хост, · щоб не вписати сам приватний хост
# у tracked файл і не звести запобіжник на нуль.
check_private_hosts() {
    step 'Приватні хости в публічних файлах'
    local file hit
    while IFS= read -r file; do
        test -f "$file" || continue
        hit="$(grep -HnoE 'https?://[A-Za-z0-9.-]+\.dev(/|$)' "$file" 2>/dev/null | sed -n '1p' || true)"
        test -z "$hit" || fail "приватний dev-хост у публічному файлі: $hit"
    done < <(public_files)
    # Літерал розірваний конкатенацією: інакше сама фікстура є dev-хостом у
    # публічному файлі, і перевірка ловить власний вихідний код. Той самий
    # прийом уже вживається для фікстур детектора секретів нижче.
    local fixture='https://example''.dev/api'
    printf '%s\n' "$fixture" | grep -qE 'https?://[A-Za-z0-9.-]+\.dev(/|$)' \
        || fail 'negative test: детектор dev-хоста не спрацював'
    note 'dev-хостів немає; детектор перевірений фікстурою'
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
    run bash tests/command-registry.sh
    check_rules
    check_references
    check_env_contract
    check_private_hosts
    check_public_safety
    check_whitespace
}

check_shell() {
    step 'CLI layout'
    local root_shells
    root_shells="$(find . -maxdepth 1 -type f -name '*.sh' -print)"
    test -z "$root_shells" || fail "Bash-скрипти лишилися в корені: $root_shells"
    for dir in api batch prepare quality heal write run runtime audit system; do
        test -d "cli/$dir" || fail "немає cli/$dir"
    done
    note 'root *.sh: 0; cli/** категорії: 10'

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

    step 'Pipeline unit contracts'
    run php tests/pipeline-unit.php
    run php tests/pipeline-faults.php
    run bash tests/batch-summary.sh
    run bash tests/model-runtime-materialization.sh
    run bash tests/smoke-envelope.sh
    run bash tests/drive-memory-layers.sh
    run bash tests/judge-flow.sh
    run bash tests/patch-argument.sh
    run bash tests/pre-push-attribution.sh
    run bash tests/run-resume.sh
    run bash tests/run-target-env.sh
    run bash tests/http-retry.sh
    run bash tests/rotation.sh
    run bash tests/no-silent-failures.sh
    run bash tests/quarantine-recovery.sh
}

check_agents() {
    step 'OpenCode agents і routing guard'
    have jq || fail 'jq недоступний'
    run bash .opencode/validate-translation-agents.sh
    jq -e . opencode.json >/dev/null || fail 'opencode.json невалідний JSON'
    run node --experimental-strip-types tests/routing-guard.mjs
    run node --experimental-strip-types tests/execution-guard.mjs
    run node --experimental-strip-types tests/result-writer.mjs
    run node --experimental-strip-types tests/child-contract.mjs
}

check_runtime() { run ./bdo runtime; }
# Ціль НЕ підставляється: її задає BDO_ENV у `.env`, і нав'язати тут `local`
# означало б показати результат не того середовища, у якому працює прогін.
check_api() { run ./bdo api; }

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
    run ./bdo paths
    run ./bdo platform
    # Ціль прогону першою: агент, який не знає середовища, або питає власника
    # про те, що написано у файлі, або йде в чуже. Ключ тут не друкується.
    step 'Ціль прогону'
    if [ -f .env ] || [ -n "${TRANSLATE_ENV_FILE:-}" ]; then
        bash ./cli/system/select-env.sh 2>&1 >/dev/null | sed 's/^/   /'
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
