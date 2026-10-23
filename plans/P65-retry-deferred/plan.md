# Повтор відкладених рядків після відмови моделі

| Field | Value |
| --- | --- |
| ID | P65 |
| Status | approved |
| Created | 2026-10-23 |
| Last updated | 2026-10-23 |
| Author | головна сесія власника |
| Source | власник 2026-10-23: провал PROD-сесії `20261022_232959` (`translation-worker truncated` на двох довгих пачках поспіль, 100 рядків у `deferred` без кнопки повернення) |
| Format | dev-standard 2 |

## Навіщо

Провалена сесія не має відновлення. Кнопка «продовжити» існує лише для паузи. Новий прогін відкладені рядки не бере. Власник лишається зі сотнею рядків, які видно лише в базі.

## Goal

На екрані прогону проваленої сесії є кнопка «повторити відкладені». Вона створює новий прогін лише з відкладених рядків із тимчасових причин. Успішно записаний рядок зникає з відкладених.

## Definition of Done

- [ ] Кнопка «повторити відкладені» видима лише на проваленій сесії з відкладеними рядками тимчасових причин; інакше її немає.
- [ ] Новий прогін бере лише відкладені рядки тимчасових причин, найстаріші першими; нетранзитивні причини не бере ніколи.
- [ ] Успішний запис рядка прибирає його з `deferred`; невдача лишає мітку з новою причиною.
- [ ] Пункт відкладених із `plans/BACKLOG.md` («Успішно перекладений рядок лишається у відкладених») закрито цим планом і вилучено з `BACKLOG.md`.
- [ ] `docs/OPERATIONS.md` описує кнопку й наслідок; `docs/TROUBLESHOOTING.md` у кроці 5 веде на кнопку.
- [ ] `uv run bdo gate` дає код 0; звірка на DEV (`dry_run`) за `docs/WEB.md` пройдена зі знімками.
- [ ] All steps are `done` or `skipped` with a note explaining the skip.
- [ ] Final verification passed (see `Final verification`).

## Scope

- `store/repo.py`: метод `remove_deferred`.
- `pipeline/commit.py`: очищення мітки після успішного запису.
- `pipeline/runner.py` (`RunGoal`), `pipeline/steps.py` (`step_fetch`): режим повтору відкладених.
- `web/screens/run.py` + `web/templates/run.html`: дія й кнопка з вибором розміру пачки.
- `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md`, `plans/BACKLOG.md`: текст і вилучення пункту.

## Non-goals

- Воскресіння проваленої сесії з того самого місця. Не робити.
- Порятунок часткових items із обрізаної відповіді (окремий пункт `BACKLOG.md`, D-17 без змін). Не чіпати.
- Зміна складу тимчасових причин (`_TRANSIENT_DEFER_REASONS`). Не чіпати.
- Запис на PROD агентом. Заборонено правилами.

## Constraints

- Сервер власника не зупиняти: `uv run bdo web stop` лише для сервера, який підняв виконавець.
- Середовище `.env` не перемикати й не редагувати вручну; тестовий прогін лише `dry_run` на DEV.
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
  - `src/bdo_translate/pipeline/steps.py` — вибірка; `_TRANSIENT_DEFER_REASONS` (рядок 167), `step_fetch` (рядок 233), фільтр `row.identity_hash in deferred` (рядок 260).
  - `src/bdo_translate/pipeline/runner.py` — `RunGoal` (рядок 196), `goal_json` зберігається в `RunSession`; відновлення з паузи читає ціль через `RunGoal(**goal_data)` (рядок 477).
  - `src/bdo_translate/web/screens/run.py` — екран; `resume_enabled` (рядок 167), дії `run_pause`, `run_stop`, `run_resume` (рядки 718–720).
  - `src/bdo_translate/web/templates/run.html` — кнопки; блок `resume_enabled` (рядки 24–31).
  - `src/bdo_translate/api/endpoints.py` — `row_by_hash` для довантаження рядка за хешем.
- **Canonical commands:**
  - Gate: `uv run bdo gate` → код 0.
  - Профілі: `uv run bdo gate secrets|docs|lint|types` → код 0.
  - Статус: `git status --short`; чисте дерево перед стартом.
  - Browser check: штатний браузер Codex (вкладка чату `iab` або вкладки Chrome власника через Computer Use, довідка в skill `codex-in-app-browser`); Playwright MCP лише коли штатний не вміє, з названою причиною.
- **Terms:** `deferred` — рядок у таблиці відкладених; тимчасова причина — член `_TRANSIENT_DEFER_REASONS`; повторна сесія — новий прогін із прапорцем `retry_deferred`.

## Assumptions and open questions

- Single package: кроки правлять спільні файли екрана, вибірки й запису; поділ дав би два пакети з тим самим ресурсом (DEV-сервер і база `.bdo`).
- Прапорець повтору живе в `RunGoal.retry_deferred` і `goal_json`; окремої таблиці не потрібно — якщо ні, крок 2.2 стає `blocked` із причинами.
- Розмір пачки повтору за замовчуванням дорівнює `min_rows_per_batch` (5), власник може підняти до `MAX_ITEMS` (50).
- Assumption: повторна сесія бере всі відкладені рядки тимчасових причин цілого середовища, а не лише однієї сесії — мітки `deferred` глобальні.
- Question: чи діє постійний дозвіл власника 2026-10-02 на запис не більше 5 рядків на DEV для кроку 4.2 — blocks Step 4.2 — recommended answer: так, власник підтверджує при затвердженні плану; інакше 4.2 `skipped` із причиною.

## Instructions for the executor

Read this section and the sections above before the first step. Re-read it after any interruption.

1. **Where to start.** Open `tasks.md` next to this file. Find the first step whose `Status` is not `done` or `skipped`. Read the `Progress log` at the end of `tasks.md` and that step's `Notes`. Start there. Do not redo `done` steps. Start only when the `Status` row of this file is `approved` or `in-progress`; the first executed step runs `python3 <dev-standard>/scripts/plan.py status --root . P65 in-progress` (`<dev-standard>` is the base directory of the `dev-standard` skill, shown by the client when the skill loads), which refuses while the git tree has any uncommitted change — then stop and tell the owner the listed paths; after it, commit this file with the regenerated registry `README.md`.
2. **Work one step at a time.** Read the whole step before acting. Do only what the step says, in the order of its checkboxes. Do not start the next step before the current one is `done`. After a step is `done`, go on to the next step in the same session without reporting to the owner in between. Stop only on a stop condition (instructions 8-9), a `blocked` step, a step that waits for an answer to a Question in `Assumptions and open questions`, or a closed plan. A commit, a push or a message to the owner inside a step is not a reason to stop. In a Brygada package the subagent does not edit this plan's files and does not commit: the main session does instructions 1, 3–6, 11, 12.
3. **Status of a step.** Set `Status: in-progress` when you begin, `done` when every checkbox is ticked and `Done when` holds, `blocked` when a stop condition occurs, `skipped` only when the step is proven unnecessary (write why in `Notes`).
4. **Checkboxes.** Change `- [ ]` to `- [x]` only after the action is actually done AND you saw its evidence (command output, file content). Never tick ahead, never tick based on expectation.
5. **Notes.** Under the step's `Notes`, add a dated line for every deviation, surprise, decision, workaround, failed attempt, or useful output summary: `- <YYYY-MM-DD>: <what happened> — <what you did>`. Keep notes short; do not paste long logs.
6. **Progress log.** After finishing or blocking a step, add one line to the `Progress log` at the end of `tasks.md` and update `Last updated` in this file.
7. **Verification is mandatory.** Run every `Verify` command exactly as written. Compare the result with the expected result. A step without matching evidence is not done.
8. **When something does not match.** Follow the step's `If it fails`. You may make the one fix it allows and retry once. If it still fails, or if a file, symbol, or command is not as the plan describes: set `Status: blocked`, write a note with the exact error and what you checked, and stop. Do not improvise a different approach.
9. **Stop and ask the owner** before: changing anything listed in `Non-goals` or `Constraints`; adding a dependency; changing a public API, schema, or data irreversibly; deleting files or data; any action that needs secrets or credentials.
10. **Never:** disable or weaken tests, suppress errors, edit files the plan does not mention without a note explaining why, or mark the plan `done` (dev-standard: close and delete it) while any Definition of Done item is unchecked.
11. **Git.** `git add` лише поіменно (`git add <шлях>`; заборонені `git add .`, `-A`, `commit -a`, `--no-verify`). Коміт: `git commit -F <файл> -- <шляхи>`; повідомлення за `docs/COMMITS.md` (`Версія: X.Y.Z`, мітка `Задача:`, перелік `Файли:`); версію підняти в `pyproject.toml`, `src/bdo_translate/__init__.py`, `uv.lock` (`uv lock`, перевірка `uv lock --check`). Push, теги й переписування історії робить лише власник. Коміти й пуш виконує головна сесія, не пакетний виконавець.
12. **Finishing.** In this order: run `Final verification`, tick the `Definition of Done`, move knowledge that must outlive the plan into the project's permanent documents and anything unfinished to `BACKLOG.md` of the plans directory, commit the final plan files with those documents, then run `python3 <dev-standard>/scripts/plan.py close --root . P65`, fix every `REF` line, and commit the deletion with the `NEXT` command it prints, the message naming the plan ID. The script never commits. Run `close` and `git commit` as separate calls: the commit hook judges the state before the command.

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

- [ ] Run `uv run bdo gate` → exit code 0.
- [ ] Run `git status --short` → only this plan's own files (`plan.md`, `tasks.md`) and its documents are uncommitted — instruction 12 commits them next; other sessions' changes that appeared during the plan are listed in `Notes` of the review step and are not touched.
- [ ] Звірка повтору на DEV за `docs/WEB.md` пройдена: кнопка видима на проваленій сесії, повторна сесія виконується, знімки (3–5 файлів `.bdo/playwright/P65-*` або знімки в чаті) показують очікуваний текст, консоль без `error`, мережа без неочікуваних статусів ≥ 400.

## Rollback

Revert the plan's commits (`git revert` за хешами плану, без переписування історії). Окремий прапорець не потрібен: без натискання кнопки поведінка та вибірка лишаються старими.

## Out of scope / follow-ups

- (порожньо)
