# P60 · Покоління покращення ШІ-шару: видно й можна перепокращити

| Поле | Значення |
|---|---|
| ID | P60 |
| Статус | in-progress |
| Створено | 2026-10-02 |
| Оновлено | 2026-10-02 |
| Автор | Claude (сесія планування) за запитом власника |
| Джерело | власник 2026-10-02: бачити, які рядки ким, коли й якою моделлю покращені, навіть однією моделлю в різні дні, і вибирати скопом покоління для повторного покращення. Контракт сайту · повідомлення сесії сайту 2026-10-02. Рядок `чекає` у `BACKLOG.md`. |
| Реєстр | [README.md](README.md) |

## Контракт сайту (2026-10-02)

1. `client_run` на рівні запиту `POST /translations`, шаблон `[A-Za-z0-9._:-]{1,64}`
   (інакше 400 `details.parameter=client_run`); зберігається в ревізії (і в
   reaffirm-ревізії, і в пропозиції); `meta.client.run`. Validate не пише.
2. Фільтри за ПОТОЧНОЮ ШІ-ревізією в `GET /rows` і `/rows/facets`:
   `machine_client_run` (csv), `machine_model`, `machine_provider`,
   `machine_client_version` (точні), `machine_updated_after` (≥; з `_before` · `[after, before)`).
3. `GET /rows/machine-generations` з тими самими фільтрами: `data[]` ·
   `{client_name, client_version, provider, model, prompt_version, origin,
   client_run, legacy_day, first_revised_at, last_revised_at, rows}`, найновіші
   першими, кеш 10 хв, `limit` 50 (≤ 200).
4. `client_run` у кожній версії `GET /rows/{hash}/history` і в `fields=layers`.
5. Legacy (`client_run=null`) групуються ще й за `legacy_day` (YYYY-MM-DD,
   Europe/Kyiv). Вибір legacy-покоління · `machine_client_version`/`machine_model`
   + `machine_updated_after/before` по межах дня.
6. НЕВІДОМІ параметри `GET /rows` сервер МОВЧКИ ІГНОРУЄ (не 400). Старий PROD
   на `machine_client_run` віддасть рядки без фільтра · прогін покращив би не те
   покоління. Тому фільтри поколінь вмикаються ЛИШЕ коли
   `GET /rows/machine-generations` = 200 (до деплою 404). Невідоме поле в тілі
   запису старий сервер ігнорує · `client_run` можна слати одразу.

## Goal

- Кожен запис несе `client_run` = id сесії прогону.
- На «Почати прогін» для `improve` · таблиця поколінь і вибір одного покоління
  як джерела пачок; лічильники категорій рахуються з тим самим фільтром.
- `/history` показує прогін кожної версії.

## Definition of Done

- [ ] `write` шле `client_run` (id сесії) у кожному записі.
- [ ] `machine_generations()` у `api/endpoints.py`: 200 → групи, 404 → «не підтримується».
- [ ] Вибір покоління можливий лише коли сервер підтримує зведення; `Runner.start`
  повторно перевіряє підтримку й відмовляє `generations_unsupported`, інакше
  ніколи не шле `machine_client_run`/`machine_model`/… у `/rows`.
- [ ] `/history` · `client_run` у версіях.
- [ ] Звірка після деплою сайту (лише читання на PROD: таблиця поколінь, лічильники,
  `/history`); знімки `P60-*`; gate 0. План видалено на закритті.

## Step 1.1 — `client_run` у записі й у `/history`

- **Status:** in-progress
- **Files:** `api/endpoints.py` (`write`), `pipeline/commit.py` (виклики `write`), `web/screens/history.py`.
- **Verify:** gate 0; після деплою · `meta.client.run` у відповіді запису (`writes.response_json` на екрані виклику), `/history` показує прогін.
- **Notes:** 2026-10-02 · код є, gate 0: `write(client_run=…)`, у `step_commit` id сесії (перевірка шаблону сайту, інакше не шлемо), `/history` · «прогін <id>» перед датою. Ключ ідемпотентності рахується з items, `client_run` на нього не впливає.

## Step 1.2 — Зведення поколінь і вибір покоління на «Почати прогін»

- **Status:** todo
- **Files:** `api/endpoints.py`, `pipeline/runner.py` (`corpus_query`, `RunGoal`, `Runner.start`), `web/screens/start.py`, `web/templates/start.html`, за потреби `web/static/app.js`, `app.css`.
- **Verify:** до деплою · вибору покоління немає, решта «Почати прогін» як була; після деплою · таблиця поколінь, вибір змінює лічильники категорій.

## Step 1.3 — Звірка й закриття

- **Status:** todo

## Progress log

- 2026-10-02 · план створено за контрактом сайту; DEV сайт готує у два кроки.
