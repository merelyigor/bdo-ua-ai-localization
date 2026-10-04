# P61 · Терміни: тіньовий вимір покриття й перевірки за відмінками

| Поле | Значення |
|---|---|
| ID | P61 |
| Статус | draft |
| Створено | 2026-10-04 |
| Оновлено | 2026-10-04 |
| Автор | Claude (сесія планування) за запитом власника |
| Джерело | власник 2026-10-04: «що порадиш для термінів, щоб якісно перекладати й не поламати терміни, максимально без ручного втручання»; рада сесії планування (кроки 2–3 з шести). Серія · P61 → P62 → P63. |
| Реєстр | [README.md](README.md) |

## Навіщо

Терміни на паузі (власник, 2026-09-25: дані глосарія на PROD можуть бути
неактуальні). Пауза забороняє будувати рішення конвеєра на термінах, але
дозволяє ВИМІРЮВАТИ в тіні. Цей план нічого не міняє в перекладі: він дає
цифри, без яких P62 і P63 гадають.

Два питання:
1. Скільки назв гри в рядках пачки конвеєр НЕ бачить сьогодні. Терміни
   рядка приходять з блоку `glossary` `GET /rows` (індекс згадок сайту,
   `batch/row.py::Row.terms`). Сайт 2026-10-02 зробив `POST /glossary/match`,
   який знаходить усі терміни активного глосарія в будь-якому тексті.
2. Наскільки перевірка вжитку за лемами (`quality/morph.py::term_used`,
   pymorphy3) розходиться з чинним правилом основ (`pipeline/names.py::glossary_used`)
   і хто з них правий. Тіньове порівняння вже є на `/quality`
   (`web/screens/quality.py`, блок `morphology`), але без вердикту «хто правий».

## Goal

- На `/quality` видно: для останніх N рядків · скільки термінів дав індекс
  згадок, скільки дав `glossary/match`, які назви знайшов лише `match`.
- На `/quality` видно розбіжності правила основ і лем із прикладами, щоб
  власник чи наступна сесія вирішили, яке правило вмикати в P62.

## Definition of Done

- [ ] `api/endpoints.py::glossary_match(api, text)` за контрактом сайту (нижче); 403/404 → `None` (нема права або ендпоінта), без падіння екрана.
- [ ] Блок «покриття назв» на `/quality`: рядків перевірено, термінів з індексу, термінів з `match`, лише в `match` (до 20 прикладів: англійська назва · український відповідник · рядок).
- [ ] Блок «морфологія» показує приклади розбіжностей із текстом перекладу й очікуваною назвою, а не лише лічильник.
- [ ] Жоден крок конвеєра не змінився: payload ролей, перевірки, маршрути ті самі (diff `pipeline/**`, `batch/payload.py` порожній).
- [ ] Звірка в браузері, знімки `P61-*`, `uv run bdo gate` 0.
- [ ] Підсумок виміру · абзац у `Progress log` з цифрами; план видалено на закритті (D-59), рядок PROGRESS.

## Scope

`api/endpoints.py` (новий виклик), `web/screens/quality.py`, `web/templates/quality.html`, за потреби `app.css`.

## Non-goals

- Будь-яка зміна payload моделі, перевірок чи маршрутів (це P62).
- Пропозиції глосарія (це P63).
- Кеш `glossary/match` у SQLite: вимір робиться на кнопку, не на кожен прогін.

## Constraints

- Терміни на паузі: лише читання й показ. Жодного рішення конвеєра на цих даних.
- Ключ API · той, що вже в `.env` (потрібна здатність `glossary:read`); `.env` не читати й не правити.
- Тексти рядків іде лише на сайт проєкту; моделі в цьому плані не викликаються.
- Ліміт тексту `match` · 4000 символів; довший `source_text` · пропустити з причиною `too_long`, не обрізати.

## Контракт `POST /glossary/match` (сесія сайту, 2026-10-02)

- `POST /agent/v1/glossary/match`, `X-API-Key` зі здатністю `glossary:read`, тіло `{"text": "..."}` · непорожній рядок до 4000 символів.
- 200: `data.matches[] = {term: {...картка як у /glossary/terms: term_id, canonical_source, ukrainian, ukrainian_layer, category, entity_type, policy, status, severity, definition, gist, case_sensitive, scopes, forms...}, occurrences: [{start, length, text}]}`.
- Зсуви в символах (Python `text[start:start+length]`). Порядок · за першим `start`, потім `term_id`. Перекриття зняті: лишається довша назва. `case_sensitive: true` · точний регістр, решта · цілими словами без відмінювання.
- `meta: {count, text_length, offsets: "characters"}`.
- 400 `invalid_request`, `details.parameter = "text"` (порожній, не рядок) або `max: 4000`, `given`; 403 без `glossary:read`.
- На момент запису · лише локально в сайті (коміт сайту a0cdb54). Перед стартом · перевірити на DEV: 404 → план `blocked`, спитати сесію сайту.

## Context for the executor

- Робоча тека · корінь репо. Сервер власника · `http://127.0.0.1:<BDO_WEB_PORT>/` (спершу `/health`; стара версія · `uv run bdo web restart`, D-61).
- Ключові файли: `src/bdo_translate/batch/row.py` (`Row.terms`, `glossary_human`, `glossary_machine`), `src/bdo_translate/pipeline/names.py` (`glossary_used`), `src/bdo_translate/quality/morph.py` (`term_used`), `src/bdo_translate/web/screens/quality.py` (наявне тіньове порівняння), `src/bdo_translate/api/endpoints.py` (зразок · `machine_generations`, `glossary_resolve`), `docs/API.md` (розділи глосарія).
- Команди: `uv run bdo gate`, `uv run bdo version`, `uv run bdo web restart`.

## Instructions for the executor

1. Перед стартом: власник перевів план у `approved`. `draft` не виконується.
2. Код пише виконавець Бригади (`scripts/executor/exec.py`); головна сесія планує, звіряє, комітить (CLAUDE.md «Робота за планом»).
3. Кожен крок · звірка в браузері за протоколом §9.5 на DEV.
10. Прогалину вирішуй сам за порядком джерел довідника §5.5, рядок у `EXECUTOR_DECISIONS.md`.
10а. Зупинка лише перед необоротним: PROD-запис, `.env`, секрети, push, віддалені моделі, крім `go/*-free`.

## Step 1.1 — Клієнт `glossary_match`

- **Status:** pending
- **Depends on:** контракт на DEV (перевірити запитом; 404 → `blocked`).
- **Files:** `src/bdo_translate/api/endpoints.py`.
- **Why:** джерело повного переліку назв у тексті.
- **Do:**
  - [ ] `async def glossary_match(api, text) -> list[dict] | None`: 404/403 → `None`; `data.matches` не список обʼєктів → `ApiError(code="invalid_response")`.
  - [ ] Текст > 4000 символів не надсилати (повертати `None` з причиною на боці виклику).
- **Verify:** [ ] gate 0; [ ] виклик на DEV з рядком, де є відома назва (`[Dark Knight] Neidr`), повертає `Dark Knight` зі `start=1`.
- **Done when:** функція є, gate 0, виклик звірено на екрані кроку 1.2.
- **If it fails:** 403 · ключ без `glossary:read` → `blocked`, питання власнику (ключ у `.env` агент не міняє).
- **Notes:**

## Step 1.2 — Блок «покриття назв» на `/quality`

- **Status:** pending
- **Depends on:** 1.1.
- **Files:** `src/bdo_translate/web/screens/quality.py`, `src/bdo_translate/web/templates/quality.html`, за потреби `src/bdo_translate/web/static/app.css`.
- **Why:** побачити, скільки назв губить індекс згадок.
- **Do:**
  - [ ] Кнопка «виміряти покриття назв» (дія з реєстру екрана, D-07): бере останні до 50 рядків наявних пачок DEV (ті самі джерела, що вже читає `/quality`), для кожного `source_text` · `glossary_match`.
  - [ ] Порівняння за `canonical_source` (без регістру): з індексу (`Row.terms()`), з `match`, лише з `match`, лише з індексу.
  - [ ] Таблиця до 20 прикладів «лише в `match`»: назва · відповідник · `ukrainian_layer` · уривок рядка.
  - [ ] Відмова з причиною: `generations`-подібна підказка, коли `match` повернув `None`.
- **Verify:** [ ] у темній темі блок з цифрами; [ ] консоль без error, мережа без ≥ 400; [ ] знімки `.bdo/playwright/P61-1.2-1..3.png`.
- **Done when:** цифри видно, приклади клікабельні до `/history` рядка.
- **If it fails:** сайт повільний на 50 рядках · зменшити до 20 і записати в `Notes`.
- **Notes:**

## Step 1.3 — Приклади розбіжностей морфології

- **Status:** pending
- **Depends on:** —
- **Files:** `src/bdo_translate/web/screens/quality.py`, `src/bdo_translate/web/templates/quality.html`.
- **Why:** щоб вирішити, яке правило вмикати в P62, треба бачити, ХТО правий.
- **Do:**
  - [ ] Для кожної розбіжності `rule_match != morph_match` показати: очікувану назву, переклад (з підсвіткою знайденого), вирок кожного правила.
  - [ ] Лічильники: «лише основи кажуть так», «лише леми кажуть так».
- **Verify:** [ ] блок видно на DEV зі справжніми прикладами або «розбіжностей немає»; [ ] знімки `P61-1.3-*`; [ ] gate 0.
- **Done when:** власник може за 1 хв побачити, яке правило помиляється.
- **Notes:**

## Step 1.4 — Підсумок і закриття

- **Status:** pending
- **Do:** [ ] абзац у `Progress log` з цифрами (покриття, розбіжності, хто правий на прикладах) і рекомендацією для P62; [ ] PROGRESS; [ ] `git rm` плану й рядок реєстру (D-59).

## Final verification

`uv run bdo gate` 0; `/quality` на DEV показує обидва блоки; diff `src/bdo_translate/pipeline/**` і `batch/payload.py` за план · порожній.

## Rollback

Видалити блоки з `quality.html` і `quality.py` та функцію `glossary_match`; дані не змінюються.

## Progress log

- 2026-10-04 · план створено (draft) за порадою сесії планування; чекає `approved` власника і `glossary/match` на DEV.
