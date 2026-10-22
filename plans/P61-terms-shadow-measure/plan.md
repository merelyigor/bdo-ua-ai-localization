# P61 · Терміни: тіньовий вимір покриття й перевірки за відмінками

| Field | Value |
|---|---|
| ID | P61 |
| Status | draft |
| Created | 2026-10-04 |
| Last updated | 2026-10-04 |
| Author | головна сесія власника (сесія планування) |
| Source | власник 2026-10-04: «що порадиш для термінів, щоб якісно перекладати й не поламати терміни, максимально без ручного втручання»; рада сесії планування (кроки 2–3 з шести). Серія · P61 → P62 → P63. |
| Format | dev-standard 1 |

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
- [ ] Підсумок виміру · абзац у `Progress log` з цифрами; план видалено на закритті (D-59).

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

## Assumptions and open questions

- Single package: кроки 1.2 і 1.3 правлять спільні `quality.py` і `quality.html`, а 1.2 залежить від 1.1; паралельних пакетів немає.

## Instructions for the executor

1. Перед стартом: власник перевів план у `approved`. `draft` не виконується.
2. Код пише делегований виконавець за глобальним skill `brygada`; головна сесія веде план, звіряє й комітить.
3. Кожен крок · звірка в браузері за протоколом звірки `docs/WEB.md` на DEV.
4. Режим `autonomous` skill dev-standard: розбіжність плану з кодом у межах Scope вирішуй сам і записуй у `Notes` кроку; стоп — перед необоротною дією, дією поза Scope або з секретами.
## Final verification

`uv run bdo gate` 0; `/quality` на DEV показує обидва блоки; diff `src/bdo_translate/pipeline/**` і `batch/payload.py` за план · порожній.

## Rollback

Видалити блоки з `quality.html` і `quality.py` та функцію `glossary_match`; дані не змінюються.
