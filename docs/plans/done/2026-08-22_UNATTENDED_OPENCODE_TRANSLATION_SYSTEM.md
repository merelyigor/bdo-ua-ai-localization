# Автономна система перекладу в OpenCode

- **Статус:** done (закрито 2026-08-22)
- **Створено:** 2026-08-22
- **Реєстр:** [docs/plans/README.md](../README.md)

## 1. Рішення власника і призначення плану

**Підсумок виконання 2026-08-22:** OpenCode 1.18.21 завантажив українські
primary-режими `патч`, `ручний`, `пропозиції`, `покращення`; live smoke створив
окремі parent/child session і повернув `status: PASS`. Активний PROD patch мав
1 рядок: worker, QA, repair і control QA завершились дочірніми сесіями, engine
відновився після двох client headers timeout, записав 1 рядок у `machine` і
зафіксував `verified`. Усі сім gates завершились з exit 0.

Цей план є єдиною програмою реалізації автономного перекладу для
`bdo-ua-ai-localization`. Його треба виконати наскрізно як одну роботу. Окремий
етап, зелений unit test або створена дочірня сесія не є завершеним результатом.
План закривається лише після живого unattended-прогону, який записав усі
придатні рядки в потрібний шар і сам пережив контрольовані відмови.

Основний сценарій власника:

1. У неділю в BDO виходить патч приблизно на 500-1000 нових рядків.
2. Власник відкриває OpenCode та обирає готовий режим роботи.
3. Режим показує активний патч, статистику, рекомендований розмір пачки,
   кількість пачок і прогноз часу.
4. Після короткого підтвердження диригент сам запускає локальних субагентів,
   перевіряє їх, повторює невдалі кроки, записує результат і бере наступну пачку.
5. Власник може залишити процес без нагляду на кілька годин.
6. Після повернення власник бачить фактичний підсумок API, нуль необроблених
   рядків або точний список інфраструктурних очікувань, які автоматично
   продовжаться після відновлення залежності.

Пріоритети цього плану:

1. переклад фактично доходить до API;
2. жодна завершена робота не губиться і не записується двічі;
3. мовну роботу виконують справжні локальні субагенти OpenCode;
4. окремий збій не зупиняє весь прогін;
5. якість виправляється дешевими gates, QA і repair;
6. основний агент тільки диригує та звітує;
7. інтерфейс власника складається з готових режимів, а не з пояснення параметрів.

## 2. Межі та перевизначені попередні рішення

Поточне рішення власника перевизначає такі застарілі обмеження:

- замість одного універсального primary-агента мають бути окремі режими;
- правило «рівно одне коло repair» замінюється керованою політикою повторів;
- серверний API можна змінювати через `TRANSLATE_PROJECT_ROOT`, якщо це потрібно
  для idempotency, receipt, status або безпечного resume;
- прямі мовні виклики `cli/runtime/translate.sh -> Ollama` не є цільовою архітектурою;
- нуль записаних рядків після витрати токенів є дефектом системи;
- pipeline не має завершувати весь run через дефект однієї сесії чи пачки.

Незмінні обмеження:

- `BDO_ENV` у приватному `.env` одночасно задає read/write target;
- агент не перемикає `BDO_ENV`;
- `git push` виконує тільки власник;
- credentials, приватні URL, OpenCode DB dump, payload/state dump не потрапляють
  у tracked files, коміти або звіти;
- identity, `keep`, PA markup і placeholders не змінюються;
- дочірні мовні сесії працюють на GGUF-моделях з allowlist і без tools;
- ручні рішення, moderation history і glossary не перезаписуються;
- `output/` та `state/` не видаляються;
- канал `machine` не змішується з `manual` або `proposal`.

Рефакторинг розкладки `cli/**`, масове перейменування shell-файлів і косметичне
розділення документації не входять у критичний шлях. Їх не виконувати до
закриття цього плану, якщо конкретний файл не заважає реалізації.

## 3. Цільовий інтерфейс OpenCode: готові режими

### 3.1 Primary-агенти

Створити чотири primary-агенти з короткими стабільними ASCII ID. Українська
назва і призначення мають бути в `description`, щоб OpenCode показував власнику
зрозумілий вибір. Не покладатися на Unicode у filename або agent key, доки це не
підтверджено окремим runtime-тестом встановленої версії OpenCode.

| ID | Українська назва в description | Призначення | Канал |
|---|---|---|---|
| `патч` | `Перекласти активний патч` | нові рядки активного патча без ШІ-шару | `machine` |
| `ручний` | `Ручний переклад` | створення якісного ручного шару | `manual`, дефекти -> `proposal` |
| `пропозиції` | `Підготувати пропозиції` | усе відразу в чергу модерації | `proposal` |
| `покращення` | `Поліпшити ШІ-переклад` | повторний переклад наявного machine layer з англійського джерела | `machine` |

`translation` на час міграції лишити compatibility alias тільки якщо цього
вимагає OpenCode. Після доказу нових режимів він або перенаправляє на вибір
режиму без мовної роботи, або вимикається. Не підтримувати п'ять незалежних
копій великого prompt: спільні інваріанти живуть у коді та
`.opencode/critical-rules.md`, а prompt кожного режиму містить лише його policy.

### 3.2 Поведінка режимів без додаткових пояснень власника

Кожний режим на старті сам виконує read-only preflight і показує:

- `BDO_ENV`;
- active patch identifier і часові межі;
- кількість рядків за filter режиму;
- скільки закриває memory;
- рекомендований batch size;
- кількість пачок;
- приблизний час за останніми фактичними вимірами;
- стан незавершеного run: `new`, `resumable`, `waiting`, `complete`;
- поточний API quota, якщо endpoint це підтримує.

Режим не питає про параметри, для яких є безпечний default. Для запису достатня
команда власника «перекладай», «давай» або еквівалентне підтвердження; `BDO_ENV`
вже визначає середовище. Read-only запит про статистику нічого не записує.

### 3.3 Єдиний рушій під усіма режимами

Primary-агенти не реалізують чотири pipeline. Вони створюють `RunSpec` і
передають його одному рушію:

```json
{
  "mode": "patch|manual|proposal|improve",
  "environment": "PROD|DEV",
  "filter": "...",
  "channel": "machine|manual|proposal",
  "batch_size": 15,
  "memory_layers": ["manual", "machine"],
  "include_current": false,
  "created_by_session": "<OpenCode parent session>",
  "state": "planned|running|waiting|complete|failed_terminal"
}
```

Точний schema оформити у PHP value object і JSON Schema. Поля не будувати через
довільний текст primary-моделі: режим передає рушію лише відомий preset та явно
дозволені overrides.

## 4. Розподіл відповідальності

### 4.1 Primary-диригент

Primary-сесія:

- читає намір власника лише в межах обраного режиму;
- запускає або відновлює run;
- викликає одну машинно-читну команду рушія;
- показує прогрес і важливі warnings;
- не читає повні payload/response;
- не перекладає, не перевіряє і не ремонтує український текст;
- не збирає items власним `php -r`;
- не робить ad-hoc HTTP requests;
- не вирішує порядок кроків із prompt;
- не завершує run через окрему невдалу спробу.

### 4.2 Мовні субагенти OpenCode

Зберегти та, за виміряною потребою, розширити набір:

| Субагент | Вхід | Вихід | Tools |
|---|---|---|---|
| `translation-terminology` | лише unresolved/pending terms | пропозиції термінів | без доступу до payload/state; поточний вузький fallback переглянути |
| `translation-worker` | compact worker payload | candidate array | none |
| `translation-qa` | rows signals + candidate | verdict array | none |
| `translation-repair` | лише failing subset з defects | fixes array | none |
| `translation-smoke` | короткий marker | один детермінований рядок | none |

Новий мовний агент додається лише після виміру, що чинні ролі змішують несумісні
задачі. Не створювати субагента тільки заради кількості сесій.

### 4.3 Записувач API не є LLM-субагентом

Не створювати мовну сесію `translation-writer`, яка сама складає HTTP payload.
Запис є детермінованою транзакцією над уже перевіреним artifact:

1. pipeline будує `items.json` штатною PHP identity logic;
2. механічні gates фіксують identity, text, tokens і route;
3. write step обчислює idempotency key;
4. штатний API client надсилає точний payload;
5. receipt зберігається атомарно в manifest;
6. verifier читає status API та звіряє counts.

У UI цей крок можна показувати як `API writer`, але він не використовує модель,
не має свободи редагувати текст і не створює платного контексту primary-агента.

## 5. OpenCode session driver

### 5.1 Доведений локальний API

Встановлені типи `@opencode-ai/sdk` уже містять:

- `session.create` з `parentID`;
- `session.children`;
- `session.prompt` і `session.promptAsync`;
- `session.messages`;
- `session.status`;
- `session.abort`.

Реалізувати session driver у `.opencode/plugin/` або в мінімальному локальному
helper, який використовує клієнт, переданий OpenCode plugin runtime. Не запускати
окремий OpenCode server і не вигадувати endpoint, якщо клієнт уже доступний у
plugin context.

### 5.2 Обов'язковий spike перед підключенням pipeline

Spike є першим кроком реалізації, але не окремим deliverable:

1. Створити дочірню `translation-smoke` session з `parentID` primary-сесії.
2. Передати marker через supported session prompt API.
3. Довести, що session видима через `session.children` і в OpenCode DB.
4. Довести, що `chat.message` mutation, якщо вона потрібна, реально змінює prompt.
5. Довести, що agent/model/schema route застосовані до дочірньої сесії.
6. Перевірити timeout, abort і повторне створення child.

Якщо `chat.message` mutation не діє, не зупиняти план: використовувати прямий
`session.prompt` із payload, який driver читає з дозволеного artifact. Payload
не проходить через primary context. Зміна механізму не змінює acceptance.

### 5.3 Життєвий цикл дочірньої сесії

Для кожної model step рушій зберігає:

- role;
- attempt number;
- parent session ID локально, без tracked output;
- child session ID локально;
- payload artifact path і checksum;
- schema path і checksum;
- started/heartbeat/finished timestamps;
- provider/model;
- token counts;
- finish reason;
- response artifact checksum;
- validation result і failure code.

Одна спроба:

1. перевірити preconditions і schema;
2. створити child із правильним `parentID` та title без приватних даних;
3. подати payload;
4. чекати status/event з heartbeat;
5. на idle прочитати останню assistant response;
6. зберегти response атомарно;
7. прогнати shape/identity gate;
8. позначити спробу successful або classified failure;
9. після failure перейти до retry policy, а не завершити run.

У constrained child tools мають залишатися порожніми. Читання payload із диска
виконує driver до model request, а не сама модель.

## 6. Машина станів run і batch

### 6.1 Run manifest

Окремий run manifest містить:

- immutable `RunSpec`;
- environment fingerprint без secret;
- active patch/filter snapshot;
- ordered batch IDs;
- counters: selected, processed, written, moderated, waiting, terminal;
- current batch;
- lock owner/heartbeat;
- created/started/updated/completed timestamps;
- pause/wait reason;
- aggregate receipts;
- engine and prompt versions.

Запис manifest робити atomically через temp file + rename. Перед оновленням
перевіряти schema. Пошкоджений manifest не перезаписувати: створити backup у
state, відновити з journal і зафіксувати recovery event.

### 6.2 Batch manifest

Кожна пачка має immutable identity set та журнал кроків:

```text
selected -> prepared -> awaiting_worker -> candidate_valid
-> deterministic_valid -> awaiting_qa -> qa_valid
-> healing -> ready_to_commit -> committing -> committed -> verified
```

Дозволені бічні стани:

```text
waiting_dependency | retry_scheduled | paused | failed_terminal
```

`failed_terminal` дозволений лише для доведеного контрактного конфлікту, який
автоматично виправити неможливо: змінена source identity, відкликаний доступ,
непідтримувана server schema. Він не стирає пачку і не заважає обробити інші
незалежні пачки.

Кожний завершений step має artifact, sha256, counts, timestamp та engine
version. Step з валідним artifact не виконується вдруге.

### 6.3 Єдина команда рушія

Надати primary-режимам машинний контракт, наприклад:

```bash
./bdo run drive --json
```

Команда виконує детерміновані кроки до model boundary, керує child session через
session driver або повертає строгий envelope, якщо OpenCode runtime має виконати
виклик. Не парсити українські рядки через `grep`.

Envelope:

```json
{
  "ok": true,
  "run_id": "...",
  "state": "running|waiting|complete|failed_terminal",
  "did": [],
  "next": {"kind": "continue|wait|complete", "reason": null},
  "counts": {},
  "progress": {},
  "warnings": [],
  "owner_action_required": false
}
```

Primary повторює drive, доки стан не `complete`, `paused` або справжній
`owner_action_required`. Звичайний model/API timeout не є owner action.

## 7. Retry, repair і безперервність

### 7.1 Класи помилок

Кожна помилка отримує code, scope і recovery policy:

| Клас | Приклади | Дія |
|---|---|---|
| transient model | timeout, empty, invalid JSON | abort, backoff, нова child session |
| route/config | zero tokens, wrong provider/model | resync models, runtime check, restart child |
| response contract | duplicate/foreign/missing identity | reject whole response, rebuild schema, retry |
| row quality | QA major/critical, russianism | free fix -> repair subset -> control QA |
| transient API | timeout, 429, 5xx | status/idempotency check, backoff, retry |
| permanent row | source changed, server rejects invariant | refresh row, rebuild or terminal row event |
| dependency down | Ollama/API/OpenCode unavailable | `waiting_dependency`, periodic retry |
| process crash | app/terminal/computer restart | lock expiry, manifest resume |

### 7.2 Retry policy

Не робити безмежний гарячий цикл. Default policy має бути конфігурованою,
версійованою і перевіреною тестами:

- короткі model retry: 3 спроби з новою child session;
- після трьох — runtime self-check і одна відкладена серія;
- repair rounds: доки є виміряне покращення, але з лімітом часу/спроб на рядок;
- API: exponential backoff із jitter і повагою до `Retry-After`;
- dependency down: довгий `waiting` без втрати lock ownership/heartbeat;
- після вичерпання активного бюджету run продовжує інші пачки;
- unresolved manual row -> `proposal`;
- machine row із непорожнім текстом і зеленими mechanical gates -> `machine`;
- порожній machine row лишається resumable debt і повторюється пізніше.

Числа винести в один config із safe defaults. ENV overrides документувати лише
коли справді потрібні; не додавати десятки прихованих перемикачів.

### 7.3 Прогрес замість зависання

Watchdog перевіряє heartbeat дочірньої сесії та run. Якщо child перевищив timeout,
driver робить `session.abort`, класифікує спробу і створює нову. Якщо primary
сесія зникла, новий запуск того самого режиму знаходить resumable run і пропонує
`Продовжую незавершений прогін`, а не створює дубль.

## 8. Idempotent write і зміни серверного API

### 8.1 Клієнтський контракт

Перед commit створити stable idempotency key з environment, channel, batch ID,
identity set і candidate checksum. Ключ не містить secret або повного тексту.

Стани commit:

```text
ready_to_commit -> committing -> receipt_received -> verified
```

Після HTTP timeout у `committing` заборонено сліпо повторювати write. Спочатку
отримати status/receipt за idempotency key. Повтор допустимий лише коли сервер
підтвердив, що операцію не застосовано, або сервер сам дедуплікує ключ.

### 8.2 Серверний контракт

У `TRANSLATE_PROJECT_ROOT` спочатку прочитати його власні instructions, API
implementation, tests і migrations. Мінімально додати, якщо відсутнє:

- приймання idempotency key;
- атомарне збереження result/receipt;
- повтор того самого key повертає той самий semantic result;
- конфлікт key з іншим payload checksum дає окрему 409 error code;
- read-only endpoint status/receipt;
- counts written/rejected/moderated із per-item code;
- tests на timeout-after-commit і duplicate request.

Не дублювати серверну business logic у цьому репозиторії. Client error mapping
має використовувати реальні server codes.

## 9. Канальні контракти

### 9.1 Patch / machine

- filter за замовчуванням: active patch + `missing=machine`;
- manual/proposal layers не перезаписуються;
- усе з непорожнім text після mechanical gates пишеться в machine layer;
- QA визначає repair priority, але не маршрутизує machine row у moderation;
- порожній результат не комітиться і не губиться;
- run завершується, коли API query підтверджує нуль missing machine rows у scope.

### 9.2 Manual

- source selection виключає active proposals;
- PASS/acceptable після repair іде `manual` з чинною auto-approve policy;
- справді нерозв'язне після retry/repair іде `proposal`;
- moderation receipt входить у completed count;
- manual revision ніколи не замінюється machine write.

### 9.3 Proposal

- уся вибірка йде `proposal` з `auto_approve=false`;
- повторний run не створює duplicate active proposal;
- active proposal вважається доставленим результатом, а не failed row.

### 9.4 Improve machine layer

- fetch містить `layers` і current machine text;
- worker бачить `current` та зберігає його, якщо новий варіант не кращий;
- memory використовує лише дозволені шари, default `manual`;
- scope і cursor не залежать від `missing=machine`;
- checkpoint дозволяє мільйонний run виконувати днями;
- quota/wait автоматично продовжує run наступного quota window.

## 10. Команди оператора

Реалізувати через `./bdo`, з human output за замовчуванням і `--json` для
машинного споживача:

```text
./bdo mode status patch|manual|proposal|improve
./bdo run plan <mode>
./bdo run start <mode>
./bdo run drive
./bdo run status
./bdo run pause
./bdo run resume
./bdo run failures
./bdo run retry
./bdo run verify
./bdo audit
```

Назви можуть бути уточнені за наявною dispatcher-архітектурою, але не створювати
дублікати старих команд. `./bdo` і `./bdo help flow` повинні показувати один
канонічний маршрут.

Прогрес має містити: selected, memory, translated, QA PASS, repaired, written,
moderated, waiting, terminal, remaining, batches complete/total, elapsed, ETA,
current role/attempt та last successful receipt time.

## 11. Реалізаційна послідовність для Terra

Це порядок роботи всередині одного плану, а не незалежні релізи.

1. Виконати `./bdo gate preflight`, зафіксувати `./bdo env`, status і baseline
   усіх gates. Не запускати live batch, якщо власник уже тестує OpenCode.
2. Прочитати всі routed instructions і call sites: plugin, agents, schemas,
   batch, heal, commit, audit, installed SDK types, server API.
3. Зафіксувати baseline artifacts і synthetic fixtures без prod payload dump.
4. Реалізувати smoke session driver та довести parent/child/prompt/abort.
5. Додати PHP run/batch state machine, schemas, atomic journal і locks.
6. Додати JSON envelopes helper-ам, які читає рушій; прибрати parsing прози з
   нового маршруту.
7. Під'єднати worker до session driver; після regression gates під'єднати QA і
   repair; direct Ollama path лишити лише тимчасовим fallback під feature flag.
8. Довести дочірні сесії через OpenCode DB та `./bdo audit`; після цього видалити
   direct fallback і його config, щоб не було двох production flows.
9. Реалізувати retry classifier, watchdog, resume і fault injection.
10. Реалізувати idempotent client commit; за потреби змінити server API та його
    tests у серверному репозиторії.
11. Створити чотири primary-режими та спільний мінімальний policy prompt.
12. Перевести `патч`, manual/proposal та improve presets на один engine.
13. Додати operator status/pause/resume/failures/verify.
14. Оновити audit для parent-child relation, payload size/checksum, schema,
    tokens, tools, retry chain і receipt verification без друку sensitive data.
15. Додати regression tests і fault-injection harness.
16. Виконати dry run, restart/resume test, duplicate commit test і server tests.
17. Оголосити ціль одним рядком і виконати малу живу пачку в середовищі з `.env`.
18. Виконати повний активний patch run unattended.
19. Звірити OpenCode DB, audit, receipts та patch delta.
20. Лише після доказів прибрати застарілий універсальний flow, синхронізувати
    документацію, правила й реєстри.
21. Запустити всі gates та переглянути фінальний diff на secrets/state/output і
    сторонні зміни.

Після кожного кроку можна робити локальну перевірку, але не зупиняти виконання
плану для нового погодження, якщо не виникла safety stop-condition, зміна
`BDO_ENV`, необоротна migration або потреба в credential/owner action.

## 12. Тести

### 12.1 Unit і contract

- RunSpec presets та заборонені комбінації channel/filter;
- transition table: кожний дозволений і заборонений перехід;
- atomic manifest update та recovery journal;
- stale lock і live lock;
- retry classification/backoff;
- identity set, duplicate, missing, foreign hash;
- artifact checksum mismatch;
- idempotency key stability і collision guard;
- receipt parsing і server error mapping;
- route policy для всіх primary/subagent ролей.

### 12.2 Integration

- plugin створює child із правильним parent;
- worker/qa/repair отримують 45+ KB payload для реальної 15-row fixture;
- payload містить усі identity fixture;
- constrained schema активна;
- tools count дорівнює нулю;
- response зберігається й приймається механічним gate;
- retry створює іншу child session і зберігає chain;
- resume не повторює completed model step;
- commit повторно не викликає semantic write.

### 12.3 Fault injection

Обов'язково автоматизувати:

1. child session створилася порожньою;
2. неправильний provider/model;
3. timeout до першого token;
4. timeout після часткової відповіді;
5. invalid JSON;
6. валідний JSON із duplicate identity;
7. repair повернув порожній text;
8. OpenCode закрито між worker і QA;
9. OpenCode закрито між API request і локальним receipt;
10. API повернув 429, 500 і connection reset;
11. API записав, але response загубився;
12. повторний `run drive` запущено паралельно;
13. manifest пошкоджено посеред atomic update;
14. quota вичерпана;
15. source row змінився після fetch.

Для кожного тесту довести: run не втратив completed artifacts, не створив
duplicate write, перейшов у правильний retry/wait/terminal state і може resume.

## 13. Gates і докази

Під час реалізації запускати focused tests, наприкінці обов'язково:

```bash
./bdo gate preflight
./bdo gate docs
./bdo gate shell
./bdo gate agents
./bdo gate runtime
./bdo gate api
./bdo gate full
```

Додаткові докази:

- `./bdo audit` показує дочірні `translation-worker`, `translation-qa` і
  `translation-repair` з правильним parent, provider/model, tokens і нулем tools;
- session payload size для 15 живих рядків не менше 45 KB, якщо фактичний payload
  цієї вибірки такого розміру;
- кожний identity з rows присутній у prompt і response рівно один раз;
- `SHAPE`, `ROUTE`, `THINK`, `TOOLS`, `EMPTY` мають OK;
- write receipt counts збігаються з manifest;
- delta `./bdo patch` дорівнює кількості нових machine writes у scope;
- повтор drive після commit не змінює API counts;
- restart OpenCode посеред run продовжує незавершену пачку;
- навмисний model timeout автоматично породжує retry і успішне продовження.

Документація або self-report primary-моделі не є доказом.

## 14. Фінальний Definition of Done

План можна перенести в `done/` лише коли одночасно виконано все:

1. OpenCode показує чотири primary-режими з українським описом.
2. Вибір режиму однозначно задає scope, channel і defaults.
3. Worker, QA та repair є справжніми дочірніми сесіями OpenCode.
4. Primary не переносить payload і не виконує мовну роботу.
5. API write є детермінованим та idempotent, без LLM writer.
6. Run і batch мають перевірену машину станів, lock, journal і resume.
7. Model, OpenCode й API transient failures автоматично повторюються.
8. Manual failures доходять до moderation; machine non-empty rows доходять до
   machine layer; empty rows не губляться і лишаються resumable.
9. Після restart немає повторної трансляції завершених кроків або duplicate write.
10. Усі fault-injection тести зелені.
11. Усі сім gates мають exit 0.
12. Мала жива пачка записана та verified.
13. Повний активний patch run завершений unattended, а patch delta збіглася з
    receipt і manifest.
14. Правила, prompts, help, flow docs, plan registry та backlog відповідають коду.
15. Фінальний diff не містить secret, `.env`, state, output, DB dump, payload dump
    або сторонніх змін.

Якщо хоча б один пункт не доведений, статус лишається `active`, а фінальний звіт
називає точний blocking state, recovery і ризик. Формулювання «майже готово» або
«архітектура працює, але живий запис не перевірено» не закриває цей план.

## 15. Stop-conditions для виконавця Terra

Terra працює автономно до Definition of Done, але зупиняється й просить власника,
якщо:

- уже йде активний OpenCode run і тест створить конфлікт;
- потрібна зміна `BDO_ENV`;
- потрібна destructive migration або зміна історії Git;
- серверна migration має ризик втрати/перезапису даних;
- credential відсутній або відкликаний;
- контракт власника конфліктує з безпековою/юридичною вимогою;
- live PROD acceptance потребує дії, якої немає в уже даному дозволі `.env`.

Звичайна помилка моделі, timeout, invalid JSON, 429/5xx, порожня child session,
failed QA або потреба repair не є stop-condition: це штатні гілки recovery.
