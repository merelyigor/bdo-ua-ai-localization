# Етап: оркестрація в PHP · Windows без WSL2

- **Статус:** у роботі
- **Створено:** 2026-09-07
- **Реєстр:** [docs/plans/stages/README.md](README.md)
- **Рішення власника:** 2026-09-07 · «щоб Windows працював без WSL2,
  Linux/macOS/Windows однакові, бо PHP CLI однаковий»

## 1. Мета

Прибрати bash із шляху виконання набору так, щоб `./bdo` (і його
Windows-аналог) працював на macOS, Linux і Windows БЕЗ WSL2, без Docker і без
зовнішніх утиліт, крім PHP CLI.

Це НЕ переписування проєкту: логіка вже в PHP. Це прибирання ДРУГОЇ мови зі
шва між командою й логікою.

## 2. Чому саме PHP, а не Python чи Node

Вимір станом на 2026-09-07:

| Шар | Обсяг | Роль |
|---|---|---|
| `lib/**` (PHP) | 7 263 рядки | стан, workspace, схеми, якість, payload · УСЯ логіка |
| `cli/**` (bash) | 10 455 рядків | оркестрація: аргументи, файли, послідовність |
| `cli/**` (PHP) | 1 248 рядків | уже перенесені частини |
| `tests/**` (bash) | 7 895 рядків | перевірки поведінки |

`cli/run/run-drive.sh` викликає `php` **34** рази, `cli/batch/batch-commit.sh`
· **8**. Тобто bash тут не логіка, а клей навколо PHP.

Python або Node означали б ТРЕТЮ мову: на Windows довелося б ставити і PHP (бо
`lib/**` нікуди не зникає), і новий рантайм. Виграшу нуль, залежностей більше.

## 3. Що дає перенос, крім Windows

Закривається цілий КЛАС дефектів, який уже стріляв:

| Дефект | Суть | Чому в PHP його не буде |
|---|---|---|
| D106 | `qa_args[@]: unbound variable` · порожній масив під `set -u` у bash 3.2 | немає розкриття масивів як тексту |
| D89 | кліковий запуск дав PATH без Homebrew · «немає php» | один рантайм, шлях до нього відомий |
| D96 | `2>/dev/null` ковтав причину зупинки | винятки, а не коди виходу |
| §13.7 | `«$VAR»` під `set -u` падає на багатобайтовому символі | немає word splitting |
| D62 | `clear`, кольори й `read` живуть тільки в PTY | те саме, але шар один |

## 4. Межі етапу

**IN SCOPE:** `cli/**` (усі `.sh`, крім названих винятків), `bin/tui.sh`,
`bdo`, `bdo.bat`, тести під перенесені частини, `docs/COMMANDS.md`.

**OUT OF SCOPE (не чіпати цим етапом):**

- `lib/**` · логіка вже на місці; будь-яка її зміна означає окреме завдання;
- `web/**` · сторінка звертається до `Actions`/`Runner`, а не до скриптів;
- `roles/*.md` і `config/roles.json` · промпти й моделі поза цим етапом;
- контракт Agent API;
- `scripts/agent-check.sh` як ОРКЕСТРАТОР gate лишається bash до останнього
  підетапу (він і є та перевірка, якою доводиться перенос).

## 5. Три речі, які НЕ мають аналога в PHP і вирішуються окремо

1. **tmux** (`cli/system/watch.sh`, `bin/tui.sh`) · видимість довгої роботи
   власнику. На Windows tmux немає. Рішення: підетап 7 вводить `Process`-шар,
   що на macOS/Linux лишає tmux, а на Windows пише в лог-файл і показує його
   сторінкою; вибір робить код за `PHP_OS_FAMILY`, а не власник.
2. **`clear`, кольори, `read` у PTY** (`bin/tui.sh`) · вікно в терміналі.
   Рішення: `posix_isatty(STDOUT)` там, де зараз `[ -t 1 ]`; на Windows вікно
   деградує до простого виводу без керування курсором, і це названо вголос.
3. **`curl`** (8 файлів) · HTTP до Agent API й Ollama. Рішення: підетап 2
   вводить `lib/Http/Client.php` на `curl`-розширенні PHP із фолбеком на
   потоки; зовнішній `curl` більше не потрібен.

## 6. Порядок підетапів

Порядок обраний за РИЗИКОМ і залежностями: спершу те, що не торкається запису
в PROD, останнім · сам драйвер. Кожен підетап лишає набір ПРАЦЮЮЧИМ.

### Підетап 1 · шов запуску: `Cli\Kernel`

**Статус:** прийнято · рев'ю 2026-09-08. Доказ: `help` побайтово збігається з
доміграційним еталоном із `843df59` (7 487 байт, `cmp` код 0); `env` віддає
stderr і код підпроцесу без змін; три саботажі відтворені рев'юером незалежно й
усі три валять `tests/cli-kernel.sh`; `tests/command-registry.sh` зелений без
правок; `phpstorm lint_files` · 0 ERROR. Коміти `8bd0338` і `113b66f`.

**Мета.** Один вхід у PHP, який приймає argv і віддає код виходу, щоб наступні
підетапи переносили команди по одній, а `./bdo` лишався тим самим для власника.

**Робота.** `lib/Cli/Kernel.php` (розбір argv, реєстр команд із
`cli/command-registry.json`, коди виходу), `lib/Cli/Command.php` (інтерфейс),
`lib/Cli/Output.php` (stdout/stderr, кольори за `posix_isatty`). `bdo` для
перенесених команд кличе `php cli/bdo.php <argv>`, для решти · старий шлях.

**Критерії.** `./bdo help` і `./bdo env` ідуть через Kernel; решта команд
працює без змін; `./bdo gate full` зелений.

**Перевірка.** `tests/cli-kernel.sh`: невідома команда → код 2 і текст
українською; порожні аргументи → довідка; коди виходу збігаються зі старими.

**Фальсифікація.** Зламати мапу команд так, щоб `help` пішов у стару гілку ·
тест мусить упасти.

### Підетап 2 · HTTP: `lib/Http/Client.php`

**Статус:** прийнято · рев'ю 2026-09-08, коміт `86cd48e` (corrective до
`79f93f8`). Доказ, зміряний рев'юером незалежно: мертвий порт дає код 7 за
0.076 с проти 0.038 с у старого клієнта · коди виходу тотожні;
`tests/terminology-chunks.sh` повернувся до 60 с (регресійне значення на
`113b66f` · 58 с, під дефектом не завершувався за 90 с); `./bdo gate full` ·
passed за 199 с; `phpstorm lint_files` · 0 ERROR; жоден із 17 викликачів не
змінений. Усі чотири саботажі відтворені рев'юером і ВСІ валять тест за 2-3 с,
включно з 404, який під `79f93f8` ловився зависанням, а не падінням.

Історія дефекту лишається в плані навмисно. `79f93f8` містив BLOCKER:
чорний список повторів у `RetryPolicy` повторював «connection refused», через
що один offline-виклик коштував 570 с замість 0.7 с, а `./bdo gate full` став
недосяжним. Виправлено білим списком: транспорт · лише curl-код 28, HTTP ·
рівно 408, 429, 500, 502, 503, 504 (`lib/Http/RetryPolicy.php:27,31`).

**Борг цього підетапу закритий.** Коміт спершу пройшов із `--no-verify`, бо
промпт рев'юера диктував повідомлення дослівно, а `.githooks/commit-msg`
вимагає опису й блоку `Файли:`. За рішенням власника 2026-09-08 повідомлення
виправлено amend-ом (гілка не була запушена), hook прийняв його штатно, хеш
змінився на `86cd48e`. Причина закрита в `docs/ai-workflow/PROMPTS.md`.

**Мета.** Прибрати зовнішній `curl` (9 файлів, 19 згадок у `cli/**`).

**Робота.** Клієнт із таймаутами, повторами, ідемпотентністю
(`lib/Api/IdempotencyKey.php` уже є), журналом запитів. Перенести
`cli/api/http-request.sh`, `glossary-resolve.sh`, `write/moderation-queue.sh`.

**Критерії.** `./bdo api` і `./bdo capabilities` працюють через новий клієнт;
жодного `curl` у перенесених файлах; журнал запитів той самий за формою.

**Перевірка.** `tests/http-client.sh` на локальному PHP-сервері: таймаут,
403/404/500, повтор, ідемпотентний ключ у заголовку. Плюс `./bdo api` на
живому ключі.

**Інваріант, який легко порушити:** ключ API не потрапляє ні в лог, ні в
повідомлення винятку. Це вже було: `bash -x` показав ключ у виводі.

**Контракт шва: перелік, зміряний рев'юером на `113b66f`.** 17 файлів кличуть
`cli/api/http-request.sh` 29 разів; жоден із них не має права змінитися.
Непідтриманий прапорець ламає живий прогін МОВЧКИ, тому перелік нижче є
критерієм приймання, а не побажанням. Прапорці, які МУСЯТЬ працювати:

- `-fsS` (22 виклики), `-sS` (3), окремо `-s`, `-f` · будь-яка комбінація;
- `-H <заголовок>`, ДО ТРЬОХ разів в одному виклику: `X-API-Key`,
  `Content-Type: application/json`, `Idempotency-Key`
  (`cli/write/write-translations.sh:138`);
- `-X POST` (5 викликів);
- тіло чотирма формами, вони НЕ взаємозамінні: `--data <рядок>`
  (`glossary-resolve.sh:34`), `--data @<файл>` (`validate.sh:43`,
  `write-translations.sh:138`), `-d <рядок>` (`moderation-queue.sh:90`),
  `--data-binary @<файл>` (`memory-lookup.sh:42`);
- `-o <файл>`, у тому числі `-o /dev/null` (`capabilities.sh:80`) і `-o` ПІСЛЯ
  URL (`memory-lookup.sh:42`);
- `-w '%{http_code}'` (`capabilities.sh:80`) · вивід рівно код без переводу;
- `-m 30` · ЛЕГКО ПРОПУСТИТИ. Він не видний у `rg 'http-request.sh' cli/`, бо
  живе всередині PHP-рядка: `cli/api/glossary-list.sh:59`.

**Три виклики нетипові: клієнт запускається з PHP через `exec()`** і шлях до
нього приходить рядком в `argv` · `glossary-list.sh:52,59`,
`term-notes-submit.sh:40,45`, `worker-payload.sh:126,128`. Звідси два наслідки,
які тест мусить покривати: файл `cli/api/http-request.sh` лишається ВИКОНУВАНИМ
за тим самим шляхом, а вивід читається `exec()` порядково · будь-який зайвий
рядок у stdout (попередження, діагностика) потрапить у `json_decode`. Обидві
точки підміни клієнта, `BDO_HTTP_CLIENT` (`glossary-list.sh:126`) і
`BDO_CONTEXT_HTTP` (`worker-payload.sh:126`), мусять працювати як раніше ·
на них тримаються тести.

**Фальсифікація (рев'юер відтворює сам).** Внести 404 до списку повторюваних
кодів; прибрати маскування `X-API-Key`; пропустити тіло через
`json_decode`/`json_encode`. Кожен саботаж мусить валити `tests/http-client.sh`.

### Підетап 3 · `cli/api/**` (15 файлів, 1 595 рядків)

**Мета.** Вибірка рядків, здатності, таксономія, глосарій · у PHP.

**Робота.** `lib/Cli/Command/Api/*`. `capabilities.sh` уже кешує за
відповіддю, а не за списком · зберегти цю поведінку дослівно.

**Критерії.** `./bdo fetch 20 <патч>` дає ТОЙ САМИЙ `rows.json`, що й раніше
(порівняння побайтово на тому самому патчі).

**Перевірка.** Доказ ідентичності: старий і новий шлях на однаковому вході,
`diff` файлів порожній.

**Поділ на три порції (рішення рев'юера 2026-09-08).** 1 595 рядків одним
колом · це той самий ризик, який уже стрельнув на підетапі 2, де дефект
приїхав у `main` разом із правильною частиною роботи. Порядок за ЗВʼЯЗНІСТЮ:
першою йде та порція, яку не кличе жоден скрипт, крім `bdo`.

- **3a · звіти (512 рядків):** `test-api.sh` (74), `row-context.sh` (52),
  `show-rows.sh` (69), `patch-info.sh` (123), `patches-overview.sh` (194).
  Зміряно: у кожного з пʼяти РІВНО один викликач · сам `bdo`. Шва до інших
  скриптів немає взагалі, тому порція перевіряє `Kernel` і `Http\Client` на
  живій роботі, нічим не ризикуючи.
  **Статус:** прийнято · рев'ю 2026-09-08, коміти `e77af8f` + corrective
  `3210702`. Саботаж, який у першому колі лишався ЗЕЛЕНИМ (`Output::color()`
  без ANSI), тепер валить набір за 4 с; у захопленому PTY по 4 escape-
  послідовності на кожен шлях; `./bdo gate full` passed за 205 с;
  `phpstorm lint_files` · 0 ERROR (рев'юер прогнав замість недоступного в
  агента MCP); пʼять вихідних `.sh` не змінені.
  **Рішення, яке діє на 3b і 3c:** байтова ідентичність СИЛЬНІША за правило
  «кольори беруться з `Output`». Старий `cli/api/test-api.sh:11` друкує ANSI
  БЕЗУМОВНО, навіть у конвеєр (перевірено: `./bdo api | grep -c $'\033'` дає 1),
  тому `TestApiCommand` навмисно копіює літерал замість `Output::color()`, і це
  названо коментарем у коді. Наслідок, який треба знати наперед: у цих командах
  кольору, залежного від TTY, немає взагалі, тож клас дефектів D62
  (`[ -t 1 ]` проти `posix_isatty`) тут не виникає, а цінність PTY-перевірки
  дає `cmp` захопленої панелі, а не color-probe.

  Історія першого кола лишається навмисно. `e77af8f` було НЕ ПРИЙНЯТО. Код
  правильний і
  це доведено: пʼять вихідних `.sh` не змінені, підпроцесів `curl`/`php` у
  класах немає, саботажі «зайвий пробіл», «код 0 замість помилки» і «витік
  ключа» відтворені рев'юером і валять тест за 1-3 с, `./bdo gate full` passed
  за 199 с, `phpstorm lint_files` · 0 ERROR, `BDO_ORCHESTRATOR=sh` повертає
  старий шлях. Причина невідповідності одна й вона в ПЕРЕВІРЦІ: PTY-порівняння
  ганяє `context`, у якої нуль ANSI в обох реалізаціях, тоді як фарбує єдина з
  пʼяти · `test-api.sh` (2 послідовності). Рев'юер вимкнув `Output::color()`
  глобально · набір лишився ЗЕЛЕНИМ, тобто перевірка кольорової парності не
  здатна впасти. Розбіжності сьогодні немає (`./bdo api` у справжньому tmux-PTY
  побайтово тотожний обома шляхами, разом із escape-послідовністю), але
  властивість не охороняється · за правилом набору це `немає перевірки`.
  Частина причини у промпті рев'юера: він вимагав PTY-прогін, не вимагаючи, щоб
  це була саме кольорова команда.
- **3b · глосарій і терміни (617 рядків):** `glossary-list.sh` (126, курсорна
  пагінація з захистом від зациклення й кеш лише після ПОВНОГО обходу),
  `glossary-concepts.sh`, `glossary-resolve.sh`, `term-notes-queue.sh`,
  `term-notes-describe.sh`, `term-notes-submit.sh`. Тут є ЗАПИС (пропозиції
  описів) і правило «порожнє поле ≠ невідоме поле», тому порція йде після 3a.
  **Статус:** прийнято · рев'ю 2026-09-08, коміти `83ad55c` + corrective
  `de1fa1f`. Два ERROR лінта закриті: `phpstorm lint_files` по
  `GlossaryListCommand.php` дає порожній результат, а тека кеша тепер готується
  як `is_dir || mkdir || is_dir` (останнє `is_dir` закриває гонитву двох
  прогонів), невдалий `rename` віддає код 1 із названою причиною. Обидва нові
  саботажі відтворені рев'юером і валять тест за 1 с. `./bdo gate full` passed
  за 193 с. СВІДОМЕ відхилення від байтової ідентичності, дозволене
  corrective-промптом: там, де старий bash мовчки повертав 0 на невдалому
  записі кеша, PHP повертає 1 · тому обидва нові сценарії в
  `tests/glossary-listing.sh:82-99` ганяються лише під `BDO_ORCHESTRATOR=php`.

  Історія першого кола лишається навмисно. `83ad55c` було НЕ ПРИЙНЯТО. Робота
  по суті зроблена й це доведено: `git diff` по шести `.sh` дає рівно +50/−0, тобто
  жодного рядка старого тіла не зачеплено; чотири грепи по тексту скриптів
  замінені поведінковими перевірками й жодного грепа по цих файлах не лишилось;
  сім місць виклику в рушії, `bdo` і `cli/command-registry.json` не змінені;
  три саботажі відтворені рев'юером і валять тест за 1-2 с («відсутнє поле
  `definition`» → `submit stdout`, «кеш після невдалого обходу» → `кеш зʼявився
  після невдалого обходу`, «вимкнений детектор курсора» → `зациклення має код
  4`); безпековий сценарій доведено НЕпорожнім інверсією stub-відповіді (тоді
  він падає з `очікувано proposal=0, отримано 1`); `./bdo gate full` passed за
  211 с. Причина невідповідності одна: `phpstorm lint_files` дає **2 ERROR** у
  `lib/Cli/Command/Api/GlossaryListCommand.php:51,119` (неперевірений
  `@mkdir`), а рівень ERROR блокує коміт. Агент не міг їх побачити · MCP у
  нього недоступний, лінт прогнав рев'юер.

  **Борг, зафіксований на 3c.** Заголовок-диспетчер у
  `cli/api/glossary-concepts.sh` виріс до 21 рядка й ДУБЛЮЄ правило TTL, яке
  вже є в `GlossaryConceptsCommand.php:31-34`: bash рахує вік кеша лише для
  того, щоб вирішити, чи підвантажувати `select-env.sh`. Заразом зʼявився новий
  контракт `BDO_CONCEPTS_ENV_UNAVAILABLE`. Поведінка вірна, обидві гілки вкриті
  тестами, а розходження дало б названу деградацію, а не псування даних, тому
  це борг, а не дефект. Він зникне сам на підетапі 8 разом із заголовками.
  Правило для 3c: заголовок-диспетчер не містить рішень · якщо в нього
  проситься логіка, це сигнал, що межу проведено не там.
- **3c · серце конвеєра (436 рядків):** **Статус:** прийнято · рев'ю
  2026-09-08, коміти `06fb96f` + corrective `c06b10a`. `phpstorm lint_files` ·
  0 ERROR; диференційна матриця звіряє обидва резолвери цілі на ВОСЬМИ
  комбінаціях (`tests/api-target-switch.sh:137-144`), і рев'юер відтворив два
  саботажі: змінене правило `hub-prod` валить тест за 0 с, змінена адреса PROD
  лише в PHP · за 1 с із текстом «shell і PHP розійшлися»; контракт шляху тепер
  перевіряється на ОБОХ виводах (`tests/cli-api-fetch.sh:125-127`); нова
  перевірка `check_php_runtime_guards` зареєстрована в `shell` і `full`, обидва
  її детектори рев'юер відтворив на саботажах; `./bdo gate full` passed за
  200 с. **Підетап 3 закритий цілком.**

  **Наслідок для підетапу 7.** Одне джерело правил вибору цілі зробити НЕ
  вдалось, і причина законна: PHP мусив би запускати `cli/system/select-env.sh`
  підпроцесом, а весь етап існує заради Windows без bash. Тому дві копії
  лишаються свідомо, під охороною диференційної матриці. Коли підетап 7
  перенесе `cli/system/**`, копію в bash треба ВИДАЛИТИ, а матрицю ·
  переспрямувати на новий єдиний резолвер, інакше борг стане вічним.

  Історія першого кола лишається навмисно. `06fb96f` було НЕ ПРИЙНЯТО. Структура бездоганна й це доведено: `numstat` по
  трьох `.sh` дає `4 0` для кожного (лише заголовок, нуль вилучень), `bdo`,
  реєстр і обидва файли драйвера не змінені, чотири файли процесу цього разу
  ввійшли в коміт (`git status --porcelain` порожній), `./bdo gate full` passed
  за 202 с, саботаж контракту шляху відтворений рев'юером і валить тест за 6 с.
  Три причини невідповідності. Перша: `phpstorm lint_files` дає ERROR у
  `CapabilitiesCommand.php:27` (`count()` у заголовку циклу). Друга:
  `ApiEnvironment.php` дублює правила вибору цілі з `cli/system/select-env.sh`,
  включно з двічі вписаною адресою PROD, а `tests/api-target-switch.sh` ганяє
  матрицю з семи комбінацій ЛИШЕ по bash-реалізації · PHP-копію перевірено на
  ОДНІЙ (`legacy`/`DEV`). Третя: сценарій контракту з драйвером
  (`tests/cli-api-fetch.sh:124`) читає `fetch.sh.out`, тобто вивід ЗАМОРОЖЕНОЇ
  реалізації, а не нової; властивість рятує лише сусіднє парне порівняння.

  Наслідок для флоу, а не для порції: два з трьох пунктів є повторенням уже
  баченого класу, тому закриті правилами · блок `ДУБЛЮВАННЯ ПРАВИЛА` в
  `PROMPTS.md` і розділ про IDE-інспекцію в `REVIEW.md`.

- **3c · серце конвеєра (436 рядків):** `fetch-rows.sh` (164, 9 викликачів),
  `capabilities.sh` (186, кеш за відповіддю, а не за списком), `validate.sh`
  (86). Найбільший шов і найбільша ціна помилки · останніми.

### Підетап 4 · `cli/prepare/**` і `cli/quality/**` (17 файлів, 1 996 рядків)

**Мета.** Payload ролей і механічні перевірки · у PHP.

**Робота.** Ці скрипти вже майже повністю `php -r`; перенос механічний.

**Критерії.** payload кожної ролі побайтово той самий; `./bdo gate shell`
зелений; `tests/prompt-payload-contract.sh` проходить без змін.

**Інваріант:** payload роль отримує ФАЙЛОМ. Переказ payload дав 174 порушення
контракту (D16, D17, D36, D39) · нова реалізація не має права збирати payload
у памʼяті й передавати рядком.

**Поділ на три порції (рішення рев'юера 2026-09-08).** Критерій поділу цього
разу зміряний точно: перевірок, які звіряють ТЕКСТ вихідних скриптів, у підетапі
шістнадцять, і одинадцять із них припадають на сам `worker-payload.sh`. Тому
першою йде тека з ОДНИМ таким грепом, останнім · файл із одинадцятьма.

- **4a · `cli/quality/**` (7 файлів, 487 рядків, 1 греп).** **Статус:**
  прийнято · рев'ю 2026-09-08, коміт `7729628`. `numstat` дає `4 0` на кожен із
  семи `.sh`; `phpstorm lint_files` · 0 ERROR З ПЕРШОГО РАЗУ (уперше за етап);
  усі пʼять класів `lib/Quality/**` викликаються, жодного правила не переписано
  заново; греп `fix-policy.jsonl` замінено справжньою поведінкою · тест подає
  русизм у `fix`, доводить відмову `FixPolicy` і запис причини в журнал
  (`tests/mechanical-before-qa.sh:85-98`); рев'юер відтворив саботаж складу
  половин `mechanical-split` · падає за 0 с; `./bdo gate full` passed.
  Дрібниця, яка НЕ блокує: сценарію `--require-all` у новому parity-тесті немає,
  але інваріант тримає наявний `tests/schema-provider-compat.sh` · при
  вимкненому запобіжнику він падає за 1 с (перевірено рев'юером).
- **4b · решта `cli/prepare/**` (533 рядки):** `build-schema.sh` (149, СІМ
  викликів із живого драйвера плюс два з `heal-plan.sh`), `memory-apply.sh`
  (106), `judge-payload.sh` (113, 1 греп), `glossary-gaps.sh` (64, єдиний файл
  підетапу без викликів із драйвера), `memory-lookup.sh` (62, ходить в API),
  `memory-expand.sh` (39).
- **4c · payload ролей (976 рядків, 15 грепів):** **Статус:** прийнято · рев'ю
  2026-09-08, коміт `9144c7b`. `numstat` `4 0` на кожен із чотирьох `.sh`;
  `phpstorm lint_files` · 0 ERROR; з пʼятнадцяти грепів по тексту не лишилось
  ЖОДНОГО (лишився один дозволений виняток `payload-shared-examples.sh:139`, і
  він грепає `run-drive.sh`, а не переносимий файл); `tests/cli-api-fetch.sh`
  пʼять прогонів рев'юера · `0,0,0,0,0`; `./bdo gate full` · passed за 192 с.
  D111 закритий вузькою нормалізацією позначки часу, і тест сам доводить, що
  нормалізація вузька (`assert_timestamp_normalizer_is_narrow`) · саме та
  властивість, яку легко втратити, роблячи нормалізацію ширшою.
  **Підетап 4 закритий цілком.**

  Межа рев'ю названа чесно: два з пʼяти саботажів рев'юер відтворити не зміг ·
  його патчі давали помилку розбору замість зміни поведінки. Порядок ключів і
  запис payload файлом лишились доведеними лише парним порівнянням із
  замороженою реалізацією, яке ловить їх за побудовою.

  Первинний перелік: `worker-payload.sh` (466),
  `qa-payload.sh` (221), `terminology-payload.sh` (164), `names-payload.sh`
  (125). Тут живе інваріант «payload роль отримує ФАЙЛОМ», тому порція
  остання.

### Підетап 5 · `cli/batch/**`, `cli/heal/**`, `cli/write/**` (9 файлів, 1 482 рядки)

**Статус:** прийнято · review 6.6.0 ACCEPTED: D151/D153 закриті raw 20-row shell/PHP dry-run identity proof; exact GitHub Actions run №29 (`34660478649`) зелений.

Прийнято рев'ю: перша non-PROD batch/heal порція `92cf048` + corrective
`2cc58bb`; `batch-clean` · `f785fcb`, `6.4.1`, CI success.

Останній PROD/API-write залишок підетапу 5 був:

- `cli/batch/batch-commit.sh`
- `cli/write/moderation-queue.sh`
- `cli/write/write-translations.sh`

Цю межу прийнято ланцюгом 6.4.5–6.4.7; фінальний D151/D153 dry-run identity proof прийнято review 6.6.0.

**Пакет 6.4.5:** переносить усі три файли залишку в PHP одним звʼязаним
write-пакетом. Статус підетапу 5 до ревʼю лишається `у роботі`. Усі write-
сценарії пакета працюють лише проти локального HTTP-stub у DEV; бойовий
PROD-запис у пакет НЕ входить і дозволяється лише після окремого ревʼю.

**Ревʼю 6.4.5:** `NEEDS CORRECTION`. Exact CI `c613d0f` червоний, а ревʼю
знайшло D119-D125: втрачений benchmark write-guard, руйнівну ізоляцію write-
тестів, фіктивне/неповне parity-покриття та fail-closed/provenance розходження.
Підетап 5 лишається `у роботі`; corrective 6.4.6 не робить PROD write.

**Ревʼю 6.4.6:** `NEEDS CORRECTION`. Exact CI `a7f53ec` зелений, але читання
write-path і перевірок знайшло D126-D128: moderation write обходив operational
blocker, config fallback втрачав `ollama` provenance, а D120 safety-check
фальсифікував неправильний alias. Corrective 6.4.7 виправляє обидва
orchestrator routes для blocker і не робить бойового PROD write.

**Ревʼю 6.4.7:** `ACCEPTED`. Exact CI `0d62fad` зелений; D126 блокує
PASS і moderation при `no_run/env_mismatch/quota`, D127 відновлює
`ollama/<model>` для config fallback, D128 охороняє фактичний production-root
alias до запуску write-тестів. Висновок про повне закриття підетапу пізніше скасовано аудитом: D151 вимагав відсутній dry-run identity proof.

**Ревʼю 6.6.0:** `ACCEPTED`. Commit `b11cf9a` закриває D151 і D153: 20-row shell/PHP `BDO_DRY_RUN=1` використовує той самий absolute state path після snapshot restore, raw `commit-report.txt` має однакові 495 bytes/SHA-256 і `cmp=0`, обидва request logs мають zero POST; chronology та whitespace falsifications падають на raw cmp. Production fix локальний до merged commit capture і canonical rollback count. Exact GitHub Actions run №29 (`34660478649`) зелений у `./bdo gate full`, `cli-api-fetch × 5`, `PHPStan level 0`. Підетап 5 прийнято цілком без бойового PROD write.

**Мета.** Пачка, ремонт, запис · у PHP.

**РИЗИК НАЙВИЩИЙ:** тут живе запис у PROD.

**Критерії.** Тестовий прогін (`BDO_DRY_RUN=1`) на 20 рядках дає ті самі
числа, що старий шлях; жодного запису в API під час перевірки.

**Перевірка.** Спершу `BDO_DRY_RUN=1` двічі: старим і новим шляхом, порівняння
`commit-report.txt`. Бойовий прогін · ЛИШЕ після рев'ю цього підетапу.

**Шлях відкату:** старі `.sh` лишаються в дереві до приймання підетапу 8;
перемикач · змінна `BDO_ORCHESTRATOR=php|sh`.

### Підетап 6 · `cli/run/**` (7 файлів, 1 773 рядки)

**Статус:** у роботі · Windows native smoke 6.6.2 прийнятий; пакет 6.6.3 переносить останній Stage6-owned wrapper `run-loop` і закриває D135. Підетап 6 чекає окремого Architect-review exact diff + CI для 6.6.3; `run-stop` і `step-report` лишаються Stage7.

**Пакет 6.5.0:** safe pilot підетапу 6 · `run-spec.sh` і `run-start.sh`.
Вони переносять preset/target foundation без driver loop, викликів моделей або
PROD write; rollback лишається через `BDO_ORCHESTRATOR=sh`.

**Ревʼю 6.5.0:** `NEEDS CORRECTION`. Exact CI `87cfa84` зелений, але D129
виявив фіктивну timestamp-нормалізацію й неповну перевірку причин invalid
RunSpec, а D130 - silent filesystem failures у `RunStartCommand`.
Corrective 6.5.1 не розширює migration scope і не переносить інші `cli/run/**`.

**Ревʼю 6.5.1:** `NEEDS CORRECTION`. Exact CI `52dc636` зелений; D129 і
D130 виправлені в production/test behavior, але D131 виявив залишкову
фіктивну нормалізацію: blocked `foreign awaiting_worker` міг змінити
`run-started-at`, а snapshot усе одно порівняв би `TIMESTAMP` з `TIMESTAMP`.
Corrective 6.5.2 змінює лише доказ, без production behavior.

**Ревʼю 6.5.2:** `ACCEPTED`. Exact CI `a0b0b19` зелений; D131 тепер
порівнює blocked `run-started-at` побайтово, bounded-нормалізація перевірена
двома незалежними sabotage. Production PHP corrective не змінював.
Ланцюг `6.5.0`-`6.5.2` прийнято як safe foundation підетапу 6.

**Пакет 6.5.3:** переносить `run-mode.sh` у `RunModeCommand` поверх уже
прийнятих `RunSpec`, `RunStartCommand`, `FetchRowsCommand`, `BatchNewCommand`
і `Workspace`. Human stdout fetch більше не є каналом передачі rows path.
Той самий пакет закриває D132: budget/goal state I/O стає fail-closed і в
PHP, і в тимчасовому rollback-shell. Driver loop, model calls і PROD write
до пакета не входять; підетап 6 лишається `у роботі`.

**Ревʼю 6.5.3:** `NEEDS CORRECTION`. Exact CI `4fbcbaf` зелений;
structured fetch seam і D132 fail-closed реалізовані, але D133 виявив
мовчазно звужений `cli-run-mode-parity`: helper передавав лише mode/size,
тому patch/domain і частина safety-ordering matrix не могли спростувати
регресію. Corrective 6.5.4 змінює лише proof і process evidence.

**Ревʼю 6.5.4:** `NEEDS CORRECTION`. Exact CI `25048fe` зелений і D133
matrix тепер передає повний argv, але D134 виявив два хибно спрямовані
proof: directory `run-batches.json` падав на read до перевірки failed write,
а size15 sabotage зупинявся раніше на size20 differential. Corrective 6.5.5
змінює лише test/evidence і не чіпає production behavior.

**Ревʼю 6.5.5:** `ACCEPTED`. Exact CI `0975933` зелений; D134 тепер
фізично доходить до budget write-result guard у shell і PHP, а narrow
size15 sabotage не перехоплюється валідним size20 case. Ланцюг
`6.5.3`-`6.5.5` прийнято як native `run-mode`.

**Пакет 6.5.6:** переносить цілий `run-drive.sh` у `RunDriveCommand`.
Це остання state-machine межа перед циклом і єдиний залишок підетапу 6,
який сам доходить до translation write. Пакет також закриває D136-D138:
retry budget, run goal і completion summary стають fail-closed у PHP та
rollback-shell. Бойовий PROD write не використовується для перевірки.

**Ревʼю 6.5.6:** `NEEDS CORRECTION`. Exact CI run №25 на `e5f6cbe` зелений, але branch-by-branch review знайшов D139-D147: invalid terminology response губився з advance chunk; ready term-note response не submit-ився; concepts refresh, resume guards і non-gating fallbacks перенесено неповно; post-write гілка D138 не була фактично перевірена; cleanup та exhausted QA quarantine розходились із rollback, а rollback offline goal помилково трактував невідомий remaining як доведений нуль. Green parity охоплював лише вибрані driver branches і не доводив перенесення state machine цілком.

**Forensic 6.5.6:** випадковий локальний `./bdo run drive` залишив persisted batch у `awaiting_terminology` із `child_dispatch:translation-terminology`, тобто наявний control-flow evidence не показує досягнення validate/commit branch. Точного transcript і before-snapshot немає, тому категоричне твердження про відсутність будь-якого API POST за інцидент не доведене; локальні state/output не відновлювались.

**Corrective 6.5.7:** виправляє лише підтверджені D139-D147 у межах `run-drive` і додає differential behavioral proof небезпечних state/retry/write/completion branches. `run-loop`, Stage7 і наступні підетапи не входять у corrective. Підетап 6 лишається `у роботі` до окремого Architect-review exact diff + CI.

**Ревʼю 6.5.7:** `NEEDS CORRECTION`. Exact GitHub Actions run №26 (`34532213472`) на `249d8a0` зелений, але executable review знайшов D148-D150. Native invalid `names-fixes` retry досі не rebuild-ив schema як rollback; D140 effective-threshold proof був недосяжний через ready-response fixture; D143 перевіряв лише term-notes queue, а прямі in-process optional calls не зберігали subprocess fail-soft semantics для `Throwable`. Тому green gate не доводить заявлену recovery/fallback matrix.

**Corrective 6.5.8:** виправляє лише D148-D150 у межах `run-drive`: останню names schema divergence, пропущені D142/D140 behavioral cases і повну explicit non-gating helper failure matrix. Frozen rollback `cli/run/run-drive.sh`, `run-loop`, Stage7 і PROD/API contract не змінюються. Підетап 6 лишається `у роботі` до окремого Architect-review exact diff + CI.

**Ревʼю 6.5.8:** `ACCEPTED`. Exact GitHub Actions run №27 (`34541372494`) на `98d7834` зелений: `./bdo gate full` і `cli-api-fetch × 5` завершились success. D148 доведений actual subset schema artifact після invalid names response; D149 має окремі negative/positive effective-threshold branches; D150 ганяє вісім explicit fail-soft helper boundaries із marker-backed shell nonzero та PHP exception injection. Ланцюг `run-drive` 6.5.6-6.5.8 прийнято.

**Infrastructure 6.5.9:** перед подальшим переносом вводить PHPStan 2.2.13 level 0 для `lib/**`, але лише якщо read-only baseline preflight уже зелений. Пакет не виправляє production PHP і не маскує findings baseline-ом або ignore-list; якщо preflight червоний, commit не створюється, а findings стають окремим corrective.

**Ревʼю 6.5.9:** `NEEDS CORRECTION`. Exact GitHub Actions run №28 (`34553561544`) на `0115e87` зелений у всіх трьох jobs: `./bdo gate full`, `cli-api-fetch × 5`, `PHPStan level 0`. PHPStan 2.2.13 level 0 прийнятий як detector: baseline preflight і final config green, targeted undefined-method sabotage дав `method.notFound`. Production PHP у commit відсутній. Повернення стосується лише process patch: current Stage5 status правильно відкрив D151, але старий review 6.4.7 лишив суперечливе «Підетап 5 закритий цілком». PHPStan у corrective не переробляється.

**Corrective 6.6.0:** D151 raw 20-row proof виявив D153: native commit capture втрачав stdout/stderr chronology, rollback quarantine count мав platform-dependent legacy `wc` padding. Пакет виправляє лише ці дві observable divergence і повторює raw proof без PROD/API write.

**Порядок після 6.6.0:** Windows native PHP smoke → `run-loop` разом із D135. Windows smoke не використовує `env` як positive proof, доки `EnvCommand` делегує `bash`; проміжний доказ бере `php cli/bdo.php help` і pure-native `run-spec status` із synthetic DEV env. Фінальний `bdo.bat` без WSL2 лишається критерієм Stage8.

**Ревʼю Windows preflight 6.6.1:** `NEEDS CORRECTION`. Exact GitHub Actions run №30 (`34661567183`) на `4e6efcc` мав три green jobs (`./bdo gate full`, `cli-api-fetch × 5`, `PHPStan level 0`), але `Windows native PHP smoke` впав до positive cases: sanitized PATH лишав PHP directory + `System32`, після чого `Get-Command bash` усе ще знаходив executable. Production PHP не змінювався, `main` лишився на `b11cf9a`; D154 фіксує дефект isolation proof.

**Corrective Windows preflight 6.6.2:** звужує sanitized PATH до directory абсолютного `php.exe` і більше ні до чого; `bash.exe` application мусить бути недоступним, pure-PHP `help` та `run-spec status` · green, shell-dependent `env` · nonzero negative control. Workflow і production PHP не змінюються; branch лишається preflight до окремого Architect-review exact Windows CI.

**Ревʼю Windows 6.6.2:** `ACCEPTED`. Exact preflight run №31 (`34662852607`) і exact main run №32 (`34664030930`) на тому самому `da14382` зелені у всіх чотирьох jobs: `./bdo gate full`, `cli-api-fetch × 5`, `PHPStan level 0`, `Windows native PHP smoke`. Windows log довів `PHP_OS_FAMILY=Windows; help=0; run-spec-status=0; env-negative=1; bash=absent`. D154 закритий; detector прийнятий на `main`.

**Пакет 6.6.3:** переносить останній Stage6-owned `run-loop` у `RunLoopCommand`: envelope-рішення й spin/batch safety живуть у PHP; `run-drive`, `run-mode` і model client викликаються fixed PHP argv без shell command string, timing пишеться напряму через `StepTimes`. Frozen shell loop лишається rollback. `step-report.sh` не переноситься й до Stage7 лишається fail-soft visibility bridge. Той самий пакет закриває D135 центральним `bdo::print_header()` regression без пересування wrapper headers. Підетап 6 не приймається до окремого Architect-review exact diff + CI.

**Межа visibility:** `cli/run/run-stop.sh` і `cli/run/step-report.sh`
переносяться з підетапом 7, а не з driver. Перший прямо делегує
`cli/system/watch.sh`/tmux, другий визначає ширину через `/dev/tty` і `stty`;
обидва залежать від Stage7 process/visibility design.

**Мета.** Драйвер і цикл · у PHP.

**Інваріант, який легко порушити саме тут:** ПОРЯДОК КРОКІВ ТРИМАЄ КОД. Конверт
(`child`, `retry`, `continue_run`, `blocked`) лишається тим самим за формою;
жодне рішення «що далі» не переїжджає в промпт ролі.

**Критерії.** `tests/driver-loop.sh` проходить БЕЗ змін сценаріїв · він і є
доказ, що конверт не змінився.

### Підетап 7 · `cli/system/**` (14 файлів, 2 039 рядків) і видимість

До цього підетапу також входять `cli/run/run-stop.sh` і
`cli/run/step-report.sh`: їхній перенос неможливо коректно відділити від
watch/process і terminal-visibility abstraction.

**Мета.** Сервер сторінки, сесії, значок, вікно · у PHP; крос-платформна
видимість замість tmux.

**Робота.** `lib/Process/Runner.php`: на macOS/Linux · tmux, на Windows ·
відвʼязаний процес із логом. Вибір за `PHP_OS_FAMILY` у КОДІ.

**Критерії.** `./bdo watch loop` працює на macOS; на Windows той самий виклик
дає лог, який видно сторінкою; `tests/watch-session.sh` і `tests/tui-live.sh`
проходять на macOS без змін.

### Підетап 8 · вхідні точки й прибирання

D135 входить у пакет 6.6.3: central `bdo::print_header()` отримує behavioral regression разом із `run-loop`, тому Stage8 не має окремого D135 fix і займається фінальними entrypoints та видаленням rollback-shell. Приймання D135 і Stage6 визначає review 6.6.3.

**Мета.** `bdo` стає тонким (пошук php → `php cli/bdo.php`), `bdo.bat` працює
БЕЗ WSL2, старі `.sh` видаляються, `BDO_ORCHESTRATOR` прибирається.

**Критерії.** `rg -l '\.sh' cli/ | wc -l` → 0 (крім `scripts/`); Windows-запуск
перевірений власником на реальній машині; `./bdo gate full` зелений.

**Блокер етапу:** цей підетап неможливо закрити з macOS · потрібна перевірка
на Windows. Див. `docs/plans/backlog/2026-09-05_CROSSPLATFORM_CHECK.md`.

### Підетап 9 · тести

**Мета.** `tests/**` (7 895 рядків bash) · на PHP, щоб gate працював на
Windows.

**Робота.** Робиться ПІСЛЯ 1-8 і окремим рішенням: до того тести на bash є
незалежним доказом переносу. Переписати їх раніше означало б перевіряти нове
новим.

## 7. Наскрізні інваріанти (перевіряються в КОЖНОМУ підетапі)

1. `./bdo gate full` зелений; нова перевірка ФАЛЬСИФІКОВАНА.
2. Формат файлів `state/**` не змінюється: сторінка й вікно читають їх без
   змін, інакше поверхні розійдуться.
3. Журнали (`model-calls.jsonl`, `write-log.jsonl`, `journal.jsonl`) не
   змінюють форму; `write-log.jsonl` не переписується ніколи.
4. Кожен вихід дає МАШИНОЧИТАНУ причину; порожній вивід не є відповіддю.
5. Секрети лишаються лише в `.env`; ключ не потрапляє в лог і в текст винятку.
6. Набір лишається робочим після кожного підетапу · власник має продовжувати
   перекладати щодня.

## 8. Означення готовності етапу

- підетапи 1-8 у стані `прийнято`;
- `./bdo` працює на macOS і на Windows без WSL2 (перевірено власником);
- єдина зовнішня залежність · PHP CLI; `jq`, `curl`, `tmux` не потрібні для
  роботи (tmux лишається необовʼязковою зручністю на Unix);
- `./bdo gate full` зелений на обох ОС;
- жодного `.sh` у шляху виконання;
- живий прогін на 50 рядках пройдено новим шляхом і числа збігаються зі
  старими в межах, названих у звіті.
