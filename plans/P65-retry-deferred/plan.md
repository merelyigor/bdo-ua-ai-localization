# Повтор відкладених рядків після відмови моделі

| Field | Value |
| --- | --- |
| ID | P65 |
| Status | blocked |
| Created | 2026-10-23 |
| Last updated | 2026-10-25 |
| Author | головна сесія власника |
| Source | власник 2026-10-23: провал PROD-сесії `20261022_232959` (`translation-worker truncated` на двох довгих пачках поспіль, 100 рядків у `deferred` без кнопки повернення) |
| Format | dev-standard 2 |

## Навіщо

Провалена сесія не має відновлення. Кнопка «продовжити» існує лише для паузи. Новий прогін відкладені рядки не бере. Власник лишається зі сотнею рядків, які видно лише в базі.

## Goal

На екрані невдалої сесії або порожньої вибірки є кнопка «повторити відкладені». Вона створює новий прогін із придатних відкладених рядків того самого середовища й режиму; до повтору входять тимчасові причини та `missing_item`. Для режиму пропозицій береться актуальний текст відкритої пропозиції. Успішно записаний рядок зникає з відкладених, а рядок, якого більше немає в API, отримує термінальну причину `row_not_found`. Перемикач «перекласти все» на активному патчі також добирає придатні відкладені перед новими рядками, щоб порожня перша пачка не лишала власника без перекладу.

## Definition of Done

- [x] Кнопка «повторити відкладені» видима лише на проваленій сесії або на завершеній порожній вибірці, якщо є придатні рядки того самого режиму й активного середовища; показує кількість придатних і загальну кількість у цій черзі.
- [x] Новий прогін бере лише рядки з `_RETRY_DEFER_REASONS` — тимчасові відмови моделі й `missing_item` — найстаріші першими; інші причини не бере. Зміна середовища блокує повтор на рівні екрана й обробника.
- [x] Перемикач «перекласти все» для активного патча без категорії передає `include_deferred`, спершу бере придатні відкладені, залишок пачки добирає з нових рядків, а кількість пачок покриває більшу з двох черг.
- [ ] Успішний запис рядка прибирає його з `deferred`; невдача лишає мітку з новою причиною.
- [ ] Ручний повтор у режимі пропозицій передає моделі чинний текст відкритої пропозиції; відсутній у джерелі рядок або proposal отримує термінальну причину й не утримує кнопку як повторюваний.
- [x] `/run` зберігає агрегати `fetch_diagnostics` для звичайного читання рядків і ручного повтору; звичайний автоматичний відбір пропозицій поки не входить до цього контракту. Причина порожньої або невдалої вибірки пояснюється без розкриття текстів чи хешів рядків.
- [x] Пункт відкладених із `plans/BACKLOG.md` («Успішно перекладений рядок лишається у відкладених») закрито цим планом і вилучено з `BACKLOG.md`.
- [x] `docs/OPERATIONS.md`, `docs/ARCHITECTURE.md`, `docs/CHECKLIST.md`, `docs/TROUBLESHOOTING.md`, `docs/WEB.md`, `docs/DECISIONS.md` і `docs/SECURITY.md` описують кнопку, межі, діагностику, приватність знімків і актуальні можливості браузерного протоколу.
- [x] `uv run bdo gate` дає код 0; візуальна звірка за `docs/WEB.md` пройдена на DEV для діагностики й на PROD у `dry_run` з явним дозволом власника для наявної черги: кнопка видима на проваленій і завершеній сесії з порожньою вибіркою, повтор виконується, знімки підтверджують очікуваний текст.
- [ ] All steps are `done` or `skipped` with a note explaining the skip.
- [ ] Final verification passed (see `Final verification`).

## Scope

- `store/repo.py`: метод `remove_deferred`.
- `store/models.py`, `store/repo.py`: модель і доступ до агрегатів `FetchDiagnostic`; вибір deferred за середовищем і режимом.
- `pipeline/commit.py`: очищення мітки після успішного запису.
- `pipeline/runner.py` (`RunGoal`), `pipeline/steps.py` (`step_fetch`): ручний повтор, режим «перекласти все» з відкладеними, актуальна proposal-версія, 404 і діагностика.
- `web/screens/start.py`, `web/templates/start.html`, `web/static/app.js`: передавання `include_deferred`, лічильник черги повтору й розрахунок пачок.
- `web/screens/run.py` + `web/templates/run.html`: дія, перевірка середовища й режиму, лічильники, пояснення порожньої вибірки й діагностика.
- `docs/OPERATIONS.md`, `docs/ARCHITECTURE.md`, `docs/CHECKLIST.md`, `docs/TROUBLESHOOTING.md`, `docs/WEB.md`, `docs/DECISIONS.md`, `docs/SECURITY.md`, `plans/BACKLOG.md`: опис контракту, приймання, браузерного протоколу, приватності знімків і вилучення закритого пункту.

## Non-goals

- Воскресіння проваленої сесії з того самого місця. Не робити.
- Порятунок часткових items із обрізаної відповіді (окремий пункт `BACKLOG.md`, D-17 без змін). Не чіпати.
- Автоматичний повтор у режимі пропозицій (`_TRANSIENT_DEFER_REASONS`) не змінювати. Для ручної кнопки дозволено додати `missing_item` у `_RETRY_DEFER_REASONS` за рішенням власника 2026-10-25; інші причини не додавати.
- Запис на PROD агентом. Заборонено правилами.

## Constraints

- Сервер власника не зупиняти: `uv run bdo web stop` лише для сервера, який підняв виконавець.
- Середовище `.env` не перемикати й не редагувати вручну. Браузерний тестовий прогін — лише `dry_run` на DEV. Окрема перевірка очищення після запису можлива лише в Step 4.2 після явного дозволу власника й за умови не більше п'яти придатних рядків загалом.
- `git add` лише поіменно; коміт за `docs/COMMITS.md`; push робить лише власник.
- Безкоштовні віддалені моделі лише `go/*-free`.
- Автотестів немає (D-08): доказ поведінки лише браузерна звірка.

## Planning conventions

| Rule | Source | How it is applied |
| --- | --- | --- |
| Плани живуть у `plans/`, реєстр генерує `plan.py` | `AGENTS.md` + `plans/README.md` | план створено `plan.py new`, статуси — `plan.py status` |
| Автономний режим | `AGENTS.md:35` (`<!-- dev-standard: autonomous -->`) | розбіжність плану з кодом у межах Scope виконавець вирішує сам із записом у `Notes` |
| Gate доводить статику; поведінку доводить браузерна звірка | `AGENTS.md` (розділ «Команди й гейти») | кожна фаза закінчується gate; поведінка — крок 4.1 за `docs/WEB.md` |
| Формат коміту й версії | `docs/COMMITS.md` | інструкція 11 |
| Еталон звірки кроку | `docs/WEB.md`, `docs/CHECKLIST.md` | крок 4.1 |

## Context for the executor

- **Working directory:** корінь репозиторію (`git rev-parse --show-toplevel`); всі команди звідси.
- **Key files:**
  - `src/bdo_translate/store/repo.py` — сховище; `deferred_hashes`, `deferred`, `add_deferred` (рядки 392–420); імпорт `delete` вже є (рядок 6).
  - `src/bdo_translate/store/models.py` — `Deferred.identity_hash` є первинним ключем (рядок 215).
  - `src/bdo_translate/pipeline/commit.py` — запис; успіх рядка вирішується в гілці `else` циклу `for (row, item), result in zip(accepted, written` (рядок 505).
  - `src/bdo_translate/pipeline/steps.py` — вибірка; `_TRANSIENT_DEFER_REASONS` для автоматичного повтору пропозицій, `_RETRY_DEFER_REASONS` для ручного повтору, `step_fetch` (рядок 233).
  - `src/bdo_translate/pipeline/runner.py` — `RunGoal` (рядок 196), `goal_json` зберігається в `RunSession`; відновлення з паузи читає ціль через `RunGoal(**goal_data)` (рядок 477).
  - `src/bdo_translate/web/screens/run.py` — екран; `resume_enabled` (рядок 167), дії `run_pause`, `run_stop`, `run_resume` (рядки 718–720).
  - `src/bdo_translate/web/templates/run.html` — кнопки; блок `resume_enabled` (рядки 24–31).
  - `src/bdo_translate/api/endpoints.py` — `row_by_hash` для довантаження рядка за хешем.
- **Canonical commands:**
  - Gate: `uv run bdo gate` → код 0.
  - Профілі: `uv run bdo gate secrets|docs|lint|types` → код 0.
  - Статус: `git status --short`; чисте дерево перед стартом.
  - Browser check: штатний браузер Codex (вкладка чату `iab` або вкладки Chrome власника через Computer Use, довідка в skill `codex-in-app-browser`); Playwright MCP лише коли штатний не вміє, з названою причиною.
- **Terms:** `deferred` — рядок у таблиці відкладених; тимчасова причина — член `_TRANSIENT_DEFER_REASONS`; ручний повтор бере ці причини та `missing_item` через `_RETRY_DEFER_REASONS` у новій сесії з прапорцем `retry_deferred`; `include_deferred` — звичайний прогін, який після нових рядків добирає ту саму придатну чергу.

## Assumptions and open questions

- Single package: кроки правлять спільні файли екрана, вибірки й запису; поділ дав би два пакети з тим самим ресурсом (DEV-сервер і база `.bdo`).
- Прапорець повтору живе в `RunGoal.retry_deferred` і `goal_json`; окремої таблиці не потрібно — якщо ні, крок 2.2 стає `blocked` із причинами.
- Прапорець «перекласти все» живе окремо в `RunGoal.include_deferred`, бо ручний повтор не має читати звичайні сторінки, а «перекласти все» має брати обидві черги; відкладені йдуть першими, щоб забита ними черга не змушувала щоразу перечитувати сторінки API.
- Розмір пачки повтору за замовчуванням дорівнює `min_rows_per_batch` (5), власник може підняти до `MAX_ITEMS` (50).
- Assumption: повторна сесія бере всі рядки ручного повтору (`_RETRY_DEFER_REASONS`) цілого середовища, а не лише однієї сесії — мітки `deferred` глобальні.
- Question: чи діє постійний дозвіл власника 2026-10-02 на запис не більше 5 рядків на DEV для кроку 4.2 — blocks Step 4.2 — recommended answer: так, власник підтверджує при затвердженні плану; інакше 4.2 `skipped` із причиною.

## Instructions for the executor

Read this section and the sections above before the first step. Re-read it after any interruption.

1. **Where to start.** Open `tasks.md` next to this file. Find the first step whose `Status` is not `done` or `skipped`. Read the `Progress log` and that step's `Notes`. Do not redo `done` steps. Start only when this plan is `approved` or `in-progress`. Before the first executed step, run `python3 <dev-standard>/scripts/plan.py status --root . P65 in-progress`. The command refuses while the git tree has uncommitted changes. If it refuses, stop and report the listed paths. Do not commit until the owner has reviewed the exact file list, diff, and commit message and explicitly approved that commit.
2. **Work one step at a time.** Read the whole step before acting. Follow its checkboxes in order. Do not start the next step before the current one is `done`. After a step is `done`, go to the next step in the same session. Do not report between steps. Stop on a stop condition, a `blocked` step, a question that needs the owner's answer, or a closed plan. The package executor does not edit plan files or commit. The coordinating session maintains statuses, notes, verification, and closure.
3. **Status of a step.** Set `Status: in-progress` when you begin, `done` when every checkbox is ticked and `Done when` holds, `blocked` when a stop condition occurs, `skipped` only when the step is proven unnecessary (write why in `Notes`).
4. **Checkboxes.** Change `- [ ]` to `- [x]` only after the action is actually done AND you saw its evidence (command output, file content). Never tick ahead, never tick based on expectation.
5. **Notes.** Under the step's `Notes`, add a dated line for every deviation, surprise, decision, workaround, failed attempt, or useful output summary: `- <YYYY-MM-DD>: <what happened> — <what you did>`. Keep notes short; do not paste long logs.
6. **Progress log.** After finishing or blocking a step, add one line to the `Progress log` at the end of `tasks.md` and update `Last updated` in this file.
7. **Verification is mandatory.** Run every `Verify` command exactly as written. Compare the result with the expected result. A step without matching evidence is not done.
8. **When something does not match.** Follow the step's `If it fails`. You may make the one fix it allows and retry once. If it still fails, or if a file, symbol, or command is not as the plan describes: set `Status: blocked`, write a note with the exact error and what you checked, and stop. Do not improvise a different approach.
9. **Stop and ask the owner** before: changing anything listed in `Non-goals` or `Constraints`; adding a dependency; changing a public API, schema, or data irreversibly; deleting files or data; any action that needs secrets or credentials.
10. **Never:** disable or weaken tests, suppress errors, edit files the plan does not mention without a note explaining why, or mark the plan `done` (dev-standard: close and delete it) while any Definition of Done item is unchecked.
11. **Git.** Використовуй `git add` лише з поіменованими шляхами. Заборонені `git add .`, `git add -A`, `git commit -a` і `--no-verify`. Повідомлення коміту відповідає `docs/COMMITS.md`. Push, теги й переписування історії виконує лише власник. Перед комітом покажи власнику точний список файлів, diff і повідомлення. Чекай на його явний дозвіл саме цього коміту.
12. **Finishing.** Спочатку виконай `Final verification`. Потім познач `Definition of Done` лише за наявності доказів. Перенеси довготривалі знання в документи, а незавершені пункти — у `BACKLOG.md`. Покажи власнику файл-ліст, diff і повідомлення коміту. Після явного дозволу на коміт виконай його. Далі запусти `python3 <dev-standard>/scripts/plan.py close --root . P65` окремо від коміту. Виправ кожен `REF` рядок і дочекайся окремого перегляду перед комітом видалення плану.

## Status legend

| Status | Meaning |
| --- | --- |
| `pending` | not started |
| `in-progress` | started, not finished |
| `done` | all checkboxes ticked, `Done when` holds, evidence seen |
| `blocked` | stopped on a stop condition; see `Notes` |
| `skipped` | proven unnecessary; reason in `Notes` |

---

## Final verification

- [x] Run `uv run bdo gate` → exit code 0.
- [x] Run `git status --short` → every modified path belongs to this plan's code, documentation, BACKLOG, plan, or generated plan registry; no unrelated changes are included. Other sessions' changes are listed in `Notes` of the review step and are not touched.
- [x] Візуальна звірка за `docs/WEB.md` пройдена: на DEV перевірено діагностику й відсутність кнопки на звичайній сесії; через відсутність DEV-черги власник 2026-10-25 явно дозволив read-only PROD `dry_run`, де кнопка видима на завершеній порожній вибірці, повтор із 25 пачок завершився, 3–5 знімків залишено в чаті, консоль не має нових `error`, мережа без статусів ≥ 400.

## Rollback

Revert the plan's commits (`git revert` за хешами плану, без переписування історії). Окремий прапорець не потрібен: без натискання кнопки поведінка та вибірка лишаються старими.

## Out of scope / follow-ups

- (порожньо)
