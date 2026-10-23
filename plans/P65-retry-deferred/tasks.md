# P65 — Tasks

Plan: [plan.md](plan.md).

## Phase 1 — Preparation and baseline

- **Objective:** confirm the starting state so new failures can be told apart from existing ones.
- **Acceptance criteria:** plan is `in-progress` on a clean tree; baseline gate result recorded in notes.
- **Parallel group:** none

#### Step 1.1 — Start the plan on a clean tree

- **Status:** pending
- **Depends on:** none
- **Files:** `plan.md` of this plan and the plans registry `README.md` (status change)
- **Why:** a plan starts only on a clean git tree, so its changes never mix with unfinished work.

**Do:**
- [ ] Run `git status --short`. Any line → stop: tell the owner the listed paths and that the plan cannot start until they are committed or finished; change nothing.
- [ ] Run `git rev-parse --short HEAD` (the base commit; the review phase diffs against it).
- [ ] Run `python3 <dev-standard>/scripts/plan.py status --root . P65 in-progress` (`<dev-standard>` is the base directory of the `dev-standard` skill, shown by the client when the skill loads).
- [ ] Commit `plan.md` of this plan with the registry `README.md` under the project's commit rules.
- [ ] Only now set this step `in-progress` and write the base commit in `Notes`.

**Verify:**
- [ ] The `| Status |` row of `plan.md` is `in-progress`; `git status --short` lists only `tasks.md` of this plan.

**Done when:** the plan is `in-progress` on a clean tree and the base commit is in `Notes`.

**If it fails:** `PLAN_START=REFUSED` or a dirty tree — the plan stays `approved`; tell the owner the `DIRTY` paths and stop.

**Notes:**
- (none yet)

#### Step 1.2 — Record baseline gate result

- **Status:** pending
- **Depends on:** Step 1.1
- **Files:** none (read-only)
- **Why:** to know which gate failures, if any, existed before the change.

**Do:**
- [ ] Run `uv run bdo gate` from the repository root.
- [ ] Write the exit code in `Notes`.

**Verify:**
- [ ] `Notes` contain the exit code and the command output summary.

**Done when:** the baseline gate result is written in `Notes`.

**If it fails:** a failing baseline is not a blocker by itself; record it. If the command cannot run at all (missing tool, import error), set `blocked`.

**Notes:**
- (none yet)

---

## Phase 2 — Retry-deferred backend

- **Objective:** the pipeline can run a retry session over deferred rows and clears the deferred mark after a successful write.
- **Scope:** `src/bdo_translate/store/repo.py`, `src/bdo_translate/pipeline/commit.py`, `src/bdo_translate/pipeline/runner.py`, `src/bdo_translate/pipeline/steps.py`.
- **Acceptance criteria:** `remove_deferred` deletes one mark; a written row loses its mark; a retry goal loads only transient deferred rows oldest-first.
- **Verification:** `uv run bdo gate` exits 0.
- **Parallel group:** none

#### Step 2.1 — Add repo.remove_deferred

- **Status:** pending
- **Depends on:** Step 1.2
- **Files:** `src/bdo_translate/store/repo.py` (modify)
- **Why:** nothing can clear a deferred mark today, so a retry would loop forever.

**Do:**
- [ ] Open `src/bdo_translate/store/repo.py`. Find the method `def add_deferred`.
- [ ] Insert after its body a new method with this exact body (4 spaces indent, method of the same class):
```python
    def remove_deferred(self, identity_hash: str) -> None:
        """Прибирає мітку відкладеного рядка після успішного запису."""
        statement = delete(Deferred).where(cast(Any, Deferred.identity_hash) == identity_hash)
        with self._session() as session:
            session.exec(statement)
            session.commit()
```
- [ ] Change nothing else in the file.

**Verify:**
- [ ] Run `rg -n "def remove_deferred" src/bdo_translate/store/repo.py` → one line with the method name.
- [ ] Run `uv run bdo gate lint` → exit code 0.

**Done when:** the method exists and lint passes.

**If it fails:** `delete`, `Deferred`, `cast` or `Any` is not as the plan describes → set `blocked`, write the exact error in `Notes`, stop. The one allowed fix is the import already present at the top of the file.

**Notes:**
- (none yet)

#### Step 2.2 — Clear the mark after a successful write

- **Status:** pending
- **Depends on:** Step 2.1
- **Files:** `src/bdo_translate/pipeline/commit.py` (modify)
- **Why:** a row written after healing keeps its old mark, so later runs skip it forever.

**Do:**
- [ ] Open `src/bdo_translate/pipeline/commit.py`. Find the anchor `if channel_name == "machine" and ctx.mode.source == "proposals":`.
- [ ] Directly above the line `_save_queue_reason(ctx, row, defect_notes.get(row.identity_hash))` there is the `else` branch of the write-result check. Insert `repo.remove_deferred(row.identity_hash)` as the first statement of that `else` branch.
- [ ] The `else` branch keeps handling `proposal` queue reasons and `_reject_written_proposal` exactly as before.
- [ ] Change nothing else in the file.

**Verify:**
- [ ] Run `rg -n "remove_deferred" src/bdo_translate/pipeline/commit.py` → one line inside the success branch.
- [ ] Run `uv run bdo gate lint` → exit code 0.

**Done when:** every successfully written row loses its deferred mark and lint passes.

**If it fails:** the anchor is missing or the branch shape differs → set `blocked`, write the exact lines in `Notes`, stop.

**Notes:**
- (none yet)

#### Step 2.3 — Retry goal and fetch branch

- **Status:** pending
- **Depends on:** Step 2.2
- **Files:** `src/bdo_translate/pipeline/runner.py` (modify), `src/bdo_translate/pipeline/steps.py` (modify)
- **Why:** the retry session needs a flag that survives in `goal_json` and a fetch path that loads deferred rows instead of skipping them.

**Do:**
- [ ] Open `src/bdo_translate/pipeline/runner.py`. Find the dataclass `RunGoal`.
- [ ] Add the field `retry_deferred: bool = False` after the field `generation`.
- [ ] Open `src/bdo_translate/pipeline/steps.py`. Find the function `step_fetch`.
- [ ] Add a branch at the start of row selection for retry sessions.
- [ ] Read the flag as `json.loads(ctx.session.goal_json).get("retry_deferred")`.
- [ ] Load candidates only from `repo.deferred()`, oldest first by `created_at` ascending.
- [ ] Sort inside the new branch; do not change the order of `deferred()`.
- [ ] Keep only rows whose reason is in `_TRANSIENT_DEFER_REASONS`.
- [ ] Load each kept row with `row_by_hash`.
- [ ] Skip a hash that `row_by_hash` no longer finds; skip rows already in `ctx.skip_hashes`.
- [ ] Treat a row with empty `source_text` exactly like the existing fetch path does.
- [ ] Stop at `target` rows.
- [ ] Keep the existing patch and proposals paths untouched for sessions without the flag.
- [ ] Change nothing else in the two files.

**Verify:**
- [ ] Run `rg -n "retry_deferred" src/bdo_translate/pipeline/runner.py src/bdo_translate/pipeline/steps.py` → hits in both files.
- [ ] Run `uv run bdo gate` → exit code 0.

**Done when:** the flag exists in the goal and the fetch branch loads only transient deferred rows.

**If it fails:** `goal_json`, `row_by_hash` or `_TRANSIENT_DEFER_REASONS` is not as the plan describes → set `blocked`, write the exact error in `Notes`, stop.

**Notes:**
- (none yet)

#### Step 2.4 — Checkpoint: phase 2 is green

- **Status:** pending
- **Depends on:** Step 2.3
- **Files:** none (read-only)
- **Why:** each phase must end in a working state that is safe to stop at.

**Do:**
- [ ] Run `uv run bdo gate` from the repository root.

**Verify:**
- [ ] The command exits with code 0.
- [ ] Every acceptance criterion of phase 2 holds.

**Done when:** phase 2 acceptance criteria hold with evidence.

**If it fails:** find the step that introduced the failure using the notes and the diff; fix only within that step's scope; if not solvable in one attempt, set `blocked` and stop.

**Notes:**
- (none yet)

---

## Phase 3 — Button and documents

- **Objective:** the owner sees the retry button on a failed session and the documents explain it.
- **Scope:** `src/bdo_translate/web/screens/run.py`, `src/bdo_translate/web/templates/run.html`, `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md`, `plans/BACKLOG.md`.
- **Acceptance criteria:** the button shows only on failed sessions with transient deferred rows; docs describe the flow; the BACKLOG item is gone.
- **Verification:** `uv run bdo gate` exits 0.
- **Parallel group:** none

#### Step 3.1 — Action run_retry_deferred and button

- **Status:** pending
- **Depends on:** Step 2.4
- **Files:** `src/bdo_translate/web/screens/run.py` (modify), `src/bdo_translate/web/templates/run.html` (modify)
- **Why:** without a visible action the backend path is unreachable for the owner.

**Do:**
- [ ] Open `src/bdo_translate/web/screens/run.py`. Find the action `run_resume` and its handler.
- [ ] Add an action `run_retry_deferred` (label «повторити відкладені») next to `run_resume`.
- [ ] Give the handler a hidden `session_id` input; load that session and require its status `failed`.
- [ ] Copy every field of the failed session goal from its `goal_json`.
- [ ] Override three fields: `retry_deferred=True`; `rows_per_batch` from the form; `batches` as the transient deferred count divided by `rows_per_batch`, rounded up, minimum 1.
- [ ] Parse `rows_per_batch` as an integer with default `min_rows_per_batch`; clamp it into [`min_rows_per_batch`, `MAX_ITEMS`]; raise `StateError` on a non-numeric value.
- [ ] Start the new session through the runner and redirect to `/run`.
- [ ] Compute button visibility in `build` next to `resume_enabled`.
- [ ] Show the button only when the session status is `failed` and at least one `repo.deferred()` row has a reason in `_TRANSIENT_DEFER_REASONS`.
- [ ] Open `src/bdo_translate/web/templates/run.html`. Find the `resume_enabled` block.
- [ ] Add a form with the button and a `rows_per_batch` number input next to that block, shown only when the new flag is true.
- [ ] Add `action_error("run_retry_deferred")` next to the existing `action_error` calls.
- [ ] Change nothing else in the two files.

**Verify:**
- [ ] Run `rg -n "run_retry_deferred" src/bdo_translate/web/screens/run.py src/bdo_translate/web/templates/run.html` → hits in both files.
- [ ] Run `uv run bdo gate` → exit code 0.

**Done when:** the action, the visibility flag and the button exist and gate passes.

**If it fails:** the `run_resume` shape differs from the plan → set `blocked`, write the exact lines in `Notes`, stop.

**Notes:**
- (none yet)

#### Step 3.2 — Documents and BACKLOG cleanup

- **Status:** pending
- **Depends on:** Step 3.1
- **Files:** `docs/OPERATIONS.md` (modify), `docs/TROUBLESHOOTING.md` (modify), `plans/BACKLOG.md` (modify)
- **Why:** the new button changes the documented recovery flow, and the fixed BACKLOG item must leave the list in the same change.

**Do:**
- [ ] Open `docs/OPERATIONS.md`. Find the table with «продовжити» (`btn-run_resume`).
- [ ] Add a row for «повторити відкладені» (`run_retry_deferred`): new session over transient deferred rows; successful rows lose the mark.
- [ ] Open `docs/TROUBLESHOOTING.md`. Find step 5 of «Прогін зупинився на повторі».
- [ ] Point that step at the new button with this exact advice sentence: «Натисніть «повторити відкладені» і почніть із малої пачки (від 5 рядків).»
- [ ] Open `plans/BACKLOG.md`. Delete the item starting with «Успішно перекладений рядок лишається у відкладених».
- [ ] Change nothing else in the three files.

**Verify:**
- [ ] Run `rg -n "повторити відкладені" docs/OPERATIONS.md docs/TROUBLESHOOTING.md` → hits in both files.
- [ ] Run `rg -n "почніть із малої пачки" docs/TROUBLESHOOTING.md` → one hit in step 5.
- [ ] Run `rg -n "лишається у відкладених" plans/BACKLOG.md` → no hits.
- [ ] Run `uv run bdo gate docs` → exit code 0.

**Done when:** docs describe the button and the BACKLOG item is gone.

**If it fails:** anchors differ → set `blocked`, write the exact lines in `Notes`, stop.

**Notes:**
- (none yet)

#### Step 3.3 — Checkpoint: phase 3 is green

- **Status:** pending
- **Depends on:** Step 3.2
- **Files:** none (read-only)
- **Why:** each phase must end in a working state that is safe to stop at.

**Do:**
- [ ] Run `uv run bdo gate` from the repository root.

**Verify:**
- [ ] The command exits with code 0.
- [ ] Every acceptance criterion of phase 3 holds.

**Done when:** phase 3 acceptance criteria hold with evidence.

**If it fails:** find the step that introduced the failure using the notes and the diff; fix only within that step's scope; if not solvable in one attempt, set `blocked` and stop.

**Notes:**
- (none yet)

---

## Phase 4 — Browser acceptance on DEV

- **Objective:** the retry flow is proven in the browser on DEV without writing.
- **Scope:** DEV environment only, `dry_run` sessions.
- **Acceptance criteria:** the button is visible on a failed DEV session; the retry session runs; screenshots, console and network are clean.
- **Verification:** `docs/WEB.md` protocol checklist.
- **Parallel group:** none

#### Step 4.1 — Dry-run the retry button on DEV

- **Status:** pending
- **Depends on:** Step 3.3
- **Files:** none (read-only; screenshots go to `.bdo/playwright/`, which is git-ignored)
- **Why:** project rules accept a behavior change only with a browser proof.

**Do:**
- [ ] Open the DEV application in the native Codex browser channel and switch it to the dark theme.
- [ ] Open the failed DEV session screen and confirm the button «повторити відкладені» is visible.
- [ ] Start the retry with a small batch and follow it to the end (`dry_run`).
- [ ] Take 3–5 screenshots with `getScreenshot()` to `.bdo/playwright/P65-<n>.png`; expected text on screen: «повторити відкладені» and the retry session running or done.
- [ ] Check the console for zero `error` entries and the visible network states for no unexpected failures.
- [ ] Open one session that is not failed (running, paused or finished) and confirm the button is absent there.
- [ ] Read the retry session rows from the database and confirm they match the transient deferred hashes in oldest-first order; write the count in `Notes`.

**Verify:**
- [ ] Screenshots show the button and the retry run with the expected text.
- [ ] Console has no `error` entries; no unexpected network failure is visible.
- [ ] If the native channel cannot save a file or read a state, name the missing ability and use Playwright MCP as the fallback, stating the reason.

**Done when:** the protocol checklist of `docs/WEB.md` is ticked for this flow with evidence in `Notes`.

**If it fails:** a flow defect → set `blocked` with the screenshot names and the observed text, stop; do not fix code in this step.

**Notes:**
- (none yet)

#### Step 4.2 — Write-prove the deferred cleanup on DEV

- **Status:** pending
- **Depends on:** Step 4.1
- **Files:** none (read-only plus one DEV write run approved below)
- **Why:** `dry_run` never reaches `step_commit`, so only a real DEV write proves the mark is cleared.

**Do:**
- [ ] Confirm the owner approved the DEV write of at most 5 rows when approving this plan.
- [ ] Run the retry on DEV with `dry_run` off and at most 5 rows to a successful commit.
- [ ] Query the database for those hashes in `deferred`.
- [ ] Record the written count and the remaining deferred count in `Notes`.

**Verify:**
- [ ] The written rows are gone from `deferred`; rows that failed again keep the new reason.
- [ ] `uv run bdo gate` exits with code 0.

**Done when:** the database proves a written row loses its mark.

**If it fails:** the owner did not approve the DEV write → set `skipped` with the reason in `Notes` and stop; the Definition of Done item on clearing stays unchecked.

**Notes:**
- (none yet)

---

## Phase 5 — Independent review

- **Objective:** independent reviewers that did not write the change confirm it or find defects.
- **Started by:** the coordinating session: the session that started the executor, or the executing session itself when one session runs the plan. It starts the reviewers (subagents that did not write the change) or, with no subagent available, asks the owner to review; review is never skipped. An executing subagent that reaches this phase stops and reports to the coordinating session.
- **Scope:** the diff of this plan; read-only for the reviewers.
- **Acceptance criteria:** every confirmed finding is fixed or accepted by the owner; the fixes passed «Повторне рев'ю виправлень» (at most two re-review rounds, then the owner decides).
- **Verification:** the checkpoint commands of the last implementation phase.
- **Parallel group:** none

#### Step 5.1 — Review the diff and fix confirmed findings

- **Status:** pending
- **Depends on:** Step 4.2
- **Files:** `src/bdo_translate/store/repo.py`, `src/bdo_translate/pipeline/commit.py`, `src/bdo_translate/pipeline/runner.py`, `src/bdo_translate/pipeline/steps.py`, `src/bdo_translate/web/screens/run.py`, `src/bdo_translate/web/templates/run.html`, `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md`, `plans/BACKLOG.md` (modify only to fix confirmed findings)
- **Why:** an independent read catches defects the author misses.

**Do:**
- [ ] The coordinating session starts read-only reviewers in parallel, one per lens of skill `brygada`, `references/review-lenses.md` — lenses 1–5 (correctness, contracts, tests, plan, safety), plus lens 6 (dryrun) when the diff changes instructions — on the executor model; each gets `git diff <base commit> -- <files this plan changes>` (new uncommitted files listed separately), the path of this `plan.md`, its lens and skill `adversarial-review`; lenses `tests` and `dryrun` each get their own repository copy in the package section «Пісочниця» (the coordinating session creates the copies, `review-lenses.md`).
- [ ] The coordinating session judges the findings by «Суд головної сесії» of that file, fixes the confirmed ones inside this plan's scope (itself or by a package) and runs «Повторне рев'ю виправлень».

**Verify:**
- [ ] Rerun `uv run bdo gate` → exit code 0.
- [ ] Every finding has a note: confirmed and fixed, rejected with a reason, or accepted by the owner.
- [ ] «Повторне рев'ю виправлень» ran for every lens with confirmed findings; its result is in `Notes`.
- [ ] `Notes` list the lenses run (and why lens 6 was or was not run); every review has a non-empty «Перевірено» section with `файл:рядок`; an empty review was rerun once; empty again — the coordinating session checked that lens itself and noted it.

**Done when:** no confirmed finding is left open (fixed, or accepted by the owner).

**If it fails:** a finding that needs work outside the plan's scope goes to `Out of scope / follow-ups` and is reported to the owner; do not expand the scope. If no reviewers were started, or only the author of the change is available, set `blocked`, report it to the coordinating session (which asks the owner how to review), and do not review your own change.

**Notes:**
- (none yet)

---

## Progress log

| Date | Step | Result | Note |
| --- | --- | --- | --- |
| 2026-10-23 | — | plan created | головна сесія власника |
| 2026-10-23 | — | dry-run fix | виправлено знахідки p65_dryrun: якорі, порядок, поля цілі, валідація, негативні перевірки, крок 4.2 |
