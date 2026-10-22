# Agent API: ендпоінти, які вживає цей набір

Довідник саме про те, що набір реально викликає. Повний контракт API (усі
параметри, коди помилок, семантика полів) живе в СЕРВЕРНОМУ проєкті й
недоступний звідси: це файл `AGENT_TRANSLATION_API.md` у репозиторії Agent API,
а не в цьому. При розбіжності діє серверна документація.

У цьому проєкті немає PHP-попередника: запити робить функція
`src/bdo_translate/api/endpoints.py` (її видно на екрані «API»), стан живе в
таблицях SQLite ([`ARCHITECTURE.md`](ARCHITECTURE.md)). Команди `./bdo …`,
класи PHP (`Row::…`, `Term::…`, `*Command`, `Quality\…`) і файли попередника
(`state/…`, `context.json`, `write_*.json`) тут **не існують**; імена класів PHP
у цій довідці — лише історичні посилання, а не механізми цього проєкту.

**Звірено з живим PROD API 2026-09-04.** Перевірялися конверт відповіді, склад
полів кожного ендпоінта, дозволені значення параметрів і форма помилки ·
запитами, а не читанням. Знайдені тоді розбіжності виправлені в цьому файлі.

Це технічна довідка для розробника та діагностики, **не основний
користувацький workflow**. Усі запити робить код конвеєра з браузерного
інтерфейсу; окремих команд для роботи з API у [`bdo`](../src/bdo_translate/cli.py)
немає.

## Базове

| Що | Значення |
|---|---|
| База | `BDO_ENV=PROD` · `BDO_API_BASE_PROD` або production default; `BDO_ENV=DEV` · `BDO_API_BASE_DEV`; застарілий `BDO_API_BASE` ігнорується |
| Автентифікація | заголовок `X-API-Key: <ключ>`; без заголовка `User-Agent` PROD повертає 403 ще до перевірки ключа (перевірено 2026-09-25) |
| Формат | JSON. Успіх: `success: true` + `data`, у частини ендпоінтів ще `meta`. Помилка: `success: false` + `error` (код), `message`, `hint`, `details` |
| Ліміти | `GET /me` → `limits`: `requests_per_minute`, `rows_per_day`, `rows_written_today`, `rows_remaining_today`, `quota_resets_at`. Цифри не зашивати в документацію · вони залежать від ключа |
| Середовище | одна константа `BDO_ENV=PROD\|DEV`, див. [DECISIONS.md](DECISIONS.md) і `.env.example` |
| Мережеві збої | усі виклики API йдуть через `api/client.py`: `tenacity`, `Retry-After`, вікно повторів `RETRY_WINDOW_SECONDS` (570 с) на операцію; далі відмова з кодом |

Розбір конверта · `api/client.py:parse_envelope`, підказки за кодами помилок ·
`api/errors.py:ERROR_HINTS`. Свій `curl` в обхід штатних команд заборонений:
разом із ним губляться retry, перевірки identity й повноти пачки. Повтор запису
безпечний завдяки стабільному `Idempotency-Key` пачки.

## Читання

### `GET /me`

Хто ми, що можемо, скільки лишилось квоти. Викликається перед кожним записом і
першим у smoke-перевірці.

Блоки відповіді: `user` (`id`, `name`, `email`, `role`), `key` (`prefix`,
`name`, `abilities`, `last_used_at`), `limits`, `batch` (`max_items`,
`max_rows_per_page`, `max_context_rows`), `writes` і `effective_abilities`.

`writes.channels` · СПИСОК обʼєктів `{layer, mode, allowed, result}`, а не мапа
за назвою каналу. Саме цю форму читає функція `write` у
`src/bdo_translate/api/endpoints.py`.

Для машинного шару потрібне `translations:write-machine` у `effective_abilities`.

### `GET /taxonomy`

Довідковий: перелік доменів і семантичних типів (`domain`, `semantic_type`), за
якими фільтрується вибірка. Вживають екрани «почати прогін» і «якість»
(`web/screens/start.py`, `web/screens/quality.py`).

### `GET /patch/summary?patch=active`

Скільки в патчі рядків і скільки з них без перекладу. `snapshot_id` активного
патча повертається в `meta`. Вживає `active_patch_snapshot_id`
(`api/endpoints.py`) — щоб дізнатися `snapshot_id` активного патча перед
resolve терміна.

### `GET /patches`

Перелік знімків: `snapshot_id`, `patch_number` (номер патча в грі), `is_active`,
`status`, `source_kind`, дати `published_at`/`imported_at`/`activated_at`/
`accepted_at`, блок `changes` (`added`, `changed`, `removed`, `reactivated`,
`source_records`) і `rows` (`total`, `translatable`, `untranslated`, `states`).
Додано на сервері 2026-08-24, поля звірені з живим API 2026-09-04.

Кількість рядків, доступних для конкретного ШАРУ, звідси не береться:
`rows.states` рахує рядок за найвищим наявним шаром, тому рядок із manual і без
machine лежить у `manual`. Для точної цифри потрібен окремий швидкий запит
`GET /rows?patch=N&missing=machine&limit=1&include_total=1`.

`GET /patch/summary` на великому патчі рахує
довго · виміряно 87 секунд на патчі з 12937 рядків, тоді як
`GET /rows?...&include_total=1` відповідає за секунди.

Вживають екрани «якість» і «почати прогін» (`web/screens/quality.py`,
`web/screens/start.py`).

Виміряно 2026-08-24: в активному патчі 6 лишався ОДИН рядок без
machine-перекладу, у патчі 5 · два, у патчі 3 · 442, у патчі 1 · 29927. Тобто
«нема що перекладати» стосується активного патча, а не корпусу.

### `GET /rows/{identity_hash}`

Один рядок за identity hash: `data.row` з тими самими блоками, що й у
`GET /rows`. Вживає `row_by_hash` (`api/endpoints.py`) — вибірка рядків для
режиму пропозицій, де API повертає лише `identity_hash`, а повний рядок треба
дочитати окремо.

### `GET /rows/{identity_hash}/history`

Історія версій шарів одного рядка: `data {identity_hash, source_hash,
layers{manual[], machine[]}, truncated{manual, machine}}`, до 50 версій на шар,
найновіші першими; невідомий хеш · 404. Вживає `row_history`
(`api/endpoints.py`) — екран «історія рядка» (`web/screens/history.py`).

### `GET /rows/facets`

Зрізи рядків за категоріями: `data.facets[]` `{domain, semantic_type, total}`,
`meta {total, groups, computed_at, cache_ttl_seconds: 600}`. Ті самі фільтри,
що й у `GET /rows`; `cursor`, `limit`, `fields`, `include_total` ігноруються.
Вживає `facets` (`api/endpoints.py`) — екран «почати прогін» для режимів
корпусу.

### `GET /rows/machine-generations`

Покоління ШІ-шару: `data.generations` — зведення по тегах поколінь. Вживає
`machine_generations` (`api/endpoints.py`) — екран «почати прогін» і вибір
покоління в режимі покращення. Коли сервер ще не має ендпоінта, функція
повертає `None` замість помилки: невідомі параметри `GET /rows` сервер
ігнорував би, тому фільтри поколінь без нього не надсилаються.

### `GET /rows`

Головна вибірка. Повертає рядки з identity, джерелом, класифікацією, глосарієм і
обмеженнями.

| Параметр | Навіщо |
|---|---|
| `limit` | розмір логічної пачки 5–100; клієнт розбиває запит на сторінки до серверної стелі 50 |
| `patch=active` | лише активний патч; замість `active` приймається числовий `snapshot_id` (`patch=3`), тому працювати можна з будь-яким, зокрема закритим патчем |
| `missing=machine` | немає машинного перекладу |
| `missing=manual` | немає ручного перекладу |
| `missing=both` | немає жодного |
| `state=stale` | джерело змінилось після перекладу |
| `exclude_proposed=1` | відкинути рядки з відкритою пропозицією |
| `domain=`, `semantic_type=` | категорія за `GET /taxonomy` |
| `diff=added` | лише нові рядки патча |
| `include_total=1` | додати загальну кількість у `meta` |
| `fields=` | які блоки віддавати: `core`, `coordinates`, `classification`, `layers`, `reference`, `tokens`, `constraints`, `glossary`, `patch`, `entity_identity`. Джерело правди · `GET /taxonomy` → `field_groups`; чуже значення дає `invalid_request` з переліком дозволених у `details.allowed` |

`missing=machine` критичний: без нього вибірка щоразу віддає ТІ САМІ перші рядки
патча, бо заливка ШІ навмисно не рухає лічильник «опрацьовано». Режими в
[`config/modes.json`](../config/modes.json) додають його самі: у запиті має
бути хоча б один із `missing=`, `state=stale`, `exclude_proposed=` **або**
`machine_client_name_not=`. Режим `improve` працює по корпусу й має саме
четвертий фільтр, без жодного з трьох названих.

`exclude_proposed=1` потрібен НЕ завжди. Він потрібен там, де пачка пише
ПРОПОЗИЦІЇ: інакше рядок, що вже чекає на людину, повертається у вибірку
нескінченно, а сервер відхиляє запис із `active_proposal_exists`. Для прогону в
ШІ-шар він не потрібен · шари незалежні, і відкрита ручна пропозиція машинному
запису не перешкоджає. Щоб узяти саме такі рядки, задайте `missing=` явно й не
додавайте прапорець. Наш режим `patch` усе одно ставить `exclude_proposed=1` (D-54): рядок, що
чекає рішення людини, не перекладається вдруге.

Вибірка пачки йде через `rows_page` (`api/endpoints.py`) зі сторінками по
`meta.next_cursor`; розмір пачки задає екран «почати прогін».

**Збіг терміна в рядку (серверна сесія 2026-09-25, на момент запису ще не
задеплоєно).** Кожен термін у блоці `glossary` отримує `source_span
{offset, length, text}` (у символах, не байтах), `match_kind: name|ordinary_word`
і `forms` · відмінкові форми, затверджені людиною (на проді їх мало, тому поле
здебільшого порожнє). Старі `matched_text`, `byte_offset`, `byte_length` не
змінились. Набір не подає моделі як закон термін зі збігом `ordinary_word`
(`Row.terms()` у `batch/row.py` відкидає такі терміни); відсутнє поле означає
«невідомо», і термін лишається вимогою.

### `GET /rows/{identity_hash}/context`

Уже затверджені переклади зі спільним терміном · найсильніший сигнал для моделі.
**Цей набір цю форму не вживає** · див. «Ендпоінти, яких код не вживає».

### `POST /rows/context`

Те саме, що `GET /rows/{identity_hash}/context`, але ПАЧКОЮ. Тіло ·
`{"identity_hashes": [...]}`, відповідь · `data.contexts` і `meta`
(`requested`, `found`).

Це єдиний вживаний шлях до контекстів: `rows_context`
(`api/endpoints.py`) читає їх частинами по 50 identity hash. Одиничний GET на
50 рядків коштував би 50 запитів, і на цьому крок деградував мовчки.

### `POST /translations/memory`

Чи цей самий англійський оригінал уже перекладено деінде. Тіло ·
`{"identity_hashes": [...]}`, до 50 за раз. Денної квоти запису не витрачає.

На довгому прогоні цей крок закрив 54% рядків без жодного виклику моделі, і
головне тут не економія, а узгодженість: без нього модель вигадує свій варіант
там, де в проєкті вже є усталений.

Вживає `memory_find` (`api/endpoints.py`) — крок «памʼять» у пачці.

### `POST /glossary/terms/resolve`

Чи є в каталозі канонічний відповідник для терміна. Тіло ·
`{"canonical_source": "...", "source_identity": {"identity_hash": "...", "source_snapshot_id": 0}}`.
`source_snapshot_id` обовʼязковий разом з `identity_hash` у `source_identity`;
контракт звірено з DEV 2026-09-26.

Створювати нові терміни агентське API навмисно не вміє: це `POST /glossary` в
адмінці під правом `manage_glossary`.

Вручну цей ендпоінт кликати майже не потрібно: крок «термінологія» робить
resolve по кожному терміну пачки сам, включно з повтором по `identity_hash` при
`blocked_identity`, додаючи `identity_hash` і `source_snapshot_id`, і кладе
результат у payload ролі.

Вживає `glossary_resolve` (`api/endpoints.py`) — крок «термінологія» у пачці та
екран «API».

### `POST /glossary/proposals`

ОПИС терміна як пропозиція, а не як факт. Тіло · `term_id`,
`canonical_source`, `ukrainian`, `source_identity` (`identity_hash`,
`source_snapshot_id`), `provider`, `model` і самі тексти `gist` (до 200
символів) та `definition` (до 4000). Термін, у якого опис уже є, пропускається
без запиту: затверджене не перезаписується. **Цей набір цей ендпоінт не
вживає** · див. «Ендпоінти, яких код не вживає».

## Запис

### `POST /translations/validate`

Серверна перевірка до запису: markup, placeholders, межі довжини, актуальність
джерела. Може повернути `status: repaired` разом із `repaired_text` · це
безкоштовна перша сходинка лікування.

Тіло · `layer`, `mode`, `auto_approve`, `auto_repair: true`, `client_name`,
`client_version`, `items`; для режиму покращення додатково `reaffirm: true`.
Вживає `validate` (`api/endpoints.py`) — крок записи в `pipeline/commit.py`.

Статус `skipped` з кодом `unchanged` («Такий самий текст у цьому шарі вже збережений», замір 2026-09-28) означає те саме, що `unchanged`: рядок чистий, запис нічого не змінить.

Перевірка йде тими самими `layer`/`mode`/`auto_approve`, що й запис каналом
прогону (типово `machine`); драйвер передає канал прогону. Канал пропозицій
на сервері суворіший до тегів оформлення, тож перевірка іншим каналом пропускала
рядки, які потім відхиляв запис (дефект 247 попередника). Прод приймає `mode` у `validate`
(перевірено 2026-09-25: невідоме значення дає HTTP 400).

Розбіжність глосарія в `details.glossary[]` з 2026-09-25 несе `blocking` і
`match_kind` (серверна сесія, ще не задеплоєно). Якщо `blocking: false` або
`match_kind: ordinary_word`, набір не робить із неї наказу «ужий «X»» ні в
підказці repair, ні в проході по назвах; без цих полів поведінка стара.

### `POST /translations`

Єдиний запис. Канал визначає трійка полів:

| Канал | `layer` | `mode` | `auto_approve` | Куди потрапляє |
|---|---|---|---|---|
| `machine` | `machine` | `direct` | `true` | ШІ-шар напряму |
| `manual` | `manual` | `proposal` | `true` | чистий рядок: сервер схвалює лише за дозволом API-ключа, інакше лишає в черзі; проблемний завжди переходить у `proposal` |
| `proposal` | `manual` | `proposal` | `false` | завжди черга модерації, навіть якщо ключ має право схвалення |

`manual + direct` і `machine + proposal` сервер відхиляє. Прямий машинний запис
вимагає ролі `admin`/`super_admin` і здатності `translations:write-machine` ·
перевіряється через `GET /me` ДО побудови payload.

Що саме дозволено ЦЬОМУ ключу, не вгадується: `GET /me` → `writes.channels`
віддає список фактично дозволених пар. Звірено 2026-09-04: там рівно дві ·
`{layer: machine, mode: direct, allowed: true, result: machine}` і
`{layer: manual, mode: proposal, allowed: true, result: manual, auto_approve: true}`.
Третій канал (`proposal`) відрізняється від другого не дозволом сервера, а нашим
власним `auto_approve: false` у запиті.

Деталі й обґрунтування · [API_WRITE_CONTRACT.md](API_WRITE_CONTRACT.md).

Запис не обходить перевірок: сервер зберігає `validation_result`, походження
`ai_api`, provider, model і ревізію.

Тіло · `layer`, `mode`, `auto_approve`, `provider`, `model`, `prompt_version`,
`auto_repair: true`, `strictness: standard`, `client_name`, `client_version`,
`items`; для режиму покращення додатково `reaffirm: true`. Заголовок
`Idempotency-Key` стабільний для тієї самої пачки, тому повторний запис не
створює дубля. Вживає `write` (`api/endpoints.py`) — крок записи в
`pipeline/commit.py`.

Відмова запису з 2026-09-25 (серверний `43fcaf2`, на проді) несе `retryable`
і для розмітки · `details.markup {missing:[{token,count}], extra:[{token,count}]}`
із кодами `markup_cosmetic_breakage` / `markup_caption_breakage`; `save_failed`
лишився лише для справжнього збою збереження. Набір:
- відмову з однозначним місцем тега виправляє `markup_repair` у
  `pipeline/commit.py` (зіпсований підпис, зайвий токен, якого немає в
  оригіналі, обгортка всього рядка) і записує однією другою спробою з ключем
  `<ключ>-markup`; результат другого запису пишеться в таблицю `writes` разом
  із першою спробою;
- `retryable: true` відкладає рядок до наступного прогону — в таблицю `deferred`,
  а не в карантин;
- решта, зокрема тег посеред речення, іде в карантин як і раніше.

### `GET /translations/proposals` і `POST /translations/proposals/{id}/{approve|reject}`

Черга модерації: подивитись, схвалити, відхилити з причиною.

Вживають `proposals`, `proposals_of_row`, `proposal_approve`, `proposal_reject`
(`api/endpoints.py`) — екрани «черга до людини» й «карантин і запис».

### `GET /translations/decisions`

Рішення людини щодо власних пропозицій ключа: `approved`, `edited`, `rejected`,
`superseded`, з `proposed_text`, `final_text`, `reason`, моделлю й часом.
Сторінки курсором `next_cursor`, фільтр `since`. Потрібна окрема здатність
ключа. Повідомлено серверною сесією 2026-09-25, ще не задеплоєно; набір цей
ендпоінт поки не вживає (див. «Ендпоінти, яких код не вживає»; план ·
калібрування судді рішеннями людини).

## Походження й режими корпусу

Контракт серверної сесії 2026-09-30. **DEV · задеплоєно 2026-09-30, PROD · задеплоєно
2026-10-01** (міграція застосована; `/rows/facets` і `/rows/{identity_hash}/history`
без ключа · 401; автосхвалені ШІ-пропозиції підписано як `ai_api`). Усе додаткове:
старі поля й формат `updated_at` не змінились. Невідомі поля тіла й
параметри старий сервер ігнорує, тому режим корпусу перед стартом перевіряє
`GET /rows/facets`: без нього старий сервер віддав би не ті рядки.

**Запис і перевірка.** `POST /translations` і `/translations/validate`
приймають необовʼязкові `client_name` (≤ 64) і `client_version` (≤ 32, порядок
X.Y.Z, суфікси `-rc`/`+build` відкидаються). Відповідь запису · `meta.client`.
Автосхвалений `manual/proposal/auto_approve=true` лягає в ручний шар з
`origin=ai_api`, моделлю й `client_*`. Схвалення автоматичне лише без
розбіжностей глосарія, інакше рядок лишається `pending`.

**`layers.manual|machine`, нові поля.**

| Поле | Тип і значення |
|---|---|
| `revision`, `revision_id` | int; `revision` з 1 у межах шару рядка |
| `created_at`, `revised_at` | ISO 8601 з поясом; «коли перекладено» · `revised_at` (`updated_at` оновлює масовий перерахунок актуальності) |
| `prompt_version`, `client_name`, `client_version` | string \| null |
| `source_hash`, `source_changed` | хеш джерела ревізії; bool \| null (null · слід невідомий) |
| `author`, `author_kind` | підпис автора (e-mail ніколи) · `import` \| `user` \| null |
| `written_by_me` | bool · акаунт власника ключа (не сам ключ) |

`core`: `first_seen_patch`, `changed_in_patch` (id знімків або null).
`origin` ревізії: `human`, `ai_api`, `localized_loc_import`, `legacy_unknown`.

**Нові параметри `GET /rows`.** `patch` необовʼязковий (без нього · весь
корпус). Невідоме значення · 400 `invalid_request` з `details.allowed`.
Будь-який `machine_*` вимагає непорожнього ШІ-шару.

| Параметр | Що відбирає |
|---|---|
| `machine_origin` | csv значень `origin` |
| `machine_author`, `machine_author_not` | `bosia` (легасі-імпорт, те саме, що `machine_provenance=legacy`) \| `me` |
| `machine_updated_before` | ISO 8601, порівнюється з `revised_at` ШІ-шару |
| `machine_client_version_lt` | X.Y.Z; ревізії без версії теж проходять |
| `machine_client_name`, `machine_client_name_not` | 1–64; для `_not` ревізії без назви теж проходять |
| `stale` | `machine` \| `manual` \| `any`; `state=stale` лишився як був |

Сортування немає (≈ 10 с на сторінку). Найстаріші · `machine_updated_before` +
курсор. `limit` 1–100, типово 20.

**`GET /rows/facets`.** Ті самі фільтри; `cursor`, `limit`, `fields`,
`include_total` ігноруються. Перший виклик на повному корпусі 3–16 с, далі
10 хв із кешу (окремо на набір фільтрів і акаунт). Форма відповіді · у розділі
«Читання».

**`GET /rows/{identity_hash}/history`.** Форма відповіді · у розділі «Читання».

**`GET /translations/proposals`, нові поля.** `revision`, `created_at`,
`origin` (`human` \| `machine_adoption`), `provider`, `model`, `prompt_version`,
`client_name`, `client_version`, `base {layer, revision_id, revision, is_current}`.

**Режими клієнта.** Ручний · `missing=manual&exclude_proposed=1`. Покращення ·
`machine_client_name_not=bdo-ua-translate-python`, легасі першим ·
`machine_author=bosia`; після зміни промптів · `machine_client_version_lt=<версія>`.
Актуалізація · `state=stale` (або `stale=machine`). Патч · як був.

## Ендпоінти, яких код не вживає

Ці ендпоінти існують на сервері, але `src/bdo_translate/api/endpoints.py` їх
не викликає. Тож вони **не є** частиною робочого механізму цього набору:

| Ендпоінт | Стан у коді |
|---|---|
| `GET /guide` | не вживається; довідковий, машинна інструкція від сервера |
| `GET /glossary/concepts` | не вживається; поняття гри не входять у payload (відкладено) |
| `GET /glossary/terms/list` | не вживається; повного переліку термінів набір не бере |
| `GET /glossary/terms?q=…&match=exact` | не вживається; стан одного терміна перед описом не перечитується |
| `POST /glossary/proposals` | не вживається; описи термінів як пропозиції не надсилаються |
| `GET /rows/{identity_hash}/context` | не вживається; контекст береться пачкою через `POST /rows/context` |
| `GET /translations/decisions` | не вживається; рішення людини ще не звірено |

## Identity: те, що не можна вигадувати

Рядок ідентифікується четвіркою `source_language + key0 + record_id + key1`, а
API віддає її згорнутою в `identity_hash`. Він приходить з API і повертається
без змін · не будується локально й не «виправляється».

Детерміновані гейти на identity робить код конвеєра, а не окрема команда:

- `write` у `api/endpoints.py` відмовляє на `identity_hash`, `source_hash` або
  `text`, що порожні чи не є рядками, і на `same_as_source`/`glossary_confirmed`,
  що не дорівнюють `true`;
- `validate` звіряє кількість і порядок результатів із порядком рядків пачки
  (`result_count_mismatch`, `result_order_mismatch`);
- `idempotency_key` у `pipeline/commit.py` будує стабільний ключ із
  `identity_hash`, `source_hash` і sha256 тексту, тому повторний запис тієї самої
  пачки не створює дубля.

Складати `items` власним скриптом заборонено: так уже втрачали всі три перевірки
одночасно. Рядок лише з `identity_hash` без `source_hash` і без `text` до
запису не доходить.

## Коди помилок, які зустрічаються

| Код | Що робити |
|---|---|
| `stale_source` | джерело змінилось · перечитати рядок і перекласти заново |
| `markup_functional_breakage` | скопіювати всі токени `must_preserve` дослівно |
| `markup_cosmetic_breakage` | зберегти теги `cosmetic` (колір, перенос) дослівно й у тій самій кількості. При `strictness=standard` (наш дефолт) рядок ЗАПИСУЄТЬСЯ, а код приходить у `data.results[].warning_codes`; при `strict` той самий код відхиляє рядок |
| `source_equivalent` | це англійський оригінал, а не переклад |
| `length_too_short` | переклад закороткий · вкластися у вікно constraints.length |
| `length_too_long` | переклад задовгий · вкластися у вікно constraints.length |
| `non_translatable` | рядок не перекладається, гра підставить оригінал |
| `invalid_request` | запит відхилено як неправильний · перевірити параметри запиту |
| `unauthorized` | ключ API не прийнято · перевірити ключ у .env |
| `forbidden` | ключ не має права на цю дію · потрібен ключ з відповідною роллю |
| `network_error` | немає зʼязку з API · перевірити мережу й адресу бази, повторити |
| `rate_limited` | зачекати до Retry-After |
| `daily_row_quota_exceeded` | квота вичерпана до київської півночі |
| `layer_busy` | шар зайнятий перебудовою каталогу, повторити |
| `timeout` | API не відповів вчасно · повторити пізніше |
| `not_json` | API повернув не JSON · перевірити адресу бази в .env |
| `retry_exhausted` | усі повтори вичерпано · перевірити зʼєднання й стан API, запустити знову |
| `active_proposal_exists` | буває ЛИШЕ при записі пропозиції (`mode=proposal`): у цього автора вже є відкрита. Для машинного шару не виникає · додайте `exclude_proposed=1`, якщо пишете пропозиції |
| `save_failed` | найчастіше зайвий `\n`, якого немає в оригіналі |

Повний перелік із підказками · `src/bdo_translate/api/errors.py` (`ERROR_HINTS`).
Що робити, коли відмова сталася під час прогону, · у
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
