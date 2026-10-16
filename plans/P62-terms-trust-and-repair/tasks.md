# P62 — Tasks

Plan: [plan.md](plan.md).


## Phase 1 — Рівні довіри, перевірка за відмінками, ремонт замість модерації

- **Objective:** назва-закон у перекладі завжди є (у будь-якому відмінку) або рядок не пишеться в шар; назва-порада не блокує рядок; порушення закону виправляє роль ремонту, людина отримує лише те, що двічі не вдалось.
- **Acceptance criteria:** виконано всі пункти `Definition of Done`; план `approved` лише після зняття паузи термінів власником.
- **Verification:** кроки 1.1–1.7 і `Final verification`.
- **Parallel group:** none

#### Step 1.1 — Рівень довіри терміна

- **Status:** pending
- **Depends on:** none
- **Files:** `batch/row.py` (або новий `quality/terms.py`).

**Do:**
- [ ] `term_trust(term)` за таблицею «Навіщо».
- [ ] Звірити на DEV, які поля (`severity`, `blocking`, `match_kind`, `policy`) реально є в блоці `glossary` рядка.
- [ ] Показ рівня на `/quality` поруч із термінами рядка.

**Verify:**
- [ ] На DEV рядок з людським і машинним терміном показує «закон» і «порада».
- [ ] Знімки `P62-1.1-*`.
- [ ] gate 0.

**Done when:** `term_trust` є єдиним місцем правила рівня довіри, рівень видно на `/quality`, gate 0.

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)

#### Step 1.2 — Перевірка закону за лемами

- **Status:** pending
- **Depends on:** Step 1.1, підсумок P61
- **Files:** `quality/defects.py`, `pipeline/names.py`, `quality/morph.py`.

**Do:**
- [ ] Дефект `glossary_law`, коли `term_used` (або правило, обране за P61) не знаходить назву-закон.
- [ ] Порада дефекту не дає.
- [ ] Людська мітка дефекту в `web/labels.py`.

**Verify:**
- [ ] Навмисно зламаний вхід (переклад без назви) на екрані перевірок показує `glossary_law`.
- [ ] «Темного лицаря» для «Темний лицар» · без дефекту.
- [ ] Знімки.
- [ ] gate 0.

**Done when:** `glossary_law` ловить відсутню назву-закон у будь-якому відмінку й не ловить пораду, gate 0.

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)

#### Step 1.3 — Повні назви в payload перекладача

- **Status:** pending
- **Depends on:** Step 1.1, P61 Step 1.1
- **Files:** `batch/payload.py`, `pipeline/steps.py`.

**Do:**
- [ ] Назви з `glossary/match`, яких немає в `Row.terms()`, додаються в `glossary`/`terms` payload з рівнем довіри.
- [ ] Кеш на сесію за `source_text` (SQLite, як `term_cache`, D-23), щоб не кликати сайт двічі.
- [ ] 404/403 · без доповнення, причина в журналі пачки.

**Verify:**
- [ ] Тестовий прогін DEV на `go/*-free`: у «Запит» перекладача видно додану назву.
- [ ] Знімки.
- [ ] gate 0.

**Done when:** назви з `glossary/match` потрапляють у payload перекладача з рівнем довіри, без `match` поведінка стара, gate 0.

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)

#### Step 1.4 — Ремонт з точною вказівкою

- **Status:** pending
- **Depends on:** Step 1.2
- **Files:** `pipeline/heal.py`, `roles/translation-repair.md`, `pipeline/commit.py` (причина черги).

**Do:**
- [ ] Дефект `glossary_law` дає ремонту вказівку «ужий «X» у відмінку, якого вимагає речення».
- [ ] Після 2 невдалих спроб · moderation з поясненням «назва «X» не вжита».
- [ ] Повторна механічна перевірка після ремонту.

**Verify:**
- [ ] Прогін із записом на DEV на пачці зі зламаною назвою: ремонт виправляє або рядок іде в чергу з поясненням; `/review` показує пояснення.
- [ ] Знімки.
- [ ] gate 0.

**Done when:** порушення закону виправляє ремонт, після двох невдалих спроб рядок іде в moderation з поясненням, gate 0.

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)

#### Step 1.5 — Сигнали відхилення від поради

- **Status:** pending
- **Depends on:** Step 1.1
- **Files:** `store/models.py`, `store/repo.py`, `pipeline/names.py` або `steps.py`, екран `/quality`.

**Do:**
- [ ] Таблиця `term_signal` (сесія, `identity_hash`, `canonical_source`, очікуване, фактичне, provider/model, час).
- [ ] Запис, коли переклад не містить пораду, а містить інший відповідник.
- [ ] Лічильник сигналів на `/quality`.

**Verify:**
- [ ] Після тестового прогону DEV сигнали видно на екрані.
- [ ] Знімки.
- [ ] gate 0.

**Done when:** відхилення від поради пишуться в `term_signal` і видно на `/quality`, gate 0.

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)

#### Step 1.6 — Промпти ролей

- **Status:** pending
- **Depends on:** Step 1.1
- **Files:** `roles/translation-worker.md`, `roles/translation-repair.md`, `roles/translation-judge.md`.

**Do:**
- [ ] «закон» · вжити обовʼязково у правильному відмінку; «порада» · вжити, якщо підходить за сенсом, інакше · кращий відповідник.
- [ ] Суддя не валить рядок за відхилення від поради.
- [ ] Без англійських кодів у тексті для людини.

**Verify:**
- [ ] Тестовий прогін DEV: суддя не шле в чергу рядки лише через пораду.
- [ ] gate 0.

**Done when:** три промпти розрізняють «закон» і «пораду», суддя не блокує через пораду, gate 0.

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)

#### Step 1.7 — Закриття

- **Status:** pending
- **Depends on:** Step 1.1, Step 1.2, Step 1.3, Step 1.4, Step 1.5, Step 1.6
- **Files:** `plans/P62-terms-trust-and-repair/plan.md` (видалення), `plans/README.md`

**Do:**
- [ ] `git rm` плану, рядок реєстру геть (D-59).

**Verify:**
- [ ] `uv run bdo gate` → код 0; файла плану й рядка реєстру немає.

**Done when:** план видалено тим самим комітом (D-59).

**If it fails:** стоп, питання власнику.

**Notes:**
- (none yet)


## Progress log

- 2026-10-04 · план створено (draft); чекає закриття P61 і зняття паузи термінів власником.
