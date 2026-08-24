# Agent API: ендпоінти, які вживає цей набір

Довідник саме про те, що набір реально викликає. Повний контракт API (усі
параметри, коди помилок, семантика полів) живе в СЕРВЕРНОМУ проєкті ·
`docs/AGENT_TRANSLATION_API.md` від `TRANSLATE_PROJECT_ROOT`. Тут не
дублюється: при розбіжності діє серверна документація.

Це технічна довідка для primary-агента, розробника та діагностики, **не основний
користувацький workflow**. Власник не запускає наведені CLI-команди вручну:
primary виконує їх усередині agent flow.

## Базове

| Що | Значення |
|---|---|
| База | `BDO_ENV=PROD` · `BDO_API_BASE_PROD` або production default; `BDO_ENV=DEV` · `BDO_API_BASE_DEV`; застарілий `BDO_API_BASE` ігнорується |
| Автентифікація | заголовок `X-API-Key: <ключ>` |
| Формат | JSON; відповідь у конверті `data` / `meta` / `error` |
| Ліміти | 120 запитів/хв; денна квота ЗАПИСАНИХ рядків · з `GET /me` |
| Середовище | одна константа `BDO_ENV=PROD\|DEV`, див. [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) |

Розбір конверта · `Bdo\Translate\Api\Response`, підказки за кодами помилок ·
`Bdo\Translate\Api\ErrorCodes`. Свій `curl` в обхід штатних команд заборонений:
разом із ним губляться перевірки identity й повноти пачки.

## Читання

### `GET /me`

Хто ми, що можемо, скільки лишилось квоти. Викликається перед кожним записом і
першим у smoke-перевірці.

Важливі поля: роль, `effective_abilities` (для машинного шару потрібне
`translations:write-machine`), `rows_remaining_today`.

    ./bdo api

### `GET /guide` і `GET /taxonomy`

Довідкові: `guide` · машинна інструкція від сервера, `taxonomy` · перелік
доменів і семантичних типів (`domain`, `semantic_type`), за якими фільтрується
вибірка. Обидва в `./bdo api`.

### `GET /patch/summary?patch=active`

Скільки в патчі рядків і скільки з них без перекладу. `snapshot_id` активного
патча повертається в `meta`.

    ./bdo patch            # активний
    ./bdo patch 3          # конкретний знімок

### `GET /patches`

Перелік знімків: `snapshot_id`, `patch_number` (номер патча в грі), `is_active`,
`status`, `source_kind`, дати `published_at`/`imported_at`/`activated_at`/
`accepted_at`, блок `changes` (added, changed, removed) і `rows`
(total, translatable, untranslated, states). Додано на сервері 2026-08-24.

Кількість рядків, доступних для конкретного ШАРУ, звідси не береться:
`rows.states` рахує рядок за найвищим наявним шаром, тому рядок із manual і без
machine лежить у `manual`. Для точної цифри потрібен окремий швидкий запит
`GET /rows?patch=N&missing=machine&limit=1&include_total=1`.

Огляд обома джерелами одразу:

    ./bdo patches                    # усі патчі: без machine і без manual
    ./bdo patches 5 machine          # останні пʼять, лише ШІ-шар
    ./bdo patches all manual --full  # + всього рядків і стани перекладу

`--full` не є типовим навмисно: `GET /patch/summary` на великому патчі рахує
довго · виміряно 87 секунд на патчі з 12937 рядків, тоді як
`GET /rows?...&include_total=1` відповідає за секунди.

На сервері без `GET /patches` команда не падає, а деградує до старого шляху:
перебір знімків від активного вниз, без номера й дати.

Виміряно 2026-08-24: в активному патчі 6 лишався ОДИН рядок без
machine-перекладу, у патчі 5 · два, у патчі 3 · 442, у патчі 1 · 29927. Тобто
«нема що перекладати» стосується активного патча, а не корпусу.

### `GET /rows`

Головна вибірка. Повертає рядки з identity, джерелом, класифікацією, глосарієм і
обмеженнями.

| Параметр | Навіщо |
|---|---|
| `limit` | розмір пачки; серверна стеля 50 |
| `patch=active` | лише активний патч; замість `active` приймається числовий `snapshot_id` (`patch=3`), тому працювати можна з будь-яким, зокрема закритим патчем |
| `missing=machine` | немає машинного перекладу |
| `missing=manual` | немає ручного перекладу |
| `missing=both` | немає жодного |
| `state=stale` | джерело змінилось після перекладу |
| `exclude_proposed=1` | відкинути рядки з відкритою пропозицією |
| `domain=`, `semantic_type=` | категорія за `GET /taxonomy` |
| `diff=added` | лише нові рядки патча |
| `include_total=1` | додати загальну кількість у `meta` |
| `fields=` | які блоки віддавати |

`missing=machine` критичний: без нього вибірка щоразу віддає ТІ САМІ перші рядки
патча, бо заливка ШІ навмисно не рухає лічильник «опрацьовано». `./bdo fetch`
додає його сам, якщо в запиті немає жодного з `missing=`, `state=stale`,
`exclude_proposed=`.

`exclude_proposed=1` потрібен НЕ завжди. Він потрібен там, де пачка пише
ПРОПОЗИЦІЇ: інакше рядок, що вже чекає на людину, повертається у вибірку
нескінченно, а сервер відхиляє запис із `active_proposal_exists`. Для прогону в
ШІ-шар він не потрібен · шари незалежні, і відкрита ручна пропозиція машинному
запису не перешкоджає. Щоб узяти саме такі рядки, задайте `missing=` явно й не
додавайте прапорець.

    ./bdo fetch 15 "patch=active&missing=machine"                    # прогін у ШІ-шар
    ./bdo fetch 15 "patch=active&missing=machine&exclude_proposed=1" # коли пишемо пропозиції

### `GET /rows/{identity_hash}/context`

Уже затверджені переклади зі спільним терміном · найсильніший сигнал для моделі.
Один запит на рядок, і `./bdo payload worker` робить це ЗА ЗАМОВЧУВАННЯМ.

Три запобіжники проти марних викликів: проба перших 3 рядків (нічого не знайшли ·
решту не питаємо), повторне використання `context.json` теки пачки, і мовчазна
деградація без прикладів, якщо API недоступний.

    ./bdo context <identity_hash>
    ./bdo payload worker rows.json               # приклади типово
    ./bdo payload worker rows.json --no-context  # без прикладів і без запитів

### `POST /translations/memory`

Чи цей самий англійський оригінал уже перекладено деінде. Тіло ·
`{"identity_hashes": [...]}`, до 50 за раз. Денної квоти запису не витрачає.

На довгому прогоні цей крок закрив 54% рядків без жодного виклику моделі, і
головне тут не економія, а узгодженість: без нього модель вигадує свій варіант
там, де в проєкті вже є усталений.

    ./bdo memory find rows.json

### `POST /glossary/terms/resolve`

Чи є в каталозі канонічний відповідник для терміна. Тіло ·
`{"canonical_source": "...", "source_identity": {"identity_hash": "..."}}`.

Створювати нові терміни агентське API навмисно не вміє: це `POST /glossary` в
адмінці під правом `manage_glossary`.

Вручну цей ендпоінт кликати майже не потрібно: `./bdo payload terminology` робить
resolve по кожному терміну пачки сам, включно з повтором по `identity_hash` при
`blocked_identity`, і кладе результат у payload субагента.

    ./bdo payload terminology rows.json
    ./bdo glossary resolve "Reforge"                    # окремий термін вручну

## Запис

### `POST /translations/validate`

Серверна перевірка до запису: markup, placeholders, межі довжини, актуальність
джерела. Може повернути `status: repaired` разом із `repaired_text` · це
безкоштовна перша сходинка лікування.

    ./bdo validate items.json

### `POST /translations`

Єдиний запис. Канал визначає трійка полів:

| Канал | `layer` | `mode` | `auto_approve` | Куди потрапляє |
|---|---|---|---|---|
| `machine` | `machine` | `direct` | `true` | ШІ-шар напряму |
| `manual` | `manual` | `proposal` | `true` | чистий рядок: сервер схвалює лише за дозволом API-ключа, інакше лишає в черзі; проблемний завжди переходить у `proposal` |
| `proposal` | `manual` | `proposal` | `false` | завжди черга модерації, навіть якщо ключ має право схвалення |

`manual + direct` і `machine + proposal` сервер відхиляє. Прямий машинний запис
вимагає ролі `admin`/`super_admin` і здатності `translations:write-machine` ·
перевіряється через `GET /me` ДО побудови payload. Деталі й обґрунтування ·
[API_WRITE_CONTRACT.md](../API_WRITE_CONTRACT.md).

Запис не обходить перевірок: сервер зберігає `validation_result`, походження
`ai_api`, provider, model і ревізію.

    ./bdo commit rows.json candidate.json verdicts.json --write
    ./bdo write --channel proposal items.json

### `GET /translations/proposals` і `POST /translations/proposals/{id}/{approve|reject}`

Черга модерації: подивитись, схвалити, відхилити з причиною.

    ./bdo moderation
    ./bdo moderation --approve <id>
    ./bdo moderation --reject <id> --reason "..."

## Identity: те, що не можна вигадувати

Рядок ідентифікується четвіркою `source_language + key0 + record_id + key1`, а
API віддає її згорнутою в `identity_hash`. Він приходить з API і повертається
без змін · не будується локально й не «виправляється».

`./bdo items` є детермінованим гейтом саме тут: він звіряє `source_hash` проти
sha256 джерела, відмовляє на identity поза пачкою й на дублікаті, а з
`--require-all` вимагає повноти пачки. Збирати items власним скриптом заборонено
· так уже втрачали всі три перевірки одночасно.

## Коди помилок, які зустрічаються

| Код | Що робити |
|---|---|
| `stale_source` | джерело змінилось · перечитати рядок і перекласти заново |
| `markup_functional_breakage` | скопіювати всі токени `must_preserve` дослівно |
| `active_proposal_exists` | буває ЛИШЕ при записі пропозиції (`mode=proposal`): у цього автора вже є відкрита. Для машинного шару не виникає · додайте `exclude_proposed=1`, якщо пишете пропозиції |
| `save_failed` | найчастіше зайвий `\n`, якого немає в оригіналі |

Повний перелік із підказками · `lib/Api/ErrorCodes.php`.
