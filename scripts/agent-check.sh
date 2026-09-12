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
# Стеля піднята з 201 до 220 рішенням власника 2026-09-12 разом зі зміною
# моделі роботи: карта правил узяла на себе контракт делегування (спосіб
# питається перед роботою, думання не делегується, коміт лише з головної
# сесії). Це свідоме рішення, а не підгонка порога під червону перевірку ·
# старий блок ролі ВИКОНАВЦЯ з карти прибрано тим самим заходом.
readonly RULE_MAP_MAX_LINES=220

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
    } | awk '!/(^|\/)(output|state|legacy|node_modules)(\/|$)/ && !/(^|\/)\.env($|\.)/' | sort -u
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
    grep -Fq 'force-push і теги · власник' AGENTS.md \
        || fail 'у AGENTS.md немає межі push: force-push лишається за власником'
    grep -Fq '§4.2 `git push` ДОЗВОЛЕНИЙ агенту' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §4.2 про push"
    # Порядок кроків тримає код, а не модель · це головне рішення переходу
    # 2026-09-04, і воно не має права зникнути з правил при переписуванні.
    grep -Fq 'ПОРЯДОК КРОКІВ ТРИМАЄ КОД, А НЕ МОДЕЛЬ' AGENTS.md \
        || fail 'AGENTS.md не фіксує, що порядок кроків тримає драйвер, а не модель'
    grep -Fq 'Payload роль отримує ФАЙЛОМ' AGENTS.md \
        || fail 'AGENTS.md не забороняє переказувати payload'
    grep -Fq 'Переклад запускається ЛИШЕ через' AGENTS.md \
        || fail 'AGENTS.md не забороняє обхідні шляхи запуску перекладу'
    # Зміна вектора 2026-09-04: основною поверхнею власника став браузер. Правило
    # мусить стояти в правилах, бо саме їх агент читає на початку сесії · інакше
    # наступна сесія знову вважатиме вікно в терміналі головним інтерфейсом.
    grep -Fq 'ОСНОВНИЙ інтерфейс · браузер' AGENTS.md \
        || fail 'AGENTS.md не називає браузер основним інтерфейсом власника'
    grep -Fq 'Кнопка сторінки не має власної логіки' AGENTS.md \
        || fail 'AGENTS.md не фіксує, що дія сторінки є командою з реєстру'
    grep -Fq 'Сторінку перевіряй СТАНОМ DOM' AGENTS.md \
        || fail 'AGENTS.md не фіксує спосіб перевірки сторінки'
    # Стану НЕ ДОСИТЬ · вимога власника 2026-09-06. Два дефекти вікна живого
    # друку поспіль (сирий JSON, друк порціями з утратою початку · D83) знайшло
    # око власника: обидва живуть у темпі показу, якого в знімку DOM немає.
    grep -Fq 'перевіряй ВІЗУАЛЬНО' AGENTS.md \
        || fail 'AGENTS.md не вимагає ДОДАТКОВОЇ візуальної перевірки видимих змін'
    # Дозвіл на малу пачку існує РАЗОМ зі своєю межею: без неї наступна сесія
    # почне міряти поведінку моделі на пʼяти рядках і повторить D82.
    grep -Fq 'НАЙМЕНШУ пачку' AGENTS.md \
        || fail 'AGENTS.md не дозволяє малу пачку для перевірки механіки'
    grep -Fq 'РОБОЧОМУ розмірі 50' AGENTS.md \
        || fail 'AGENTS.md не називає межі малої пачки · поведінку моделі міряють на 50'
    grep -Fq '§14 Браузерний інтерфейс як основна поверхня власника' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §14 про браузерний інтерфейс"
    # Розмір пачки зафіксовано на 50 (рішення власника 2026-08-28) і це стеля
    # запису API (`/me` -> `max_items`). Джерело правди · валідатор fetch.
    local fetch_min fetch_max plan_size composers
    fetch_min="$(php -r 'require $argv[1]; echo Bdo\Translate\Cli\Command\Api\FetchRowsCommand::MIN_BATCH;' lib/autoload.php 2>/dev/null || true)"
    fetch_max="$(php -r 'require $argv[1]; echo Bdo\Translate\Cli\Command\Api\FetchRowsCommand::MAX_BATCH;' lib/autoload.php 2>/dev/null || true)"
    test -n "$fetch_min" && test -n "$fetch_max" \
        || fail 'не вдалося прочитати діапазон розміру пачки з живої FetchRowsCommand'
    # Розмір пачки бере ПЛАНУВАЛЬНИК, а не поверхня: після 2026-09-05 і сторінка,
    # і вікно просять план у `Bdo\Translate\Run\Actions`, тому єдине число живе
    # там. Раніше воно читалось із `bin/tui.sh` · тобто з однієї з двох поверхонь.
    plan_size="$(sed -n 's/.*BATCH_SIZE = \([0-9]\{1,3\}\).*/\1/p' lib/Run/Actions.php | sed -n '1p')"
    test -n "$plan_size" || fail 'lib/Run/Actions.php не називає розміру пачки'
    test "$plan_size" -ge "$fetch_min" && test "$plan_size" -le "$fetch_max" \
        || fail "планувальник бере пачку $plan_size поза діапазоном fetch $fetch_min-$fetch_max"
    test "$plan_size" -eq 50 || fail "планувальник бере пачку $plan_size; зафіксовано рівно 50"
    # МЕЖА ПРОТИ ДВОХ ПРАВД. `mode start` кличуть рівно два місця, і кожне з них
    # названо тут разом із причиною:
    #   lib/Run/Actions.php   · СКЛАДАЄ аргументи з вибору людини (обидві
    #                           поверхні · сторінка й вікно · просять план у нього);
    #   lib/Cli/Command/Run/RunLoopCommand.php · native loop opens the next
    #                           batch from a validated envelope;
    #   lib/Run/Actions.php   · composes the operator-selected start plan.
    # Frozen cli/run/run-loop.sh is rollback only and is excluded from this
    # live-source scan, so it cannot hide a missing native composer.
    # Третє місце означає другу правду: доки їх було два, вони розходилися тихо.
    composers="$(
        {
            rg -l -e 'mode.*start' lib/Run/Actions.php >/dev/null 2>&1 && printf './lib/Run/Actions.php\n'
            rg -l -e 'run-mode' lib/Cli/Command/Run/RunLoopCommand.php >/dev/null 2>&1 && printf './lib/Cli/Command/Run/RunLoopCommand.php\n'
        } | sort -u | tr '\n' ' '
    )"
    test "$composers" = './lib/Cli/Command/Run/RunLoopCommand.php ./lib/Run/Actions.php ' \
        || fail "\`mode start\` кличе не той набір місць: [$composers]"
    # Розмір пачки поруч із командою · лише в планувальнику. Друга константа
    # лишила б драйвер на старому значенні після зміни розміру.
    local hardcoded
    # Шукаємо лише там, де код ВИКОНУЄТЬСЯ: `cli`, `bin`, `lib`, `web`.
    # Довідка в `./bdo` і приклади в `.md` є текстом для людини, і їхню
    # відповідність реєстру тримає `tests/command-registry.sh`.
    hardcoded="$(rg -n --glob '!lib/Run/Actions.php' \
        'mode.{0,12}start.{0,12}\b50\b' cli bin lib web 2>/dev/null | sed -n '1p' || true)"
    test -z "$hardcoded" \
        || fail "розмір пачки прописаний поруч із командою поза планувальником: $hardcoded"
    grep -Fq 'cli/run/plan-args.php' bin/tui.sh \
        || fail 'вікно в терміналі не бере план у спільного планувальника'
    # `.gitattributes` тримає кінці рядків, і його вміст не має права зникнути:
    # без правила LF клон на Windows дає CRLF у кожному `.sh`, і всередині WSL
    # скрипт падає з `\r: command not found`, а `.env` віддає ключ із невидимим
    # `\r`. 2026-09-05 цей файл був ПЕРЕЗАПИСАНИЙ під час додавання `bdo.bat` ·
    # перевірки на нього не існувало.
    test -f .gitattributes || fail 'немає .gitattributes · кінці рядків віддані налаштуванням машини'
    grep -qE '^\*\.sh( |\t)+text( |\t)+eol=lf' .gitattributes \
        || fail '.gitattributes не примушує LF для *.sh · у WSL такий скрипт падає на \r'
    grep -qE '^\*\.bat( |\t)+text( |\t)+eol=crlf' .gitattributes \
        || fail '.gitattributes не примушує CRLF для *.bat · cmd ламається на LF'
    # Документація не має права ВЧИТИ помилки, яка вже коштувала прогону:
    # `mode start патч` · це рівно D50. Приклад із українським ключем жив у
    # `README.md` і `WORKFLOW.md` навіть після того, як код виправили.
    local ua_key
    ua_key="$(rg -n 'mode start (патч|ручний|пропозиції|покращення)' \
        --glob '!state/**' --glob '!docs/plans/DEFECTS.md' --glob '!tests/**' \
        --glob '!scripts/agent-check.sh' . 2>/dev/null | sed -n '1p' || true)"
    test -z "$ua_key" \
        || fail "приклад команди з українським ключем режиму (це і є D50): $ua_key"
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
    # Термінал як інструмент: правило про PTY мусить бути в карті й у нормативі,
    # інакше наступна сесія знову шукатиме MCP для термінала (§13.2).
    grep -Fq '§13 довідника' AGENTS.md \
        || fail 'карта правил не веде до §13 (термінал, PTY, запис екрана)'
    grep -Fq 'tests/tui-live.sh' AGENTS.md \
        || fail 'карта правил не називає живу перевірку вікна в PTY'
    grep -Fq '§13.1 Вікно перевіряється в справжньому PTY' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не вимагає перевірки вікна в справжньому PTY'
    grep -Fq '§13.6 GIF є документацією, а не доказом' docs/AI_AGENT_RULES_REFERENCE.md \
        || fail 'норматив не відділяє запис екрана від доказу'
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
        "docs/$ref" "docs/plans/$ref" "scripts/$ref" "roles/$ref"
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
    # ПРАВИЛО: `/tmp/*` із verification evidence не є repo reference.
    # САБОТАЖ: прибрати цей skip; fixture з гарантовано відсутнім `/tmp/*.md` мусить зробити `gate docs` червоним.
    # Три останні · документи знятого 2026-09-12 флоу двох агентів. Записи
    # `docs/verification/6.4.2` і `6.4.3` називають їх як ІСТОРІЮ саботажів,
    # і це правильно: відновлюються з тега `ai-workflow-final`. Перелік
    # МІНІМАЛЬНИЙ · рівно ті три посилання, що справді трапляються; `ROLES.md`
    # і `REVIEW.md` сюди не додані навмисно, бо загальне імʼя в skip-списку
    # маскує майбутнє справді відсутнє посилання з тією самою назвою.
    local -r external='docs/AGENT_TRANSLATION_API.md YYYY-MM-DD_SLUG.md translate-patch.sh translate-menu.sh agent-call.sh merge-verdicts.sh inspect.sh HANDOFF.md PROMPTS.md docs/ai-workflow/HANDOFF.md'
    local doc ref plan base checked=0
    while IFS= read -r doc; do
        test -f "$doc" || continue
        while IFS= read -r ref; do
            case "$ref" in
                /tmp/*) continue ;;
            esac
            case " $external " in *" $ref "*) continue ;; esac
            resolve_reference "$ref" "$(dirname "$doc")" \
                || fail "$doc посилається на відсутній $ref"
            checked=$((checked + 1))
        done < <(perl -ne 'while (/`([A-Za-z0-9_.\/-]+\.(?:md|sh|ts|php))`/g) { print "$1\n" }' "$doc" | sort -u)
    done < <(linked_docs)
    note "перевірено $checked посилань у документах і промптах"

    # Markdown-посилання `[текст](шлях.md)` мусить вести туди, КУДИ вказує.
    #
    # Перевірка вище звіряє лише імʼя файла в зворотних лапках, тому
    # `](active/план.md)` на план, який переїхав у `done/`, лишався зеленим:
    # файл із таким іменем у репозиторії є. Для людини це битий клік, для
    # агента · шлях, за яким нічого немає. 2026-09-04 таких було пʼять.
    local broken
    broken="$(php -r '
    $bad = [];
    foreach (explode("\n", trim(shell_exec("git ls-files \"*.md\""))) as $doc) {
        if ($doc === "") { continue; }
        // Файл може бути в індексі git і вже видалений у робочій теці · саме
        // так виглядає закритий план до коміту. Попередження PHP тут гірше за
        // саму ситуацію: воно потрапляє у вивід і перетворює порожній перелік
        // на «посилання ведуть у нікуди» без жодного посилання.
        if (! is_file($doc)) { continue; }
        $dir = dirname($doc);
        preg_match_all("~\]\(([^)#][^)]*\.md)\)~", (string) file_get_contents($doc), $m);
        foreach ($m[1] as $target) {
            if (str_starts_with($target, "http")) { continue; }
            $full = $dir === "." ? $target : $dir."/".$target;
            if (! file_exists($full)) { $bad[] = $doc." -> ".$target; }
        }
    }
    echo implode("\n", $bad);
    ')"
    test -z "$broken" || fail "markdown-посилання ведуть у нікуди: $broken"
    note 'markdown-посилання ведуть на наявні файли'

    # Кожен документ мусить бути ЗНАЙДЕНИЙ із навігації `docs/README.md`.
    #
    # Документ, на який нізвідки немає посилання, існує лише для того, хто про
    # нього вже знає · тобто для автора. Для власника й нового агента його
    # немає взагалі, і робота дублюється.
    local unlisted
    unlisted="$(php -r '
    $nav = (string) file_get_contents("docs/README.md");
    $skip = ["README.md" => 1, "AGENTS.md" => 1, "CLAUDE.md" => 1, "QWEN.md" => 1];
    $out = [];
    foreach (array_merge(glob("docs/*.md"), glob("*.md")) as $doc) {
        $name = basename($doc);
        if (isset($skip[$name]) || str_contains($nav, $name)) { continue; }
        $out[] = $doc;
    }
    echo implode(" ", $out);
    ')"
    test -z "$unlisted" || fail "документи без посилання з docs/README.md: $unlisted"
    note 'кожен документ знайдуваний із навігації'

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
    grep -qE 'https?://[A-Za-z0-9.-]+\.dev(/|$)' <<<"$fixture" \
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
    grep -Eq "$pattern" <<<"$sample" || fail 'negative test: API key pattern не спрацював'
    sample='$2b$12$''AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    grep -Eq "$pattern" <<<"$sample" || fail 'negative test: credential hash pattern не спрацював'
    sample='identity_hash=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    if grep -Eq "$pattern" <<<"$sample"; then
        fail 'negative test: technical identity_hash помилково класифікований як credential'
    fi
    note 'secret detector ловить key/hash fixtures і дозволяє technical identity_hash'
}

# ЦІЛІСНІСТЬ ДИЗАЙНУ · §15. Вимога власника 2026-09-07: дизайн мусить лишатись
# одним продуктом після всіх майбутніх правок, і тримати це має код.
#
# Дизайн ламається не переробками, а дрібними доповненнями: кожен агент додає
# «одну маленьку кнопку» зі своїм відтінком, і через десяток правок екран
# перестає виглядати цілісно. Тому перевіряються рівно ті три речі, які
# розповзаються першими: КОЛІР, РОЗМІР ТЕКСТУ і ВИГЛЯД КНОПКИ.
check_design() {
    step 'Цілісність дизайну (§15)'
    local css='web/app.css'
    test -f "$css" || fail "немає $css"

    # §15.1 Палітра одна. Кольори живуть у блоках `:root`; будь-де інде · лише
    # токени. Літерал на місці використання ламає ТЕМНУ тему тихо: світла
    # виглядає нормально, і побачити це можна тільки оком.
    local hex
    hex="$(rg -n --glob 'web/*.html' -e '#[0-9a-fA-F]{3,8}\b' -e '\brgba?\(' -e '\bhsla?\(' \
        2>/dev/null | sed -n '1p' || true)"
    test -z "$hex" \
        || fail "колір-літерал у розмітці замість var(--токен) · темна тема зламається тихо: $hex"

    # У самому CSS літерали дозволені ЛИШЕ в межах блоків `:root`. Рахуємо
    # рядки поза ними: вихід із блоку · рядок, що закриває дужку.
    local stray
    stray="$(awk '
        /:root[[:space:]]*\{/ { inroot = 1 }
        inroot && /^[[:space:]]*\}/ { inroot = 0; next }
        !inroot && /#[0-9a-fA-F]{3}/ { print NR": "$0; exit }
        !inroot && /rgba?\(/ { print NR": "$0; exit }
    ' "$css")"
    test -z "$stray" \
        || fail "колір поза :root у $css · палітра розʼїхалась на дві: $stray"

    # §15.2 Типографіка зі шкали. Четвертий рівень тексту, якого немає в
    # жодному прототипі, зʼявляється саме так · одним `font-size:14px`.
    local size
    size="$(rg -o --glob 'web/*.html' 'font-size:[0-9]+px' 2>/dev/null \
        | grep -vE 'font-size:(11|12|13)px' | sed -n '1p' || true)"
    test -z "$size" \
        || fail "розмір тексту поза шкалою 11/12/13 у розмітці: $size"

    # §15.3 Кнопка бере НАЯВНИЙ клас. Інлайн-фон, рамка чи радіус на кнопці ·
    # це шоста різновидність кнопки, яку потім ніхто не приведе до ладу.
    local painted
    painted="$(rg -n --glob 'web/*.html' \
        '<(button|a)[^>]*style="[^"]*(background|border|border-radius):' 2>/dev/null \
        | sed -n '1p' || true)"
    test -z "$painted" \
        || fail "кнопка перефарбована інлайн замість класу з app.css: $painted"

    # Класи вигляду мусять ІСНУВАТИ в CSS. Клас-привид не падає ніде: кнопка
    # просто виглядає базовою, і різницю видно лише оком.
    local klass
    # МЕЖА СЕЛЕКТОРА ОБОВʼЯЗКОВА. `grep -F .btn-danger` знаходить і
    # `.btn-dangerX`, тому перевірка на підрядку доводила б нуль · саботаж
    # перейменуванням класу вона пропускала.
    for klass in btn-primary btn-danger chip pill as-button; do
        grep -qE "\.${klass}([^a-zA-Z0-9_-]|$)" "$css" \
            || fail "клас .$klass використовується, але в $css його немає"
    done

    # §15.4 Темна тема не другорядна: кожен токен мусить бути в ОБОХ блоках.
    local light dark missing
    # Беремо лише КОЛІРНІ токени: `--mono` і `--sans` є шрифтами, і дублювати
    # їх у темній темі не треба · вимога цього не стосується.
    light="$(awk '/^:root\{/,/^\}/' "$css" \
        | grep -oE '\-\-[a-z0-9-]+:[^;]*' \
        | grep -E ':[[:space:]]*(#|rgba?\()' \
        | sed -E 's/:.*//' | sort -u)"
    dark="$(awk '/prefers-color-scheme:dark/,0' "$css" | grep -oE '\-\-[a-z0-9-]+:' | tr -d ':' | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "$light") <(printf '%s\n' "$dark") | sed -n '1p')"
    test -z "$missing" \
        || fail "токен $missing є лише у світлій темі · у темній елемент буде іншого кольору"

    # §16 БРАУЗЕР ВЛАСНИКА · обовʼязкова поверхня перевірки. MCP мусить бути
    # описаний у ПРОЄКТІ: без цього наступна сесія перевірятиме сторінку в
    # чужому браузері з чистим профілем, де немає ні токена власника, ні
    # відкритої вкладки, у якій він тестує переклад.
    test -f .mcp.json || fail 'немає .mcp.json · агент не дістане Chrome власника (§16.1)'
    if have php; then
        php -r '
            $d = json_decode((string) file_get_contents(".mcp.json"), true);
            $srv = $d["mcpServers"]["chrome-devtools"] ?? null;
            if (! is_array($srv)) {
                fwrite(STDERR, "у .mcp.json немає сервера chrome-devtools
");
                exit(1);
            }
            $args = implode(" ", (array) ($srv["args"] ?? []));
            if (! str_contains($args, "chrome-devtools-mcp")) {
                fwrite(STDERR, "chrome-devtools вказує не на chrome-devtools-mcp: $args
");
                exit(1);
            }
            // БЕЗ --autoConnect MCP підіймає СВІЙ Chrome із чистим профілем ·
            // тобто мовчки перестає бути браузером власника (§16.2).
            if (! str_contains($args, "--autoConnect")) {
                fwrite(STDERR, "chrome-devtools без --autoConnect · візьме чужий Chrome, а не вкладку власника
");
                exit(1);
            }
        ' || fail 'конфіг MCP chrome-devtools неправильний (§16)'
    fi
    grep -Fq 'вкладці власника' AGENTS.md \
        || fail 'AGENTS.md не вимагає перевіряти у вкладці власника (§16)'
    # Стан під'єднання мусить питатись КОМАНДОЮ · інакше кожна сесія знову
    # витрачає спроби на діагностику, а `curl` до 9222 вводить в оману (§16.6).
    test -x cli/system/browser-check.sh \
        || fail 'немає cli/system/browser-check.sh · стан під\x27єднання до браузера власника нічим не перевірити'
    grep -Fq 'browser)' bdo \
        || fail 'єдиний вхід не має ./bdo browser · діагностика браузера недосяжна'
    # ПОРЯДОК закриття зміни в `web/**` мусить стояти в правилах, бо саме їх
    # агент читає на початку сесії · інакше наступна сесія знову перевірить
    # сторінку локально й назве це перевіркою (§16.7).
    grep -Fq 'ЗАКРИВАЄТЬСЯ ПРОГОНОМ У БРАУЗЕРІ ВЛАСНИКА' AGENTS.md \
        || fail 'AGENTS.md не фіксує обовʼязкового прогону в браузері власника (§16.7)'
    # МЕЖА НАТИСКАННЯ. Дозвіл тиснути дії з наслідками існує РАЗОМ зі своїм
    # переліком заборон · без нього наступна сесія видалить сесію власника,
    # вважаючи це «тестуванням» (§16.4).
    grep -Fq 'ЗАБОРОНЕНО без окремого слова власника' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає межі для дій з наслідками (§16.4)"
    grep -Fq 'видалення сесій і журналів' AGENTS.md \
        || fail 'AGENTS.md не називає, чого агент НЕ тисне сам (§16.4)'
    grep -Fq '§16.7 ОБОВ' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §16.7 з порядком кроків"
    # МОДЕЛЬ РОБОТИ. Флоу двох агентів знято 2026-09-12 разом із текою
    # `docs/ai-workflow/`; контракт однієї сесії живе в §17 нормативу, а
    # стереже його `check_delegation_contract` у категорії `docs` · там же,
    # де решта того самого контракту. Тут перевірки НЕМАЄ навмисно: тримати
    # половину контракту в `shell`, а половину в `docs` означає, що саботаж
    # ловиться лише одним із двох гейтів (перевірено фальсифікацією 6.6.7).
    test -f docs/plans/stages/README.md \
        || fail 'немає реєстру етапів · підетапи ніде не мають статусу'
    grep -Fq '§16 Браузер власника як' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §16 про браузер власника"
    grep -Fq '§15 Цілісність дизайну' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §15 про цілісність дизайну"
    grep -Fq 'ДИЗАЙН Є СИСТЕМОЮ' AGENTS.md \
        || fail 'AGENTS.md не фіксує, що дизайн є системою (§15)'

    note 'дизайн: палітра лише в :root, шкала 11/12/13, кнопки з наявних класів; MCP chrome-devtools на місці'
}

# ПОРОЖНІЙ МАСИВ ПІД `set -u` · клас, який ловиться лише на macOS.
#
# `/bin/bash` тут 3.2.57, і в ньому `"${arr[@]}"` на ПОРОЖНЬОМУ масиві падає з
# `unbound variable`. У bash 5.x (homebrew) це працює, тому дефект не видно ні
# в розробці, ні в `bash -n` · він вилазить рівно на прогоні, коли гілка не
# додала жодного аргументу. Саме так пачка власника стала на кроці QA
# (`qa_args[@]: unbound variable`, D106).
#
# Запобіжник: `${arr[@]+"${arr[@]}"}` · нічого на порожньому, усі елементи на
# непорожньому. Працює в обох версіях.
check_bash32_arrays() {
    step 'Порожні масиви під set -u (bash 3.2)'
    local hits
    # Коментарі не виконуються · пояснення самого правила не є порушенням.
    hits="$(rg -n '"\$\{[a-z_]+\[@\]\}"' --glob '*.sh' cli bin scripts tests 2>/dev/null \
        | grep -v '\[@\]+' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | sed -n '1,3p' || true)"
    test -z "$hits" \
        || fail "розкриття масиву без запобіжника · упаде на порожньому в bash 3.2: $hits"
    # Перевірка МУСИТЬ мати чим доводити: без старого bash вона нічого не
    # значить, і про це треба сказати, а не тихо пройти.
    if [ -x /bin/bash ] && /bin/bash --version | grep -q 'version 3\.'; then
        /bin/bash -c 'set -u; a=(); printf "%s" ${a[@]+"${a[@]}"}' >/dev/null 2>&1 \
            || fail 'запобіжник ${a[@]+...} не працює в /bin/bash · перевірка недійсна'
        note 'bash 3.2 на місці · запобіжник перевірено ним самим'
    else
        note 'bash 3.2 недоступний · перевірено лише статично'
    fi
}

# ЖИВИЙ PHP, а не заморожені shell-тіла. Результат mkdir має бути перевірений,
# а count() не має виконуватись у кожній ітерації заголовка циклу.
check_sigpipe_pipelines() {
    step 'Конвеєри printf у grep -q'
    # ПРАВИЛО: `printf ... | grep -q` під `set -o pipefail` є гонитвою, а не
    # перевіркою: `grep -q` виходить на першому збігу, `printf` отримує SIGPIPE
    # і повертає ненульовий код, а pipefail віддає код конвеєра саме за ним.
    # УСПІШНИЙ пошук читається як провал, і повідомлення бреше про причину.
    # САБОТАЖ, який це валить: повернути будь-який такий конвеєр назад.
    # Зміряно на D114: на macOS 0 хибних падінь, на CI-runner · одразу.
    # Безпечна форма · `grep -q ПАТЕРН <<<"$var"`: конвеєра немає, SIGPIPE теж.
    local hits
    hits="$(rg -n --pcre2 "printf '%s(\\\\n)?' \"\\\$\\w+\" \\| grep -[a-zA-Z]*q" \
        tests scripts cli 2>/dev/null || true)"
    test -z "$hits" \
        || fail "конвеєр printf у grep -q ловить SIGPIPE замість результату:\n$hits"
    note 'жодного printf у grep -q: успішний пошук не читається як провал'
}

check_php_runtime_guards() {
    step 'PHP runtime guards'
    local count_in_loop mkdir_hits file line text context following start
    count_in_loop="$(rg -n --pcre2 --glob '*.php' 'for\s*\([^;\n]*;[^;\n]*\bcount\s*\(' lib cli 2>/dev/null || true)"
    test -z "$count_in_loop" \
        || fail "count() у умові заголовка PHP-циклу · обчисли довжину перед циклом:\n$count_in_loop"
    mkdir_hits="$(rg -n --pcre2 --glob '*.php' 'mkdir\s*\(' lib cli 2>/dev/null || true)"
    while IFS=: read -r file line text; do
        test -n "$file" || continue
        start=$((line > 3 ? line - 3 : 1))
        context="$(sed -n "${start},$((line + 3))p" "$file" | tr '\n' ' ')"
        if grep -Eq 'is_dir.*mkdir.*is_dir' <<<"$context"; then
            continue
        fi
        if grep -Eq '= *@?mkdir\s*\(' <<<"$text"; then
            following="$(sed -n "$((line + 1)),$((line + 4))p" "$file")"
            grep -Eq 'if .*is_dir' <<<"$following" \
                || fail "результат mkdir() не перевірено перед записом: $file:$line"
            continue
        fi
        fail "mkdir() без перевірки результату в живому PHP-коді: $file:$line"
    done <<EOF
$mkdir_hits
EOF
    note 'PHP: count() у loop-condition немає; кожен mkdir() має перевірку результату'
}

# ПРАВИЛО: RunSpec/RunStart/RunMode/RunDrive є process-free native commands.
# САБОТАЖ: function call exec()/shell_exec()/system()/passthru()/popen()/proc_open()
# у будь-якій із цих чотирьох команд має зупинити shell і full gate.
check_run_php_subprocess_guards() {
    step 'Run PHP subprocess guard'
    local file hits
    for file in lib/Cli/Command/Run/RunSpecCommand.php \
        lib/Cli/Command/Run/RunStartCommand.php \
        lib/Cli/Command/Run/RunModeCommand.php \
        lib/Cli/Command/Run/RunDriveCommand.php; do
        test -f "$file" || fail "відсутній Run PHP-файл: $file"
        grep -Fq 'ПРАВИЛО:' "$file" || fail "у $file немає коментаря ПРАВИЛО:"
        grep -Fq 'САБОТАЖ:' "$file" || fail "у $file немає коментаря САБОТАЖ:"
        hits="$(rg -n --pcre2 '\b(exec|shell_exec|system|passthru|popen|proc_open)\s*\(' "$file" || true)"
        test -z "$hits" || fail "заборонений subprocess у $file:\n$hits"
    done
    local loop='lib/Cli/Command/Run/RunLoopCommand.php' hits count
    test -f "$loop" || fail "відсутній Run PHP-файл: $loop"
    grep -Fq 'ПРАВИЛО:' "$loop" || fail "у $loop немає коментаря ПРАВИЛО:"
    grep -Fq 'САБОТАЖ:' "$loop" || fail "у $loop немає коментаря САБОТАЖ:"
    hits="$(rg -n --pcre2 '\b(exec|shell_exec|system|passthru|popen)\s*\(' "$loop" || true)"
    test -z "$hits" || fail "заборонений subprocess у $loop:\n$hits"
    count="$(rg -c --pcre2 '\bproc_open\s*\(' "$loop" || true)"
    test "$count" = 1 || fail "RunLoopCommand має рівно один proc_open helper, знайдено: $count"
    grep -Fq 'proc_open($command' "$loop" \
        || fail 'RunLoopCommand proc_open не отримує argv-array helper'
    note 'process-free Run commands і один argv-array RunLoop process helper перевірені'
}

# ПРАВИЛО: write-тести працюють лише в тимчасовому harness і не мають права
# чистити production-root output/state.
# САБОТАЖ: SOURCE_ROOT у cleanup або копіювання не за дозволеним складом має
# зупинити gate до будь-якого запуску write-сценарію.
check_write_test_safety() {
    step 'Write-test safety'
    local file hits source_root_uses
    for file in tests/cli-write-parity.sh tests/write-channel-rights.sh; do
        test -f "$file" || fail "відсутній write-тест: $file"
        grep -Fq 'ПРАВИЛО:' "$file" || fail "у $file немає коментаря ПРАВИЛО:"
        grep -Fq 'САБОТАЖ:' "$file" || fail "у $file немає коментаря САБОТАЖ:"
        grep -Fq 'SOURCE_ROOT="$ROOT"' "$file" || fail "у $file немає SOURCE_ROOT capture"
        grep -Fq 'HARNESS="$TMP/repo"' "$file" || fail "у $file немає isolated harness"
        grep -Fq 'ROOT="$HARNESS"' "$file" || fail "у $file немає ROOT harness switch"
        hits="$(grep -nE '\$SOURCE_ROOT/(output|state)|\$\{SOURCE_ROOT\}/(output|state)' "$file" || true)"
        test -z "$hits" || fail "write-тест має production-root output/state access: $hits"
        source_root_uses="$(grep -n 'SOURCE_ROOT' "$file" || true)"
        test "$(grep -c 'SOURCE_ROOT="\$ROOT"' "$file" || true)" -eq 1 \
            || fail "у $file має бути рівно один SOURCE_ROOT capture"
        test "$(grep -c 'SOURCE_ROOT.*HARNESS/cli' "$file" || true)" -eq 1 \
            || fail "у $file немає дозволеного копіювання cli через SOURCE_ROOT"
        test "$(grep -c 'SOURCE_ROOT.*HARNESS/lib' "$file" || true)" -eq 1 \
            || fail "у $file немає дозволеного копіювання lib через SOURCE_ROOT"
        test "$(grep -c 'SOURCE_ROOT.*HARNESS/config' "$file" || true)" -eq 1 \
            || fail "у $file немає дозволеного копіювання config через SOURCE_ROOT"
        test "$(grep -c 'SOURCE_ROOT.*HARNESS/roles' "$file" || true)" -eq 1 \
            || fail "у $file немає дозволеного копіювання roles через SOURCE_ROOT"
        test "$(printf '%s\n' "$source_root_uses" | wc -l | tr -d ' ')" -eq 5 \
            || fail "SOURCE_ROOT має використання поза assignment і чотирма copy operations: $source_root_uses"
    done
    note 'write-тести ізолюють state/output у harness; SOURCE_ROOT має лише 4 дозволені copy operations'
}

# ПРАВИЛО: write orchestration у PHP не запускає Unix-процеси; HTTP і файлові
# операції виконуються через PHP/runtime-класи.
# САБОТАЖ: доданий виклик exec()/shell_exec()/system()/passthru()/popen()/proc_open()
# у будь-якому з чотирьох production-файлів має зупинити gate.
check_write_php_subprocess_guards() {
    step 'Write PHP subprocess guard'
    local file hits
    for file in lib/Api/TranslationWriter.php \
        lib/Cli/Command/Batch/BatchCommitCommand.php \
        lib/Cli/Command/Write/WriteTranslationsCommand.php \
        lib/Cli/Command/Write/ModerationCommand.php; do
        test -f "$file" || fail "відсутній write PHP-файл: $file"
        grep -Fq 'ПРАВИЛО:' "$file" || fail "у $file немає коментаря ПРАВИЛО:"
        grep -Fq 'САБОТАЖ:' "$file" || fail "у $file немає коментаря САБОТАЖ:"
        hits="$(rg -n --pcre2 '\b(exec|shell_exec|system|passthru|popen|proc_open)\s*\(' "$file" || true)"
        test -z "$hits" || fail "заборонений subprocess у $file:\n$hits"
    done
    note 'write PHP-файли не запускають зовнішніх процесів'
}

check_whitespace() {
    step 'Whitespace і conflict markers'
    git diff --check
    git diff --cached --check
    note 'git diff --check: чисто'
}

check_delegation_contract() {
    step 'Контракт делегування (шар розробки)'
    # ПРАВИЛО: флоу АРХІТЕКТОР+ВИКОНАВЕЦЬ знято рішенням власника 2026-09-12.
    # Карта правил тепер тримає контракт делегування, і КОЖЕН його пункт має
    # тут свій grep · інакше правило лишається побажанням (§13 довідника).
    # САБОТАЖ: прибрати будь-який рядок нижче з AGENTS.md, повернути в неї
    # знятий контракт, видалити тип сабагента, зняти захист від секретів в
    # обгортці Codex · `./bdo gate docs` мусить впасти на кожному з них.
    #
    # НЕГАТИВНІ перевірки стоять першими: знятий контракт, який тихо повернувся
    # в карту, дав би дві суперечливі інструкції одночасно, і перемогла б та,
    # яку модель прочитала пізніше.
    if grep -Fq 'АДРЕСАТ: АРХІТЕКТОР' AGENTS.md; then
        fail 'карта правил повертає знятий контракт ВИКОНАВЦЯ · «АДРЕСАТ: АРХІТЕКТОР»'
    fi
    if grep -Fq 'АРХІТЕКТОРСЬКИЙ ПАТЧ' AGENTS.md; then
        fail 'карта правил повертає знятий механізм архітекторського патча'
    fi
    if grep -Fq 'docs/** не редагуєш' AGENTS.md; then
        fail 'карта правил містить старе blanket-правило «docs/** не редагуєш»'
    fi
    grep -Fq 'ДВА ШАРИ НЕ ПЛУТАТИ' AGENTS.md \
        || fail 'карта правил не розрізняє шар розробки і шар перекладу'
    grep -Fq 'СПОЧАТКУ CODEX' AGENTS.md \
        || fail 'карта правил не ставить Codex способом за замовчуванням'
    # ХТО ВИКОНАВ · без цього рядка делегування стає невидимим для власника:
    # він бачить результат, але не бачить, чий бюджет на нього пішов.
    grep -Fq 'ХТО ВИКОНАВ' AGENTS.md \
        || fail 'карта правил не вимагає називати у звіті, хто яку частину виконав'
    grep -Fq '§17.9 ХТО ВИКОНАВ' "$RULE_REFERENCE" \
        || fail 'норматив не описує формат рядка «ХТО ВИКОНАВ»'
    # НЕДОСТУПНІСТЬ · СТОП. Без цього рядка правило вироджується в протилежне:
    # агент не достукався до Luna, тихо зробив роботу сам і витратив бюджет,
    # який власник на це не виділяв (рішення власника 2026-09-12).
    grep -Fq 'НЕДОСТУПНИЙ CODEX · СТОП' AGENTS.md \
        || fail 'карта правил не робить недоступність Codex зупинкою'
    grep -Fq 'exit 3' scripts/delegate-codex.sh \
        || fail 'обгортка Codex не має окремого коду виходу для недоступності · СТОП не відрізнити від помилки'
    grep -Fq 'model_reasoning_effort' scripts/delegate-codex.sh \
        || fail 'обгортка Codex не передає глибину reasoning · medium/high перестають діяти'
    # ВИНЯТОК для делегованого · без нього правило зациклюється: сабагент і
    # Codex читають цю саму карту й починають виконувати правило замість пакета
    # (спіймано прогоном delegate-codex у сусідньому проєкті 2026-09-12).
    grep -Fq 'ДЕЛЕГОВАНИЙ ВИКОНАВЕЦЬ ЦЬОГО НЕ ПИТАЄ' AGENTS.md \
        || fail 'карта правил не звільняє делегованого виконавця від правила про спосіб'
    grep -Fq 'ДУМАННЯ НЕ ДЕЛЕГУЄТЬСЯ' AGENTS.md \
        || fail 'карта правил не забороняє делегувати рішення'
    grep -Fq 'Коміт і push · лише головна сесія' AGENTS.md \
        || fail 'карта правил не лишає коміт і push за головною сесією'
    # Правило без виконавців є побажанням: типи сабагентів і обгортка мусять
    # існувати, а заборона комітити · стояти в КОЖНОМУ визначенні агента.
    local agent
    for agent in inventory mechanic; do
        test -f ".claude/agents/$agent.md" \
            || fail "немає .claude/agents/$agent.md · тип виконавця оголошено лише на словах"
        grep -Fq 'НЕ КОМІТИТИ І НЕ ПУШИТИ' ".claude/agents/$agent.md" \
            || fail "$agent.md не забороняє коміт і push"
        grep -Fq 'СПОСІБ ВЖЕ ОБРАНО' ".claude/agents/$agent.md" \
            || fail "$agent.md не звільняє виконавця від питання про спосіб · він перепитає замість роботи"
    done
    grep -Fq 'СПОСІБ ВЖЕ ОБРАНО' scripts/delegate-codex.sh \
        || fail 'обгортка Codex не додає преамбулу · делегований агент перепитає замість роботи'
    test -x scripts/delegate-codex.sh \
        || fail 'scripts/delegate-codex.sh відсутній або не виконуваний'
    grep -Fq 'DELEGATE_CODEX_MODEL' scripts/delegate-codex.sh \
        || fail 'обгортка Codex не фіксує модель · делегування піде на випадкову'
    grep -Fq 'api[_-]?token' scripts/delegate-codex.sh \
        || fail 'обгортка Codex не має механічного захисту від секретів у промпті'
    grep -Fq 'BDO_ENV_FINGERPRINT' scripts/delegate-codex.sh \
        || fail 'обгортка Codex не стереже .env від чужого агента'
    git check-ignore -q state/delegate-logs \
        || fail 'тека логів делегування не ігнорується git · промпти й відповіді потраплять у публічний репозиторій'
    # Знятий флоу не повертається ФАЙЛАМИ. Тека `docs/ai-workflow/` видалена
    # 2026-09-12: її повернення означало б дві суперечливі інструкції в дереві,
    # і наступна сесія прочитала б стару як чинну. Історія · тег
    # `ai-workflow-final` і zip у власника, тому видалення нічого не втратило.
    if [ -d docs/ai-workflow ]; then
        fail 'тека docs/ai-workflow/ повернулась · знятий флоу знову читається як інструкція'
    fi
    # Контракт однієї сесії живе в §17 нормативу, і вимога ФАЛЬСИФІКАЦІЇ разом
    # із ним: без неї нова перевірка буде фіктивною · у наборі вже були тест на
    # КОМЕНТАРІ й перевірка, що знаходила `.btn-danger` у `.btn-dangerX`.
    grep -Fq '§17 Одна сесія й делегування' "$RULE_REFERENCE" \
        || fail "у $RULE_REFERENCE немає §17 про одну сесію й делегування"
    grep -Fq '§17.4 ФАЛЬСИФІКАЦІЯ обов' "$RULE_REFERENCE" \
        || fail "§17.4 не вимагає фальсифікації кожної нової перевірки"
    grep -Fq 'вважається фіктивною' "$RULE_REFERENCE" \
        || fail 'норматив не називає неспростовану перевірку фіктивною'
    note 'контракт делегування: межі в карті, два типи виконавців, обгортка Codex, старий флоу знято'
}

check_docs() {
    run bash tests/command-registry.sh
    check_rules
    check_delegation_contract
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

    # КЛІКОВІ ВХОДИ · Windows має `bdo.bat`, macOS `BDO.app`. Бандл лишається
    # тонким містком: уся логіка живе в `cli/system/mac-app.sh`, бо всередині
    # бандла її не бачать ні `bash -n`, ні ShellCheck, ні цей gate.
    if [ -d BDO.app ]; then
        test -f 'BDO.app/Contents/Info.plist' || fail 'BDO.app без Info.plist · macOS такий бандл не запустить'
        test -x cli/system/mac-app.sh || fail 'cli/system/mac-app.sh не виконуваний'
        # БАНДЛ МУСИТЬ БУТИ APPLET, А НЕ СКРИПТ (D91). Бандл, чий виконуваний
        # файл є звичайним скриптом, не відкриває зʼєднання з WindowServer,
        # тому LaunchServices не бачить запуск завершеним і значок у Dock
        # СТРИБАЄ БЕЗКІНЕЧНО. Доказ мірою, а не думкою: `lsappinfo` показував
        # `!cgsConnection` у скриптового бандла й не показував в applet.
        test -x 'BDO.app/Contents/MacOS/applet' \
            || fail 'BDO.app не є applet · значок у Dock стрибатиме безкінечно (D91)'
        # ЗАКРИВ ЗНАЧОК · ЗУПИНИВСЯ ІНТЕРФЕЙС, і значок живий, поки живий
        # сервер. Обидва боки тримає САМ applet: «Завершити» приходить як
        # `on quit`, а очікування робить `on idle`. Питаємо ЗІБРАНИЙ бандл
        # розкомпілюванням · джерело могло піти вперед без перезбирання.
        if have osadecompile; then
            local applet_src
            applet_src="$(osadecompile 'BDO.app/Contents/Resources/Scripts/main.scpt' 2>/dev/null || true)"
            grep -q 'on quit' <<<"$applet_src" \
                || fail 'зібраний BDO.app не має on quit · закриття значка лишить інтерфейс жити (D90)'
            grep -q 'on idle' <<<"$applet_src" \
                || fail 'зібраний BDO.app не має on idle · значок не переживе смерті сервера'
            grep -Fq 'cli/system/mac-app.sh' <<<"$applet_src" \
                || fail 'зібраний BDO.app не кличе cli/system/mac-app.sh · логіка переїхала в бандл, де її ніхто не перевіряє'
            # Пояснення для скопійованого бандла живе в скрипті: коли набору
            # поруч немає, сказати про це має саме він.
            grep -Fq 'Набір не знайдено поруч із додатком' cli/system/mac-app.sh \
                || fail 'скопійований BDO.app мовчить замість пояснення'
            # Зібране мусить відповідати ДЖЕРЕЛУ. Без цього `BDO.app` тихо
            # застигне на старій редакції, а правку в `.applescript` ніхто не
            # помітить · рівно та ситуація, задля якої існує gate генерації
            # `docs/COMMANDS.md`. Порівнюємо значущі рядки: розкомпілювання
            # нормалізує відступи й переносить довгі рядки.
            local built source_norm
            norm() { grep -v '^[[:space:]]*--' | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//' -e '/^$/d'; }
            built="$(printf '%s' "$applet_src" | norm)"
            source_norm="$(norm < cli/system/mac-app.applescript)"
            test "$built" = "$source_norm" \
                || fail 'BDO.app зібрано не з поточного cli/system/mac-app.applescript · перезбери: bash scripts/build-mac-app.sh'
        fi
        # Підпис перезакладається останнім кроком збирання. Недійсний підпис ·
        # це відмова запуску, а не косметика.
        if have codesign; then
            codesign --verify --deep BDO.app >/dev/null 2>&1 \
                || fail 'підпис BDO.app недійсний · macOS відмовиться його запускати'
        fi
        # Значок мусить бути видимий у Dock · інакше закрити його неможливо.
        # Питаємо САМ ключ, а не слово в тексті: згадка в коментарі не є
        # налаштуванням, і `grep` по назві валив би перевірку на поясненні.
        if have plutil && plutil -extract LSUIElement raw BDO.app/Contents/Info.plist >/dev/null 2>&1; then
            fail 'BDO.app схований із Dock (LSUIElement) · власнику нічого закривати'
        fi
        # ЗНАЧОК МУСИТЬ МАТИ ОБЛИЧЧЯ. Без `CFBundleIconFile` + файла ресурсу
        # Dock показує безликий бланк, і власник не відрізнить набір від
        # будь-якого іншого саморобного бандла. Ключ читаємо `plutil`, а не
        # `grep`: назва в коментарі не є налаштуванням.
        test -f 'BDO.app/Contents/Resources/BDO.icns' \
            || fail 'BDO.app без Resources/BDO.icns · у Dock буде порожній бланк'
        if have plutil; then
            local icon
            icon="$(plutil -extract CFBundleIconFile raw BDO.app/Contents/Info.plist 2>/dev/null || true)"
            test "$icon" = 'BDO' \
                || fail "CFBundleIconFile=${icon:-<немає>}, а ресурс зветься BDO.icns · Dock значка не знайде"
            # `Assets.car` від `osacompile` МАЄ ПРІОРИТЕТ над `CFBundleIconFile`,
            # тому з ним у Dock лишався типовий значок applet-а.
            test ! -f 'BDO.app/Contents/Resources/Assets.car' \
                || fail 'у BDO.app лишився Assets.car · він перебиває наш значок типовим значком applet-а'
        fi
        # Windows-значок лишається в теці набору поруч із `bdo.bat`. Сам `.bat`
        # свого значка нести НЕ МОЖЕ · його чіпляють до ярлика (див. README).
        test -f bdo.ico || fail 'немає bdo.ico · ярлику Windows нема чого показати'
        # ОДНЕ ОБЛИЧЧЯ НА ТРИ ПОВЕРХНІ. Перша редакція значків робилась із теки
        # завантажень власника: ті файли зникнуть, і перегенерувати значок буде
        # нізвідки, а «схожий» дав би три різні обличчя в Dock, у ярлику й у
        # вкладці. Тому джерело лежить у репозиторії, а збирач один.
        test -x scripts/build-icons.sh \
            || fail 'немає scripts/build-icons.sh · значки нічим перегенерувати'
        local icon_src
        icon_src="$(sed -n "s/^readonly SRC='\(.*\)'$/\1/p" scripts/build-icons.sh | sed -n '1p')"
        test -n "$icon_src" || fail 'scripts/build-icons.sh не називає джерела значків'
        test -f "$icon_src" \
            || fail "джерело значків $icon_src немає в репозиторії · перегенерувати буде нізвідки"
        test -f web/favicon.ico \
            || fail 'немає web/favicon.ico · браузер просить цей шлях САМ і дістане 403 (D102)'
        # КЛІКОВИЙ ЗАПУСК НЕ МАЄ PATH ТЕРМІНАЛА (D89). Перевірка структурна й
        # доповнює `tests/gui-path.sh`: той тест SKIP-иться там, де php лежить
        # у базовому PATH, а прибрати рядок із `bdo` можна на будь-якій машині.
        test -f cli/system/gui-path.sh || fail 'немає cli/system/gui-path.sh · кліковий запуск лишиться без Homebrew у PATH'
        grep -Fq 'cli/system/gui-path.sh' bdo \
            || fail 'єдиний вхід не лагодить PATH · значок у Dock помре на «немає php» (D89)'
        note 'BDO.app: applet, зібраний із cli/system/mac-app.applescript; значок BDO.icns, Windows · bdo.ico'
    fi

    # Makefile не має права стати другою копією дерева команд.
    #
    # Він уже нею був і був видалений 2026-09-04 (4.4.0). Повернутий того ж дня
    # з ОДНИМ призначенням: власник одним кліком підключається до термінальної
    # сесії, у якій працює агент (`make attach`). Підкомандою `./bdo` це не
    # робиться · роботу запускає агент, а підключається людина зі свого
    # терміналу. Тому перелік цілей закритий, і жодна не кличе `./bdo` крім
    # `watch`: інакше дерево команд знову розійдеться з
    # `cli/command-registry.json` (§9 довідника).
    if [ -f Makefile ]; then
        local targets bad_bdo
        targets="$(grep -oE '^[a-z][a-z-]*:' Makefile | tr -d ':' | sort -u | tr '\n' ' ')"
        test "$targets" = 'attach help screen stop web web-stop ' \
            || fail "Makefile має інші цілі, ніж attach/help/screen/stop/web/web-stop: [$targets]"
        # `./bdo help` і `./bdo review` у ПІДКАЗЦІ дозволені: це вказівник для
        # людини, а не виконання команди. Заборонено саме виконання чогось,
        # крім `watch`, тобто рецепт без `printf`/`@printf`.
        # Дозволено рівно два виклики набору: `watch --…` (видимість роботи) і
        # `web` (інтерфейс). Усе інше в Makefile означало б другу копію дерева
        # команд · саме за це попередній Makefile і був видалений.
        bad_bdo="$(grep -nE '\./bdo ' Makefile | grep -v 'watch --' | grep -v './bdo web' | grep -v 'printf' | grep -v '^[0-9]*:#' || true)"
        test -z "$bad_bdo" || fail "Makefile дублює команду набору замість посилання на ./bdo help: $bad_bdo"
        grep -Fq 'cli/command-registry.json' Makefile \
            || fail 'Makefile не називає єдине джерело дерева команд'
        # ДВІ ЗУПИНКИ, і кожна мусить існувати. `make stop` прибирає РОБОТУ
        # (сесію tmux), `make web-stop` · сам ІНТЕРФЕЙС. Другої не було
        # взагалі: `make web` підіймав сервер, а прибрати його з того самого
        # місця було нічим (власник назвав це 2026-09-06).
        grep -Fq './bdo web --stop' Makefile \
            || fail 'Makefile підіймає інтерфейс, але не вміє його зупинити'
        grep -Fq './bdo watch --stop' Makefile \
            || fail 'Makefile не вміє зупинити роботу'
        note 'Makefile: 6 цілей (інтерфейс і видимість), дерева команд не дублює'
    fi

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

    # §13.7 · `«$VAR»` під `set -u` падає з `unbound variable`.
    #
    # bash читає багатобайтовий символ ОДРАЗУ після імені змінної як частину
    # цього імені: `«$m»` для нього змінна `m»`. Рядок спрацьовує лише тоді,
    # коли до нього дійшло виконання, тому дефект живе в гілках відмов · саме
    # там, де він найшкідливіший. ShellCheck цього не бачить: синтаксис цілий.
    # 2026-09-05 клас укусив двічі за одну сесію (`tests/step-times.sh`,
    # `cli/audit/model-bench.sh`), тому далі його ловить перевірка, а не памʼять.
    #
    # УВАГА для правок: усередині `php -r '…'` правильна форма інтерполяції ·
    # `{$var}`, а НЕ `${var}` (останнє в PHP 8.3 вже deprecated). Механічна
    # заміна на bash-форму 2026-09-06 занесла `${var}` у три PHP-рядки.
    local braceless
    # Патерн задається КОДАМИ символів, а не самими символами: інакше
    # ShellCheck бачить у файлі «розумні лапки» й лається SC1112 на сам патерн.
    braceless="$(rg -n --glob '*.sh' --glob '.githooks/*' \
        '\$[A-Za-z_][A-Za-z0-9_]*[\x{00AB}\x{00BB}\x{00B7}\x{2019}\x{201C}\x{201D}\x{2014}\x{2026}]' \
        . 2>/dev/null | grep -vE ':[[:space:]]*#' | sed -n '1,3p' || true)"
    test -z "$braceless" \
        || fail "змінна без фігурних дужок перед багатобайтовим символом (par.13.7, pid set -u це unbound variable):
$braceless"
    note 'фігурні дужки біля «…»: пройдено'

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
    run bash tests/cli-kernel.sh
    run bash tests/cli-api-reports.sh
    run bash tests/cli-api-glossary.sh
    run bash tests/cli-api-fetch.sh
    run bash tests/cli-quality-parity.sh
    run bash tests/cli-prepare-parity.sh
    run bash tests/cli-batch-heal-parity.sh
    run bash tests/cli-batch-clean-parity.sh
    run bash tests/cli-run-foundation-parity.sh
    run bash tests/cli-run-mode-parity.sh
    run bash tests/cli-run-drive-parity.sh
    check_write_test_safety
    check_write_php_subprocess_guards
    run bash tests/cli-write-parity.sh
    run bash tests/cli-payload-parity.sh
    run bash tests/batch-summary.sh
    run bash tests/drive-memory-layers.sh
    run bash tests/judge-flow.sh
    run bash tests/patch-argument.sh
    run bash tests/pre-push-attribution.sh
    run bash tests/commit-version-guard.sh
    run bash tests/run-resume.sh
    run bash tests/run-target-env.sh
    run bash tests/api-target-switch.sh
    run bash tests/http-retry.sh
    run bash tests/http-client.sh
    run bash tests/rotation.sh
    run bash tests/session-lifecycle.sh
    run bash tests/web-server.sh
    run bash tests/web-actions.sh
    run bash tests/web-steps.sh
    run bash tests/web-screens.sh
    run bash tests/web-live-typing.sh
    run bash tests/web-call-view.sh
    run bash tests/qa-memory-only.sh
    run bash tests/no-silent-failures.sh
    run bash tests/quarantine-recovery.sh
    run bash tests/worker-reference.sh
    run bash tests/schema-provider-compat.sh
    run bash tests/mechanical-final-check.sh
    run bash tests/domain-filter.sh
    run bash tests/audit-response-shape.sh
    run bash tests/mechanical-before-qa.sh
    run bash tests/cli-quality-parity.sh
    run bash tests/heal-attempts.sh
    run bash tests/payload-shared-examples.sh
    run bash tests/registry-hygiene.sh
    run bash tests/api-doc-contract.sh
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
    # ПРАВИЛО: default PHP engine є live source of truth для direct child roles.
    # САБОТАЖ: роль у frozen rollback shell може лишитися старою й не має робити
    # gate зеленим після зміни PHP allowlist.
    engine_roles="$(php -r 'require "lib/autoload.php"; echo implode("\n", Bdo\Translate\Cli\Command\Run\RunDriveCommand::roles());' | sort -u)"
    test -n "$engine_roles" || fail 'RunDriveCommand::roles() не повернув ролей'
    missing=""
    for role in $engine_roles; do
        jq -e --arg r "$role" '.roles[$r]' config/roles.json >/dev/null || missing="$missing $role"
    done
    test -z "$missing" || fail "рушій кличе ролі, яких немає в config/roles.json:$missing"
    run bash tests/model-client.sh
    run bash tests/model-transports.sh
    run bash tests/driver-loop.sh
    run bash tests/tui.sh
    run bash tests/tui-live.sh
    run bash tests/watch-session.sh
    run bash tests/gui-path.sh
    run bash tests/run-stop.sh
    run bash tests/mac-app-quit.sh
    run bash tests/step-report.sh
    run bash tests/glossary-provenance.sh
    run bash tests/qa-scope.sh
    run bash tests/row-attempts.sh
    run bash tests/names-pass.sh
    run bash tests/prompt-payload-contract.sh
    run bash tests/step-times.sh
    run bash tests/qa-gap-costs-rows.sh
    run bash tests/terminology-excerpt.sh
    run bash tests/terminology-chunks.sh
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
    shell) check_rules; check_shell; check_design; check_bash32_arrays; check_php_runtime_guards; check_run_php_subprocess_guards; check_write_test_safety; check_write_php_subprocess_guards; check_sigpipe_pipelines; check_whitespace ;;
    agents) check_rules; check_agents; check_whitespace ;;
    runtime) check_rules; check_runtime ;;
    api) check_rules; check_api ;;
    full) check_docs; check_shell; check_design; check_bash32_arrays; check_php_runtime_guards; check_run_php_subprocess_guards; check_write_php_subprocess_guards; check_sigpipe_pipelines; check_agents ;;
    *) printf 'Usage: %s {preflight|docs|shell|agents|runtime|api|full}\n' "$0" >&2; exit 2 ;;
esac

printf '\nAgent gate passed: %s\n' "$profile"
