# Технічний аудит проєкту · 2026-09-20

## Результат

Аудит завершено, код і конфігурацію не змінювали. Проєкт загалом має послідовну архітектуру, але поточний feedback loop дає хибну впевненість: повний gate падає через некоректне очікування тесту, частина production-коду не проходить PHPStan, а деякі перевірки можуть завершуватися успішно без фактичного виконання.

## Executive Summary

1. `./bdo gate full` зараз падає не через runtime-баг, а через суперечність у тесті `cli-payload-parity`: тест очікує наказ `ужий`, хоча fixture вже містить правильну назву `Залізний меч`, яку код навмисно вважає вже використаною.
2. PHPStan перевіряє лише `lib/**` і працює на `level: 0`. Важливі production-файли в `cli/**` залишаються поза статичним аналізом.
3. Web-тести переважно використовують Node/fake browser або `curl`; у CI немає справжнього browser smoke-тесту. За відсутності Node частина тестів повертає код 0 зі статусом `SKIP`.
4. Документаційний gate сам виводить помилку `grep: --include=*.php: No such file or directory`, але все одно завершується успішно. Конкретна перевірка фактично може не працювати.
5. `lib/Web/Snapshot.php` використовує Unix-команду `kill -0` як fallback. Це суперечить заявленій підтримці native Windows.
6. `RunDriveCommand.php` і `Snapshot.php` стали великими orchestration/read-model об’єктами з багатьма відповідальностями. Це головний архітектурний ризик для майбутніх змін.
7. Інструкції для AI-агентів дуже детальні й дубльовані в чотирьох файлах по 264 рядки. Вони синхронні, але споживають багато context window і містять історичні або нестабільні деталі.
8. Немає підтвердженої критичної security-вразливості. Web-сервер має перевірки token, origin і loopback. Основні ризики зараз — якість перевірок, portability і maintainability.

## Highest Priority Problems

### A-01. Червоний повний gate через неправильний контракт тесту

- **Severity:** High
- **Area:** Tests / CI / Code
- **Agent impact:** High
- **Evidence:** `tests/cli-payload-parity.sh:20-23,110-111`; `lib/Cli/Command/Prepare/NamesPayloadCommand.php:52-61`
- **Problem:** Fixture має candidate `Залізний меч`, а validation очікує `Залізний меч`. Тест вимагає наявності `ужий`, але код навмисно не створює такий наказ, якщо очікувана назва вже присутня.
- **Why it matters:** Повний gate червоний, хоча це не доводить поломку production-флоу. Агент може почати виправляти робочий код, щоб задовольнити помилковий тест.
- **Recommended change:** Або змінити fixture на справді неправильний переклад, або перевіряти порожній payload і повідомлення `вже виконано`.
- **Expected benefit:** Gate перевірятиме реальну поведінку, а не суперечливий сценарій.
- **Risk of change:** Low.
- **Estimated effort:** Small.
- **Confidence:** High.

### A-02. PHPStan створює неповну картину якості

- **Severity:** High
- **Area:** Code / CI
- **Agent impact:** High
- **Evidence:** `phpstan.neon:1-4`; production-код у `cli/system/web-router.php` та `cli/model/client.php`
- **Problem:** Аналіз охоплює лише `lib/**`, хоча значна частина runtime живе в `cli/**`. Рівень PHPStan — `0`.
- **Why it matters:** Агент отримує зелений static-analysis результат, хоча критичний HTTP/model runtime не перевірений типами.
- **Recommended change:** Поетапно додати `cli/**` до аналізу, починаючи з production PHP-файлів і окремого baseline для вже наявних проблем.
- **Expected benefit:** Менше прихованих type/runtime регресій і точніший feedback.
- **Risk of change:** Medium: можуть з’явитися численні старі warnings.
- **Estimated effort:** Medium.
- **Confidence:** High.

### A-03. Web-перевірки допускають false green

- **Severity:** Medium
- **Area:** Tests / CI / AI Agent
- **Agent impact:** High
- **Evidence:** `tests/web-inner-html-guard.sh:9`; `tests/web-live-typing.sh:17`; `tests/web-server.sh:29`; `.mcp.json:4-5`
- **Problem:** За відсутності Node або curl тести друкують `SKIP`/`ПРОПУЩЕНО` і повертають код 0. У CI немає реального браузерного smoke-тесту.
- **Why it matters:** Локально агент може отримати зелений результат, хоча JavaScript або browser interaction взагалі не перевірялися.
- **Recommended change:** Розділити статуси `passed`, `skipped`, `not-run`; для критичного flow додати один реальний browser smoke у CI або явно позначити його окремим обов’язковим ручним gate.
- **Expected benefit:** Зменшення ризику непомічених UI-регресій.
- **Risk of change:** Medium: browser CI збільшить час і складність середовища.
- **Estimated effort:** Medium.
- **Confidence:** High.

### A-04. Docs gate має помилкову команду, але не падає

- **Severity:** Medium
- **Area:** CI / Documentation / AI Agent
- **Agent impact:** High
- **Evidence:** `scripts/agent-check.sh:868-871`
- **Problem:** `grep` отримує `--include` після шляхів і виводить `grep: --include=*.php: No such file or directory`. Помилка приховується через `|| true`.
- **Why it matters:** Gate повідомляє `passed`, хоча перевірка викликів старих `.sh`-скриптів може фактично не виконуватися.
- **Recommended change:** Перенести `--include` перед `--`/pattern і перевіряти exit code самого пошуку окремо від “нічого не знайдено”.
- **Expected benefit:** Документаційний gate знову стане доказом, а не лише повідомленням.
- **Risk of change:** Low.
- **Estimated effort:** Small.
- **Confidence:** High.

## Architecture & Code Quality

### A-05. Надто великі orchestration/read-model класи

- **Severity:** Medium
- **Area:** Architecture / Code / Maintainability
- **Agent impact:** High
- **Evidence:** `lib/Cli/Command/Run/RunDriveCommand.php` — 1183 рядки; `lib/Web/Snapshot.php` — 1549 рядків.
- **Problem:** `RunDriveCommand` одночасно керує state transitions, retry, QA, healing, judge, names pass, записом файлів і subprocesses. `Snapshot` одночасно читає state, stream, журнали, PID, summaries і web payload.
- **Why it matters:** Невелика зміна в одному сценарії може зачепити кілька незалежних поверхонь. Агенту важко визначити side effects і правильний вузький тест.
- **Recommended change:** Не робити rewrite. Поступово винести pure/read-only частини: state transition handlers, file readers, stream assembler, process-status adapter.
- **Expected benefit:** Менші поверхні змін, простіші unit-тести, менший ризик регресій.
- **Risk of change:** Medium/High: неправильне розділення може змінити порядок state transitions.
- **Estimated effort:** Large.
- **Confidence:** High.

### A-06. Unix-specific перевірка PID у Windows-сумісному runtime

- **Severity:** Medium
- **Area:** Architecture / Cross-platform / DX
- **Agent impact:** Medium
- **Evidence:** `lib/Web/Snapshot.php:1536-1547`; `docs/PROJECT_OVERVIEW.md:17-24`
- **Problem:** Якщо немає `posix_kill`, код викликає `kill -0`. У native Windows цієї Unix-команди немає.
- **Why it matters:** Web snapshot може помилково вважати процес завершеним або не показати активний model call.
- **Recommended change:** Винести process-liveness у platform adapter або перейти на state/lock contract, який не залежить від Unix PID-команд. Додати Windows regression test.
- **Expected benefit:** Однакова поведінка macOS/Linux/Windows.
- **Risk of change:** Medium.
- **Estimated effort:** Medium.
- **Confidence:** High.

## Testing & Verification

Поточний фактичний стан перевірок:

- `./bdo gate full` — **exit 1**, приблизно після 1:34, падіння на `tests/cli-payload-parity.sh`.
- `./bdo gate docs` — **exit 0**, але з помилкою `grep`, описаною вище.
- `./bdo gate agents` — **exit 0**.
- `git diff --check` — **exit 0**.
- Local `phpstan` — **не запущений**, executable відсутній.
- Поточний `HEAD` — `3148bd0`; він випереджає `origin/main` на 3 коміти, тому для нього немає окремого CI-прогону.
- Робоче дерево чисте.

Додаткові слабкі місця:

- Full gate працює fail-fast і після першої помилки не показує стан інших тестів.
- Тимчасові каталоги тестів видаляються через `trap`, а CI не завантажує failure artifacts.
- Частина model/runtime тестів може завершуватися `SKIP`, якщо середовище не дозволяє локальний bind.
- Коментар у `tests/web-server.sh:19-20` говорить про `sessionStorage`, тоді як код використовує `localStorage` як основне сховище (`web/app.js:20-41`).

## AI Agent Readiness

### A-07. Надмірний і дубльований instruction context

- **Severity:** Medium
- **Area:** AI Agent / Documentation / DX
- **Agent impact:** High
- **Evidence:** `AGENTS.md`, `CLAUDE.md`, `QWEN.md`, `.cursorrules` — по 264 рядки кожен; `docs/AI_AGENT_RULES_REFERENCE.md` — 240 рядків; `docs/DELEGATION.md` — 214 рядків.
- **Problem:** Дзеркала синхронні, але агент перед простою задачею потенційно отримує понад 700-1500 рядків нормативного контексту з історичними поясненнями, датами та рідкісними edge cases.
- **Why it matters:** Зростає шанс пропустити критичне правило, переплутати актуальну норму з історичним рішенням або витратити context на інформацію, яка не стосується задачі.
- **Recommended change:** Залишити короткий operational entrypoint із маршрутами й acceptance criteria; деталі перенести в on-demand reference. Дзеркала генерувати з одного канонічного джерела.
- **Expected benefit:** Менше reasoning overhead і чіткіша навігація.
- **Risk of change:** Medium: не можна просто скоротити правила без перенесення їхніх gate-перевірок.
- **Estimated effort:** Medium.
- **Confidence:** High.

Окремо `docs/DELEGATION.md:8-10` посилається на зовнішній локальний шлях, якого немає в цьому репозиторії. Це не runtime-баг, але зайва hidden dependency для агента.

## Documentation & Agent Instructions

Документація загалом добре описує intended architecture і має автоматичні parity-перевірки. Проблеми:

- `AGENTS.md` позиціонується як коротка карта, але фактично містить багато повної нормативної документації.
- `gate docs` перевіряє посилання, дзеркала й ключові рядки, але не ловить змістовну суперечність коментарів на кшталт `sessionStorage`/`localStorage`.
- README заявляє PHP `8.3+`, тоді як CI перевіряє лише PHP `8.5`, а Windows bootstrap завантажує PHP `8.4.25`.
- Зовнішні або швидкозмінні деталі моделей, провайдерів і delegation workflow краще не тримати в основному agent prompt.

## Dependency / Library Opportunities

Сильних кандидатів на заміну custom code бібліотекою не знайдено.

- Composer або PHP framework не потрібні: проєкт має невеликий frameworkless runtime, власний простий autoloader і не має великого dependency graph.
- Замінювати file-backed `state/**` на database/event bus не варто: state одночасно читають CLI, TUI і web, а DB додала б друге джерело істини.
- Виносити process liveness у бібліотеку необов’язково; достатньо маленького platform adapter.
- Реальний browser test runner може бути корисним, але лише для критичних сценаріїв. Додавати його як загальну залежність без визначення конкретних UI-регресій не виправдано.

## Quick Wins

1. Виправити fixture або assertion у `tests/cli-payload-parity.sh`.
2. Виправити порядок аргументів `grep` у `scripts/agent-check.sh` і перестати приховувати помилку самого scanner.
3. Розділити `passed`, `skipped` і `not-run` у тестових результатах.
4. Виправити stale comment про `sessionStorage`.
5. Зафіксувати support matrix: PHP 8.3, 8.4, 8.5 та обов’язкові локальні інструменти.
6. Додати CI artifact для failure logs тестів, не змінюючи їхню cleanup-поведінку локально.

## Larger Improvements

1. Розширити PHPStan на `cli/**` із поступовим підняттям рівня.
2. Винести з `Snapshot` platform-neutral process status і state readers.
3. Розділити `RunDriveCommand` на окремі state/use-case handlers.
4. Створити короткий canonical agent entrypoint і генерувати дзеркала.
5. Додати один обмежений real-browser smoke для основного flow.
6. Зробити CI більш відтворюваним: pin versions для зовнішніх dev tools, узгодити PHP support matrix, зберігати діагностичні артефакти.

## Things That Should NOT Be Changed

- Не потрібен rewrite на framework.
- Не потрібен Composer лише “для стандартності”.
- Не потрібно замінювати file-based state на database.
- Не потрібно повертати LLM orchestration; порядок кроків у коді є правильнішим рішенням.
- Не потрібно прибирати `cli/command-registry.json` і generated `docs/COMMANDS.md`: це корисна пара source-of-truth + generated documentation.
- Не потрібно переносити весь runtime із PHP у shell або навпаки; поточне розділення runtime PHP і development scripts має логіку.

## Recommended Roadmap

1. **P0 — відновити довіру до gate:** виправити `cli-payload-parity`, виправити `grep` у docs gate.
2. **P1 — прибрати false green:** явні `SKIP`/`not-run`, failure artifacts, актуальна документація про prerequisites.
3. **P1 — закрити coverage gap:** додати production `cli/**` до PHPStan.
4. **P2 — portability:** винести перевірку PID і додати native Windows regression.
5. **P2 — agent context:** скоротити entrypoint та автоматизувати дзеркала.
6. **P3 — архітектурна стабілізація:** поступово розділити `RunDriveCommand` і `Snapshot`.
7. **P3 — browser confidence:** додати мінімальний реальний UI smoke лише після визначення критичних сценаріїв.

## Verification

Перевірено структуру, entrypoints, runtime-код, state flow, tests, CI, gates, PHPStan configuration, agent instructions, web tooling і cross-platform paths. `gate docs` і `gate agents` завершилися з кодом 0, `gate full` — з кодом 1 на конкретному test-contract mismatch.

Звіт створено без змін коду, конфігурації або тестів.
