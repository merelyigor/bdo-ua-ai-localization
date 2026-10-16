# P61 — Tasks

Plan: [plan.md](plan.md).


## Phase 1 — Тіньовий вимір покриття й перевірки за відмінками

- **Objective:** на `/quality` видно покриття назв (індекс згадок проти `glossary/match`) і розбіжності правила основ та лем із прикладами; конвеєр не змінюється.
- **Acceptance criteria:** виконано всі пункти `Definition of Done`; `pipeline/**` і `batch/payload.py` без змін.
- **Verification:** кроки 1.1–1.4 і `Final verification`.
- **Parallel group:** none

#### Step 1.1 — Клієнт `glossary_match`

- **Status:** pending
- **Depends on:** контракт на DEV (перевірити запитом; 404 → `blocked`).
- **Files:** `src/bdo_translate/api/endpoints.py`.
- **Why:** джерело повного переліку назв у тексті.

**Do:**
- [ ] `async def glossary_match(api, text) -> list[dict] | None`: 404/403 → `None`; `data.matches` не список обʼєктів → `ApiError(code="invalid_response")`.
- [ ] Текст > 4000 символів не надсилати (повертати `None` з причиною на боці виклику).

**Verify:**
- [ ] gate 0.
- [ ] Виклик на DEV з рядком, де є відома назва (`[Dark Knight] Neidr`), повертає `Dark Knight` зі `start=1`.

**Done when:** функція є, gate 0, виклик звірено на екрані кроку 1.2.

**If it fails:** 403 · ключ без `glossary:read` → `blocked`, питання власнику (ключ у `.env` агент не міняє).

**Notes:**
- (none yet)

#### Step 1.2 — Блок «покриття назв» на `/quality`

- **Status:** pending
- **Depends on:** Step 1.1
- **Files:** `src/bdo_translate/web/screens/quality.py`, `src/bdo_translate/web/templates/quality.html`, за потреби `src/bdo_translate/web/static/app.css`.
- **Why:** побачити, скільки назв губить індекс згадок.

**Do:**
- [ ] Кнопка «виміряти покриття назв» (дія з реєстру екрана, D-07): бере останні до 50 рядків наявних пачок DEV (ті самі джерела, що вже читає `/quality`), для кожного `source_text` · `glossary_match`.
- [ ] Порівняння за `canonical_source` (без регістру): з індексу (`Row.terms()`), з `match`, лише з `match`, лише з індексу.
- [ ] Таблиця до 20 прикладів «лише в `match`»: назва · відповідник · `ukrainian_layer` · уривок рядка.
- [ ] Відмова з причиною: `generations`-подібна підказка, коли `match` повернув `None`.

**Verify:**
- [ ] У темній темі блок з цифрами.
- [ ] Консоль без error, мережа без ≥ 400.
- [ ] Знімки `.bdo/playwright/P61-1.2-1..3.png`.

**Done when:** цифри видно, приклади клікабельні до `/history` рядка.

**If it fails:** сайт повільний на 50 рядках · зменшити до 20 і записати в `Notes`.

**Notes:**
- (none yet)

#### Step 1.3 — Приклади розбіжностей морфології

- **Status:** pending
- **Depends on:** none
- **Files:** `src/bdo_translate/web/screens/quality.py`, `src/bdo_translate/web/templates/quality.html`.
- **Why:** щоб вирішити, яке правило вмикати в P62, треба бачити, ХТО правий.

**Do:**
- [ ] Для кожної розбіжності `rule_match != morph_match` показати: очікувану назву, переклад (з підсвіткою знайденого), вирок кожного правила.
- [ ] Лічильники: «лише основи кажуть так», «лише леми кажуть так».

**Verify:**
- [ ] Блок видно на DEV зі справжніми прикладами або «розбіжностей немає».
- [ ] Знімки `P61-1.3-*`.
- [ ] gate 0.

**Done when:** власник може за 1 хв побачити, яке правило помиляється.

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)

#### Step 1.4 — Підсумок і закриття

- **Status:** pending
- **Depends on:** Step 1.2, Step 1.3
- **Files:** `plans/P61-terms-shadow-measure/plan.md` (видалення), `plans/README.md`

**Do:**
- [ ] Абзац у `Progress log` з цифрами (покриття, розбіжності, хто правий на прикладах) і рекомендацією для P62.
- [ ] `git rm` плану й рядок реєстру (D-59).

**Verify:**
- [ ] `uv run bdo gate` → код 0; файла плану й рядка реєстру немає.

**Done when:** підсумок виміру записано, план видалено тим самим комітом (D-59).

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)


## Progress log

- 2026-10-04 · план створено (draft) за порадою сесії планування; чекає `approved` власника і `glossary/match` на DEV.
