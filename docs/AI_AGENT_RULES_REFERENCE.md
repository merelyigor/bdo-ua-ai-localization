# Нормативний довідник AI-агента

Це повний контракт `bdo-ua-ai-localization`. Коротка карта в root rule-файлах
маршрутизує сюди за категорією задачі. Номери `§N.M` сталі: нові правила отримують
нові номери, чинні не перенумеровуються.

## §1 Пріоритет, факти і межі задачі

- §1.1 Поточна вказівка власника має пріоритет, крім безпекових і юридичних
  заборон. Конфлікт правил зупиняє роботу до рішення власника.
- §1.2 Не вигадувати файли, API, поля, flags, ENV, модель, поведінку або результат.
  Джерела факту: код, targeted read, `rg`, лог, тест, реальна команда, серверна
  документація через `TRANSLATE_PROJECT_ROOT`.
- §1.3 Після двох еквівалентних невдач встановити причину й змінити підхід;
  третя ідентична спроба заборонена.
- §1.4 Одна сесія має одну ціль і явний Definition of Done. Не додавати
  рефакторинг, dependency, abstraction або compatibility layer без потреби.
- §1.5 Перед редагуванням знайти реалізацію, call sites, конфіг і перевірки.
  Серверний проєкт read-only: його код звідси не змінювати й не дублювати.

## §2 Публічний репозиторій і класи даних

- §2.1 Репозиторій та історія публічні. Заборонені у tracked/staged content,
  commit messages, prompts, відповідях і логах: API keys, tokens, passwords,
  private keys, cookies, session identifiers, credential/password/token/session
  hashes, private URLs, private hostnames, database dumps і персональні дані.
- §2.2 Усі чутливі значення зберігаються лише в локальному `.env` або у файлі,
  явно заданому `TRANSLATE_ENV_FILE`; обидва мають бути поза Git. У репозиторії
  дозволений лише `.env.example` з порожніми або безпечними публічними defaults.
- §2.3 `.env`, state, output, API responses, OpenCode database/session dumps і
  runtime logs не передавати remote/free моделям та не вставляти в issue/PR/chat.
- §2.4 `identity_hash`, `source_hash`, schema fingerprint і artifact checksum є
  технічними ідентифікаторами, а не credentials. Вони дозволені у мінімальному
  API/batch payload, але повний payload чи state dump публікувати заборонено.
- §2.5 Домашні абсолютні шляхи, приватна топологія, локальні usernames, e-mail та
  внутрішні URL не документувати. Публічні repo/domain URLs і нейтральні
  placeholders дозволені.
- §2.6 Якщо секрет потрапив у Git або зовнішній канал: зупинити роботу, не
  повторювати значення, повідомити власника, відкликати/перегенерувати credential,
  оцінити історію та логи. Видалення рядка новим комітом не скасовує витік.

## §3 Механічні security controls

- §3.1 `.gitignore` мусить ігнорувати root і nested `.env`, крім безпечного
  `.env.example`, а також `output/`, runtime dependencies та IDE metadata.
- §3.2 `.githooks/pre-commit` перевіряє staged snapshot, а не лише worktree:
  забороняє `.env*`, значення з локального env і відомі credential patterns.
- §3.3 Security hook не пропонує `--no-verify` як нормальний recovery path.
  Хибне спрацювання виправляється мінімальним уточненням pattern/test після review.
- §3.4 Docs gate сканує tracked files і нові файли поточної зміни, але не читає
  вміст `.env`, `state*` або `output/`. Значення env порівнює лише pre-commit hook.
- §3.5 Заборонено виводити знайдений секрет повністю. Повідомлення називає файл,
  line/type або ім'я ENV, достатні для локального виправлення.

## §4 Робоче дерево, Git і необоротні дії

- §4.1 До роботи й перед фіналом виконати `git status --short`, переглянути власний
  diff і не змінювати чужі незакомічені правки.
- §4.2 `git push` виконує ВИКЛЮЧНО власник. Агент не пушить ніколи · ні за
  дозволом, ні за проханням, ні «щоб завершити задачу». Те саме стосується всього,
  що змінює remote: force-push, `push --tags`, видалення чи перейменування
  віддалених гілок, зміна remote. Агент може лише сказати, що готове до push, і
  назвати гілку.
- §4.3 `git commit` агент виконує у двох випадках: власник попросив прямо, або
  агент спитав згоду й отримав її в цьому ж діалозі. Без цього коміту немає, навіть
  коли робота завершена й перевірки зелені. Дозвіл на один коміт не переноситься
  на наступні.
- §4.4 Заборонені без одноразового явного дозволу: force, rebase, tag, amend,
  зміна історії або remote state. Не використовувати `git add -A`, `git add .`,
  `git commit -a`; файли додавати переліком.
- §4.5 Commit message після дозволу строго відповідає
  `.codex/prompts/commit-message-ua.txt`, має зростаючу версію та не містить
  trailers, AI attribution або generated-by text. Backticks навколо
  ідентифікаторів дозволені; markdown-розмітка · ні.
- §4.6 Перед видаленням state/output, переписуванням історії, production write чи
  іншою необоротною дією назвати, що зникне, як відновити і що перевірити після.
- §4.7 `output/`, `state/`, `state-auto/` містять audit/cursors/quarantine.
  `./bdo clean` без `--apply` є preview; автоматично ці теки не видаляти.

## §5 Реалізація, shell і PHP

- §5.1 Стек: Bash orchestration/HTTP transport, frameworkless PHP 8.3+ для
  identity/quality/batch logic, jq/curl, Ollama та опційний OpenCode.
- §5.2 Новий shell helper має `set -euo pipefail` де сумісно, usage, явні exit
  codes, quoted expansions і пояснення причини нетривіального guard.
- §5.3 Новий PHP код використовує `Bdo\Translate\`, наявний autoloader,
  typed contracts і `php -l`; framework або Composer dependency без потреби не
  додавати.
- §5.4 HTTP виконувати лише через штатні helpers/select-env flow. Не створювати
  ad-hoc `curl` write, alternate API client або model runner.
- §5.5 Поведінковий bug отримує regression test. Спершу вузький доказ, потім
  профіль `shell`, потім ширший gate.
- §5.6 Коментарі пояснюють причину й invariant. Не видаляти дороге обґрунтування;
  якщо причина змінилась, оновити її разом із кодом.

## §6 Translation identity, quality і state

- §6.1 Stable identity = `source_language + key0 + record_id + key1`.
  `identity_hash` повертається API без вигадування або зміни; candidate не може
  містити foreign, duplicate чи missing identity.
- §6.2 PA markup, placeholders і newlines копіюються байт у байт. Так само все,
  що API віддав у `tokens.must_preserve` (`keep`): це єдиний авторитетний перелік
  недоторканого, і рівно його перевіряє `Row::tokenViolations()`.
- §6.3 Manual, machine і proposal є різними шарами. Manual revisions, glossary,
  moderation decisions і audit history не стирати й не перезаписувати.
- §6.4 Підстановка згадок дозволена лише для предметів. NPC, location, lore та
  інші типи не розширювати без окремого game-tested contract: це валило гру.
- §6.5 Видимий український текст не містить російської, латинських гомогліфів у
  кириличних словах або `—`; використовувати `·` чи дефіс.
- §6.6 Batch state ізольований manifest-ом. Cursor рухається лише після завершення
  batch; dry run його не рухає. Audit receipts і quarantine append-only.
- §6.7 Робочий flow один · OpenCode children. Повністю скриптовий orchestrator
  заморожений в `archive/legacy-script-flow/`: не запускається й не рефакториться.
  `state-auto/` зберігається, бо містить позиції вибірок того flow.
- §6.8 Квадратні дужки зберігаються за структурою (кількість, позиція), а вміст
  усередині перекладається, якщо теґа немає в `keep`: у корпусі усталене
  `[Титул]`, не `[Title]`. Вимога «квадратні теґи байт у байт» механічної
  перевірки не мала й дала на прод-прогоні 2026-08-17 три розбіжності, усі гірші
  за наявний текст.

## §7 Agent API і production

- §7.1 Ціль прогону задає одна константа `BDO_ENV=PROD|DEV` у локальному `.env` і
  керує читанням та записом разом. Агент її читає (`./bdo env`), не обирає й не
  перемикає прапорцем. Production read-only діагностика дозволена; production
  write вимагає дозволу на конкретний прогін і не переноситься далі. `BDO_ENV=PROD`
  дозволом на запис не є.
- §7.2 Перед write виконується `/me`; capability/role не обходяться зміною layer.
  `machine+direct`, `manual+proposal` та `auto_approve` використовуються лише за
  чинним `API_WRITE_CONTRACT.md` і серверним контрактом.
- §7.3 Кожен write row проходить deterministic local gates і API validate.
  Problematic row іде в moderation, а transport/environment failure · у quarantine.
- §7.4 External/API calls мають bounded timeout/retry й не логують headers,
  credentials або повні sensitive payloads. Error schema/status трактуються за
  серверною документацією, не вгадуються.
- §7.5 Прогін pin-иться до одного environment. Зміна target посеред run
  відхиляється; префікс `BDO_API_ENV=`, що суперечить `.env`, валить скрипт замість
  тихого перемикання. Один `.env` містить ключ рівно одного середовища.

## §8 OpenCode, субагенти й моделі

- §8.1 Лише named `translation-*` agents. Provider/model pin-яться в frontmatter,
  guard і allowlist; джерело правди після run · `./bdo audit`, не self-report.
- §8.2 Worker, repair і QA під constrained schema не мають жодних tools. Payload
  передається текстом. Tool call вимикає constrained decoding.
- §8.3 Дозволені лише GGUF Ollama models із validator allowlist. MLX заборонений,
  бо runner ігнорує constrained decoding.
- §8.4 Staged schema не замінює deterministic gates. Вона фіксує length та enum
  identity; `./bdo items`, quality checks і API validation лишаються обов'язкові.
- §8.5 Нову модель кваліфікувати кількома прогрітими runs, format compliance,
  runtime gate і реальним audit. Один sample не є доказом якості.
- §8.6 Не створювати alternate model invocation. Санкціоновані entrypoints:
  OpenCode children і ізольований benchmark `./bdo bench`, вихід якого механічно
  не приймається до запису.

## §9 Документація і плани

- §9.1 `docs/*.md` описують фактичний поточний стан. Плани живуть лише в
  `docs/plans/{backlog,active,done}` і синхронізуються з `README.md` та `BACKLOG.md`.
- §9.2 Новий план має status/date/registry header, scope, етапи й Definition of
  Done. `active -> done` лише з доказами або явною передачею залишку.
- §9.3 Зміна flow оновлює `docs/FLOW_STATE.md`; зміна API boundary ·
  `API_WRITE_CONTRACT.md`; зміна security · `docs/SECURITY.md`; навігація ·
  `docs/README.md`.
- §9.4 Документувати лише підтверджену поведінку. Неперевірений runtime/API факт
  позначити з причиною й ризиком, не перетворювати на твердження.
- §9.5 Публічна документація не містить приватних шляхів, host topology, ключів,
  state/API dumps або персональних даних.

## §10 Перевірки, завершення і формат звіту

- §10.1 Перед роботою `./bdo gate preflight`. Після зміни · профіль
  категорії. `full` охоплює локальні deterministic gates, але не викликає модель
  або API; `runtime` і `api` запускаються явно.
- §10.2 Gate недеструктивний: не пише в API/production, не деплоїть, не видаляє
  state, не змінює Git. Профіль без реальної перевірки заборонений.
- §10.3 Не заявляти успіх без exit 0. Пропущена команда має точну причину,
  неперевірений аспект і ризик.
- §10.4 Фінальний diff перевірити на secrets, state/output/tmp, generated files,
  чужі зміни, scope drift і whitespace.
- §10.5 Фінал має рівно два блоки: `## Звіт`, потім `## Що далі`. Звіт містить
  зроблене, доказові висновки, команди/результати, пропуски/ризики, `SEO-check` та
  `OSM-check`. Виправлення власної хибної заяви · окремий рядок.
- §10.6 `## Що далі` містить статус, 2-4 варіанти з рекомендованим першим,
  потребу від власника й Done criteria. Для цього CLI/docs repo `SEO-check` та
  `OSM-check` зазвичай `N/A`, але мають бути названі.

## §11 Еволюція правил

- §11.1 `AGENTS.md`, `.cursorrules`, `CLAUDE.md`, `QWEN.md` дослівно однакові.
  Зміна одного без трьох інших є gate failure.
- §11.2 Коротка карта не перевищує механічний line limit і не дублює цей довідник.
- §11.3 Нова норма не дублює чинну, має чітку область і, де можливо, механічний
  check у `scripts/agent-check.sh` (`./bdo gate`) або hook.
- §11.4 Номер правила сталий. Дублікат, номер чужої секції або посилання на
  неіснуюче `§N.M` є помилкою.
