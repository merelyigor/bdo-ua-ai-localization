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
    grep -Fq '§4.2 `git push` виконує ВИКЛЮЧНО власник' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §4.2 про push"
    # Порядок кроків тримає код, а не модель · це головне рішення переходу
    # 2026-09-04, і воно не має права зникнути з правил при переписуванні.
    grep -Fq 'ПОРЯДОК КРОКІВ ТРИМАЄ КОД, А НЕ МОДЕЛЬ' AGENTS.md \
        || fail 'AGENTS.md не фіксує, що порядок кроків тримає драйвер, а не модель'
    grep -Fq 'Payload роль отримує ФАЙЛОМ' AGENTS.md \
        || fail 'AGENTS.md не забороняє переказувати payload'
    grep -Fq 'Переклад запускається ЛИШЕ через' AGENTS.md \
        || fail 'AGENTS.md не забороняє обхідні шляхи запуску перекладу'
    # Розмір пачки зафіксовано на 50 (рішення власника 2026-08-28) і це стеля
    # запису API (`/me` -> `max_items`). Джерело правди · валідатор fetch.
    local fetch_min fetch_max tui_size
    fetch_min="$(sed -n 's/.*BATCH < \([0-9]\{1,3\}\).*/\1/p' cli/api/fetch-rows.sh | sed -n '1p')"
    fetch_max="$(sed -n 's/.*BATCH > \([0-9]\{1,3\}\).*/\1/p' cli/api/fetch-rows.sh | sed -n '1p')"
    test -n "$fetch_min" && test -n "$fetch_max" \
        || fail 'не вдалося прочитати діапазон розміру пачки з cli/api/fetch-rows.sh'
    tui_size="$(sed -n 's/.*mode start "\$key" \([0-9]\{1,3\}\).*/\1/p' bin/tui.sh | sed -n '1p')"
    test -n "$tui_size" || fail 'bin/tui.sh не називає розміру пачки'
    test "$tui_size" -ge "$fetch_min" && test "$tui_size" -le "$fetch_max" \
        || fail "TUI бере пачку $tui_size поза діапазоном fetch $fetch_min-$fetch_max"
    test "$tui_size" -eq 50 || fail "TUI бере пачку $tui_size; зафіксовано рівно 50"
    # Драйвер мусить починати наступну пачку САМ: зупинка з питанням «продовжити?»
    # була найдорожчою звичкою диригента (D25, D34).
    grep -Fq 'Наступну пачку відкриваємо САМІ' cli/run/run-loop.sh \
        || fail 'драйвер більше не починає наступну пачку самостійно'
    local prompt_include
    prompt_include="$(rg -n '^[[:space:]]*(@include|!include|include:)|[Пп]рочитай .*\.md' \
        roles | sed -n '1p' || true)"
    test -z "$prompt_include" \
        || fail "prompt ролі залежить від зовнішнього include/read: $prompt_include"
    grep -Fq 'API_CHANGE_HANDOFF.md' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не визначає handoff серверної API-зміни'
    # Рішення власника 2026-09-04: промпт для серверного боку дається В ЧАТІ
    # повним текстом. Посилання на файл змушує власника шукати блок і гадати,
    # кому його віддати · саме так і сталося з D54.
    grep -Fq 'потрібна правка API на серверному боці' AGENTS.md \
        || fail 'AGENTS.md не вимагає прямо називати потребу правки API на сервері'
    grep -Fq 'ГОТОВИЙ промпт тут же в' AGENTS.md \
        || fail 'AGENTS.md не вимагає давати промпт для серверного агента прямо в чаті'
    grep -Fq '§7.6 Коли потрібна зміна саме в API на серверному боці' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не фіксує правило про промпт серверної API-зміни в чаті'
    grep -Fq 'найслабшу дозволену модель' AGENTS.md \
        || fail 'AGENTS.md не вимагає prompt compatibility зі слабкими моделями'
    # Рішення власника 2026-08-28: знання моделі про гру є ресурсом, але не
    # джерелом відповідника. Без другої половини правило небезпечне.
    # Найдорожчий клас: зіпсувати дані, які вже написала людина.
    grep -Fq 'відсутність поля у відповіді означає «невідомо», а не «порожньо»' AGENTS.md \
        || fail 'AGENTS.md не забороняє приймати відсутність поля за порожнє значення'
    grep -Fq 'phpstorm lint_files' AGENTS.md \
        || fail 'AGENTS.md не вимагає інспекції IDE після зміни коду'
    grep -Fq 'phpstorm lint_files' docs/CHECKLIST.md \
        || fail 'чекліст не називає інспекцію IDE'
    grep -Fq 'офіційна українська локалізація Black Desert Online' AGENTS.md \
        || fail 'AGENTS.md не фіксує рамку задачі для child'
    grep -Fq '§8.14 Prompt ролі задає рамку задачі' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не фіксує рамку задачі ролі'
    grep -Fq '§8.11 Prompts ролей розраховувати' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не визначає prompt design для слабких моделей'
    grep -Fq 'Не винось спільні правила prompt-ів у runtime include' AGENTS.md \
        || fail 'AGENTS.md не вимагає самодостатніх runtime prompts'
    # 2026-08-27: власник зафіксував курс на локальні моделі. Еталон мусить бути
    # НАЗВАНИЙ, інакше «найслабша модель» щоразу означає ту, яка зараз під рукою.
    grep -Fq 'config/roles.json`, типова `qwen3.6:35b-a3b-mtp-q4_K_M`' AGENTS.md \
        || fail 'AGENTS.md не називає еталонну локальну модель для промптів'
    grep -Fq '§8.13 Еталонна «найслабша модель» названа' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не фіксує еталонну модель промптів'
    grep -Fq 'Режим більше не є промптом' AGENTS.md \
        || fail 'AGENTS.md не фіксує, що режим став конфігурацією прогону'
    # Клас відмови «тихий збій і фіктивна перевірка» коштував двох діб розбору
    # 2026-08-25…27. Норма не має права зникнути при наступному переписуванні.
    grep -Fq 'Тихий збій і фіктивна перевірка' AGENTS.md \
        || fail 'AGENTS.md не забороняє тихий збій'
    grep -Fq 'самим шляхом, що й робота' AGENTS.md \
        || fail 'AGENTS.md не вимагає, щоб перевірка йшла шляхом роботи'
    grep -Fq '§12 Клас відмови' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не описує клас тихого збою'
    grep -Fq '§12 довідника' AGENTS.md \
        || fail 'карта правил не веде до §12'
    grep -Fq '§8.12 Кожен `roles/<роль>.md` є повним' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не забороняє runtime include prompts'
    # Межа серверного проєкту: раніше її тримали `deny`-правила в конфізі
    # OpenCode (docker, artisan, mysql, psql, sqlite3). Конфігу більше немає, і
    # заміняти його текстом у промпті було б слабшою межею · тому перевіряємо
    # ІНШЕ й сильніше: у конвеєрі взагалі немає поверхні для довільної команди.
    #
    # Драйвер виконує лише `./bdo` і `cli/model/client.php`; рядок `command` із
    # конверта він НЕ виконує (це перевірено `tests/driver-loop.sh`). Модель
    # інструментів не має: `cli/model/client.php` шле повідомлення й читає
    # відповідь, і нічого більше.
    grep -qE '\b(eval|source|bash -c|sh -c)\b' cli/run/run-loop.sh \
        && fail 'драйвер отримав спосіб виконати довільний рядок'
    grep -qE '\b(exec|shell_exec|system|passthru|popen|proc_open)\s*\(' cli/model/client.php \
        && fail 'клієнт моделі отримав спосіб виконати довільну команду'
    grep -Fq 'Зовнішній серверний проєкт · лише read-only довідник' AGENTS.md \
        || fail 'AGENTS.md не обмежує серверний проєкт режимом read-only'
    test -f docs/WINDOWS_WSL2.md || fail 'немає канонічної Windows/WSL2 інструкції'
    # Native Windows flow лишається забороненим і після появи WSL-моста: у WSL
    # виконується САМ toolkit, а міст лише доставляє туди вже дозволену команду.
    grep -Fq '[WINDOWS_WSL2.md](WINDOWS_WSL2.md)' docs/README.md \
        || fail 'docs/README.md не посилається на Windows/WSL2 інструкцію'
    grep -Fq 'Власник НЕ складає команд' AGENTS.md \
        || fail 'у AGENTS.md немає UX-контракту власника'
    grep -Fq 'gate full && ./bdo api' AGENTS.md \
        || fail 'у AGENTS.md немає фінальної gate full/API-перевірки'
    note "4 дзеркала ідентичні; AGENTS.md: $lines/$RULE_MAP_MAX_LINES рядків"
    note 'UX-контракт, драйвер і межа payload присутні в правилах'
    note 'правило про push присутнє в карті правил і нормативі'
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
    # Голе імʼя файла з дерева проєкту (`term-notes-submit.sh` із `cli/api/`).
    # Шукаємо серед відстежуваних файлів, а не тримаємо список каталогів:
    # каталог `cli/**` росте, і список довелося б доповнювати щоразу.
    case "$ref" in
        */*) ;;
        *) git ls-files -- "*/$ref" | grep -q . && return 0 ;;
    esac
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
    # `inspect.sh` · бінарник JetBrains поза репозиторієм: він згадується в
    # документації як інструмент, а не як файл проєкту.
    #
    # Один рядок навмисно: перевірка нижче робить `case " $external " in *" $ref "*`,
    # тобто шукає імʼя, оточене ПРОБІЛАМИ. Перенос рядка всередині списку робить
    # перше імʼя наступного рядка невидимим для match.
    local -r external='docs/AGENT_TRANSLATION_API.md YYYY-MM-DD_SLUG.md translate-patch.sh translate-menu.sh agent-call.sh merge-verdicts.sh inspect.sh'
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
        docs/PROJECT_OVERVIEW.md docs/README.md roles/*.md
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
    run bash tests/drive-memory-layers.sh
    run bash tests/judge-flow.sh
    run bash tests/patch-argument.sh
    run bash tests/pre-push-attribution.sh
    run bash tests/commit-version-guard.sh
    run bash tests/run-resume.sh
    run bash tests/run-target-env.sh
    run bash tests/http-retry.sh
    run bash tests/rotation.sh
    run bash tests/no-silent-failures.sh
    run bash tests/quarantine-recovery.sh
    run bash tests/worker-reference.sh
    run bash tests/schema-provider-compat.sh
    run bash tests/mechanical-final-check.sh
    run bash tests/domain-filter.sh
    run bash tests/audit-response-shape.sh
    run bash tests/mechanical-before-qa.sh
    run bash tests/heal-attempts.sh
    run bash tests/payload-shared-examples.sh
    run bash tests/registry-hygiene.sh
    run bash tests/glossary-listing.sh
    run bash tests/write-channel-rights.sh
}

# Ролі й драйвер · те, що замінило шар OpenCode.
#
# Раніше тут перевірялись плагіни, промпти диригента й конфіг чужого застосунку.
# Нічого з цього більше немає: порядок кроків тримає `cli/run/run-loop.sh`,
# моделі викликає `cli/model/client.php`, а ролі описані в `config/roles.json`
# і `roles/*.md`. Перевіряємо саме цей контракт · роль без промпта або без
# схеми зупинить пачку так само мовчки, як колись неоголошена модель.
check_agents() {
    step 'Ролі конвеєра й драйвер'
    have jq || fail 'jq недоступний'
    jq -e . config/roles.json >/dev/null || fail 'config/roles.json невалідний JSON'
    local role schema
    for role in $(jq -r '.roles | keys[]' config/roles.json); do
        test -f "roles/$role.md" || fail "роль $role не має промпта roles/$role.md"
        test -s "roles/$role.md" || fail "промпт roles/$role.md порожній"
        schema="$(jq -r --arg r "$role" '.roles[$r].schema // "none"' config/roles.json)"
        case "$schema" in
            response|qa|none) ;;
            file:*) test -f "${schema#file:}" \
                || fail "роль $role посилається на відсутню схему ${schema#file:}" ;;
            *) fail "роль $role має невідомий тип схеми: $schema" ;;
        esac
        # Рамка «офіційна українська локалізація BDO» · рішення власника
        # 2026-08-28. Без неї модель бере відповідник із памʼяті про чужу
        # локалізацію, і саме звідти беруться русизми.
        grep -Fq 'Black Desert Online' "roles/$role.md" \
            || fail "промпт $role втратив рамку «офіційна українська локалізація Black Desert Online»"
    done
    note "ролей: $(jq -r '.roles | length' config/roles.json), у кожної є промпт і схема"
    # Кожна роль, яку вміє віддати рушій, мусить бути в реєстрі · інакше драйвер
    # зупиниться на живій пачці з «unknown_role».
    local engine_roles missing
    # Беремо аргумент функції `child <стан> <роль> …`, а не будь-яку згадку
    # рядка `translation-*`: інакше коментар про давно видалений плагін валить
    # gate як «невідому роль».
    engine_roles="$(grep -oE '^[[:space:]]*(child|transition [a-z_]+; child) [a-z_]+ translation-[a-z]+' cli/run/run-drive.sh \
        | grep -oE 'translation-[a-z]+' | sort -u)"
    test -n "$engine_roles" || fail 'у cli/run/run-drive.sh не знайдено жодної ролі'
    missing=""
    for role in $engine_roles; do
        jq -e --arg r "$role" '.roles[$r]' config/roles.json >/dev/null || missing="$missing $role"
    done
    test -z "$missing" || fail "рушій кличе ролі, яких немає в config/roles.json:$missing"
    run bash tests/model-client.sh
    run bash tests/driver-loop.sh
    run bash tests/tui.sh
}

check_runtime() { run ./bdo runtime; }
# Ціль НЕ підставляється: її задає BDO_ENV у `.env`, і нав'язати тут `local`
# означало б показати результат не того середовища, у якому працює прогін.
check_api() {
    run ./bdo api
    # Перелік категорій зашитий у RunSpec, а джерелом правди є API. `market`
    # забули з першого дня, і `mode start ... market` падав би «Невідома
    # категорія» на реальному домені. Дрейф має падати тут, а не на прогоні.
    step 'Категорії: код проти живого API'
    # Джерело правди · `/taxonomy`, а не один патч: у `patch/summary` видно лише
    # ті домени, які трапились у ЦЬОМУ патчі. Перша версія перевірки брала
    # активний патч і не помітила відсутнього `market`, бо в патчі 6 його немає.
    local missing
    missing="$(bash -c '
        source cli/system/select-env.sh >/dev/null 2>&1
        curl -sS -H "X-API-Key: $BDO_API_KEY" "$BDO_API_BASE/taxonomy" \
            | php -r "
                require \"lib/autoload.php\";
                \$d = json_decode((string) file_get_contents(\"php://stdin\"), true);
                \$api = array_values(\$d[\"data\"][\"domains\"] ?? []);
                echo implode(\" \", array_diff(\$api, Bdo\\Translate\\Pipeline\\RunSpec::domains()));
            "')"
    test -z "$missing" || fail "API знає категорії, яких немає в RunSpec::DOMAINS: $missing"
    note "перелік категорій збігається з API"
}

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
