# Технічний аудит і план покращень · 2026-09-20

## Статус документа

Це перевірений зріз, а не норматив. Аудит повторно звірено з кодом, тестами,
CI, git-історією та паралельною роботою на `HEAD c8de0ea`.

Стани пунктів: **активне** — дефект підтверджений; **в роботі** — виправлення
є лише в робочому дереві; **закрито** — є regression-перевірка; **не
планувати** — висновок завищений або не має достатнього ROI.

Паралельну роботу над видимістю пропусків закомічено в `c8de0ea`; локальна
regression-перевірка зелена. Остаточний доказ у CI з’явиться після push.

## Executive Summary

1. Початковий аудит був переважно правильним, але застарів: хибний
   `cli-payload-parity` і зламана команда docs-gate вже виправлені.
2. «Зелені пропуски» тестів закриті в `c8de0ea`: skip має exit 77, gate показує
   окремий підсумок, а CI забороняє пропуски.
3. Найменша актуальна runtime-проблема — Unix-команда `kill -0` у
   `Snapshot::pidAlive()`, хоча `WebCommand` уже має Windows-гілку через
   `tasklist.exe`.
4. PHPStan аналізує лише `lib/**` на level 0; production entrypoints у
   `cli/**` залишаються поза ним.
5. Заявлена підтримка PHP 8.3+ не перевіряється: CI запускає лише PHP 8.5, а
   bundled Windows runtime має версію 8.4.25.
6. Чотири instruction-файли byte-identical і автоматично звіряються. Їхня
   проблема — не суперечність, а 264 рядки з низьким signal-to-noise.
7. `RunDriveCommand` і `Snapshot` великі, але line count не доводить потребу в
   rewrite. Виділяти слід лише pure component під конкретну зміну.
8. Відсутність Playwright/Selenium у CI не є medium-ризиком сама по собі:
   Node DOM/HTTP-тести доповнює обов’язкова перевірка у браузері власника.
9. Підтвердженої критичної security-вразливості не знайдено. Це targeted
   review, а не penetration test.

## Highest Priority Problems

### A-06. Unix-only PID fallback у Windows web snapshot — активне

- **Severity:** Medium.
- **Area:** Code / Cross-platform / DX.
- **Agent impact:** Medium.
- **Evidence:** `lib/Web/Snapshot.php:1551-1563` викликає `kill -0` без
  `posix_kill`; `WebCommand.php:474-516` уже використовує `tasklist.exe`;
  `tests/windows-native-smoke.ps1` не покриває `Snapshot::pidAlive()`.
- **Problem:** native Windows не гарантує Unix-команду `kill`; Snapshot може
  позначити живий model call завершеним.
- **Recommended change:** винести чинну cross-platform логіку `WebCommand` у
  малий PHP adapter і використати його в обох consumers.
- **Larger option:** heartbeat замість PID — не робити зараз.
- **Expected benefit:** один process-liveness contract на всіх ОС.
- **Risk of change:** Low/Medium.
- **Estimated effort:** Small/Medium.
- **Confidence:** High.

Пакет реалізації для Luna High:

1. Scope: новий helper у `lib/`, `Snapshot.php`, `WebCommand.php`, Windows
   smoke і один POSIX unit-style test.
2. Не змінювати формат `state/*.json`, lifecycle сервера або сигнали.
3. Спершу перенести `WebCommand::isAlive()` без зміни поведінки; `Snapshot`
   має викликати той самий helper.
4. Додати injectable platform probe для тесту; не підміняти глобальні константи
   й не використовувати чужий реальний PID.
5. Regression: invalid PID → false; POSIX success/failure; Windows tasklist з
   PID → true; аргументи передаються масивом, не shell-рядком.
6. Focused tests, `./bdo gate touched`, `./bdo api`, `git diff --check` → exit 0.
7. **Definition of Done:** у production немає `exec('kill -0 ...')`, обидва
   consumers використовують adapter, Windows regression зелений.

### A-02. PHPStan не охоплює весь production PHP — активне

- **Severity:** Medium, не High.
- **Area:** Code / CI.
- **Agent impact:** High.
- **Evidence:** `phpstan.neon` має `level: 0`, `paths: [lib]`; production
  `cli/model/client.php` і `cli/system/web-router.php` поза scope.
- **Problem:** зелений PHPStan не є доказом для всього runtime.
- **Recommended change:** спочатку виміряти diagnostics для `cli/**/*.php`.
  Невеликий список виправити напряму; baseline — лише для великого списку з
  окремим follow-up. Не піднімати level у цій задачі.
- **Expected benefit:** точніший machine-readable feedback.
- **Risk of change:** Low для config, Medium для масових fixes.
- **Estimated effort:** Medium.
- **Confidence:** High щодо gap; обсяг diagnostics ще невідомий.

Пакет реалізації для Luna High:

1. Запустити чинний PHPStan і зафіксувати baseline.
2. Тимчасово перевірити всі tracked production `cli/**/*.php`; порахувати
   errors за файлами й класами.
3. До 20 локальних errors — додати `cli` у paths і виправити. Більше 20 —
   розбити план; широкий baseline автоматично не створювати.
4. Не змінювати `level: 0`.
5. Додати check, який падає, якщо production `cli/**/*.php` знову поза scope.
6. PHPStan, focused tests, `./bdo gate touched`, `./bdo api`,
   `git diff --check` → exit 0.
7. **Definition of Done:** весь production PHP аналізується або має явно
   обґрунтований вузький виняток.

### A-08. CI не перевіряє мінімальну PHP 8.3 — активне

- **Severity:** Medium.
- **Area:** CI / Compatibility / Documentation.
- **Agent impact:** Medium.
- **Evidence:** README і Windows docs заявляють PHP 8.3+; усі jobs у
  `.github/workflows/gate.yml` використовують 8.5; `bdo.bat` pin-ить 8.4.25.
- **Problem:** API/синтаксис PHP 8.4+ може пройти CI й зламати PHP 8.3.
- **Recommended change:** додати дешевий Linux job PHP 8.3: lint усіх tracked
  PHP-файлів плюс вузький runtime smoke. Full gate лишити на 8.5.
- **Expected benefit:** minimum version стає перевіреним контрактом.
- **Risk of change:** Low.
- **Estimated effort:** Small.
- **Confidence:** High.

Пакет реалізації для Luna High:

1. Scope: `.github/workflows/gate.yml` і, лише за потреби, один smoke test.
2. Job `php_83_compat`, `ubuntu-24.04`, PHP 8.3.
3. Lint усіх tracked `*.php`, виключивши `state/`, `output/`, `legacy/`,
   `node_modules/`.
4. Запустити короткий existing smoke без API, Ollama і GUI.
5. Не змінювати minimum version і не дублювати full gate для трьох версій.
6. Локально повторити lint-команду, smoke, `./bdo gate touched`,
   `git diff --check`.
7. **Definition of Done:** PR CI має окремий зелений PHP 8.3 job.

## Architecture & Code Quality

### A-05. Великі класи — спостерігати, не рефакторити окремо

- **Severity:** Low/Medium.
- **Area:** Architecture / Maintainability.
- **Agent impact:** Medium.
- **Evidence:** `RunDriveCommand.php` — 1183 рядки й понад 50 methods;
  `Snapshot.php` — 1564 рядки й понад 35 methods.
- **Confirmed problem:** зміна state machine/read model потребує широкого
  читання й збільшує reasoning cost.
- **Correction:** розмір не доводить god object. Перший клас є state machine,
  другий — агрегованим read model; централізація частково навмисна.
- **Recommended change:** не робити class-split PR. Виносити лише pure
  component під конкретну зміну з власним regression test. Перший кандидат —
  process adapter з A-06.
- **Risk of change:** High для rewrite, Low для одного helper.
- **Estimated effort:** Large для повного поділу; його не планувати.
- **Confidence:** Medium.

## Testing & Verification

Повторно перевірено:

- `bash tests/cli-payload-parity.sh` → exit 0; A-01 закрито.
- чотири instruction mirrors byte-identical; gate перевіряє тотожність і
  ліміт 300 рядків;
- docs-gate використовує `git grep` і розрізняє exit 1 та scanner error;
  A-04 закрито;
- local `phpstan` відсутній, тому кількість diagnostics для `cli/**` невідома;
- full gate не запускався: незавершена паралельна зміна самого gate і тестів
  зробила б результат сумішшю аудиту та чужої реалізації.

Більше не писати як актуальний факт:

- full gate падає на `cli-payload-parity`;
- docs-gate друкує `grep --include` error;
- дерево чисте або `HEAD` дорівнює `3148bd0`;
- skips повертають exit 0 — після `c8de0ea` це вже неправда.

Низькопріоритетне:

- fail-fast не показує всі failures — це нормальна властивість gate;
- artifacts додавати лише для конкретного failure, журнал якого губиться;
- `tests/web-server.sh` має stale comment про `sessionStorage`, тоді як primary
  storage — `localStorage`; виправити після завершення паралельної роботи.

## AI Agent Readiness

### A-07. Instruction context має низький signal-to-noise — активне, не перше

- **Severity:** Medium.
- **Area:** AI Agent / Documentation / DX.
- **Agent impact:** High.
- **Evidence:** чотири identical файли по 264 рядки; reference — 240 рядків;
  gate вимагає багато дослівних історичних фраз.
- **Problem:** critical acceptance criteria конкурують з датами, причинами й
  рідкісними edge cases.
- **Correction:** mirrors не є різними sources of truth — gate доводить їхню
  тотожність. Генератор не обов’язковий; важливіше скоротити канон.
- **Recommended change:** в entrypoint лишити scope, safety boundaries,
  routing, gates і final format. Історію та рідкісні сценарії маршрутизувати в
  `AI_AGENT_RULES_REFERENCE.md`. Нічого не скорочувати без mechanical check.
- **Expected benefit:** менше context overhead.
- **Risk of change:** Medium/High.
- **Estimated effort:** Medium.
- **Confidence:** High щодо обсягу, Medium щодо впливу без A/B eval.

Пакет дослідження для Luna High, без переписування правил:

1. Таблиця для кожного bullet: `keep`, `route`, `remove as history`,
   `already enforced by code/gate`.
2. Для `route/remove` назвати mechanical enforcement; немає — не скорочувати.
3. Розділити machine-specific, project-wide і task-specific правила.
4. Ціль аналізу — entrypoint ≤150 рядків без втрати hard boundaries; це не
   дозвіл механічно різати текст.
5. Підготувати diff-план і потрібні gate changes, код не змінювати.
6. **Definition of Done:** кожен рядок має долю, кожна hard boundary — check.

Посилання в `docs/DELEGATION.md` на setup сусіднього проєкту є provenance, а
не runtime dependency; його відсутність у цьому repo не є дефектом.

## Dependency / Library Opportunities

Нову runtime dependency аудит не рекомендує:

- framework/Composer не вирішують підтвердженої проблеми;
- database/event bus не потрібні для file-backed contract `state/**`;
- process adapter має бути малим внутрішнім класом;
- Playwright/Selenium не додавати без browser-only failure, якого не ловлять
  чинні Node/HTTP tests і live browser verification.

## Quick Wins

1. Виправити stale comment у `tests/web-server.sh`.
2. Додати PHP 8.3 compatibility job (A-08).
3. Виправити Windows PID fallback (A-06).

## Larger Improvements

1. Розширити PHPStan scope без підняття level (A-02).
2. Провести inventory instruction context, потім окремо затвердити скорочення
   (A-07).
3. Виносити pure components з великих класів лише під конкретну зміну (A-05).

## Things That Should NOT Be Changed

- Не робити framework rewrite, не додавати Composer «для стандартності».
- Не замінювати file-backed state на database.
- Не повертати LLM orchestration замість deterministic driver.
- Не розбивати великі класи лише через line count.
- Не додавати browser framework без виміряного defect.
- Не вважати mirrors різними sources of truth.
- Не створювати PHPStan baseline до виміру diagnostics.

## Already Completed

### A-01. Хибний `cli-payload-parity` — закрито

Коміт `4aacb25` додав три сценарії: назви немає; назва дослівно; відмінкова
форма. D204 закритий. Повторний тест завершився exit 0. У roadmap не повертати.

### A-04. Зламана команда docs-gate — закрито

`scripts/agent-check.sh` використовує `git grep -nE` і розрізняє «збігів
немає» та scanner error. Після виправлення docs-gate мав exit 0 без старої
помилки. У roadmap не повертати.

### A-03. Невидимі пропуски тестів — закрито локально

Коміт `c8de0ea` ввів exit 77, окремий підсумок пропусків і strict mode для CI.
`bash tests/gate-skip-visibility.sh` завершився exit 0. Після push лишається
дочекатися зеленого CI; нової реалізації для цього пункту не планувати.

## Recommended Roadmap

1. **P1 — A-08:** дешевий PHP 8.3 compatibility job.
2. **P1 — A-06:** спільний process adapter і Windows regression.
3. **P2 — A-02, вимір:** порахувати PHPStan diagnostics для `cli/**`.
4. **P2 — A-02, реалізація:** розширити scope, лишити level 0.
5. **P3 — A-07:** тільки inventory; переписування після окремого прийняття.
6. Не створювати задачі на class split, browser framework чи artifacts без
   нового конкретного дефекту.

## Загальний протокол для слабшої coding-моделі

Кожен пункт roadmap — окрема задача:

1. Прочитати `AGENTS.md`, названі файли, tests і call sites.
2. Перевірити `git status --short`; чужі зміни не редагувати й не комітити.
3. Відтворити проблему або baseline до зміни.
4. Змінити лише scope пункту; не додавати dependency/abstraction поза планом.
5. Додати regression з negative control.
6. Focused test, потім `./bdo gate touched && ./bdo api`, якщо пакет не задає
   сильнішої перевірки.
7. `git diff --check`, `git diff --stat`, повний diff, `git status --short`.
8. Не оголошувати «вирішено» без exit 0 обов’язкової команди.

## Межі впевненості

- Перевірені code/config/CI/instructions, ключові execution paths і history.
- Security-висновок не є formal penetration test.
- Performance profiling та A/B eval agent instructions не проводились.
- Windows PID defect доведений статично й прогалиною coverage; живого
  відтворення на Windows у цьому аудиті не було.
