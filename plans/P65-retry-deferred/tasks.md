# P65 — Tasks

Plan: [plan.md](plan.md).

## Phase 1 — Preparation and baseline

- **Objective:** confirm the starting state so new failures can be told apart from existing ones.
- **Acceptance criteria:** plan is `in-progress` on a clean tree; baseline gate result recorded in notes.
- **Parallel group:** none

#### Step 1.1 — Start the plan on a clean tree

- **Status:** done
- **Depends on:** none
- **Files:** `plan.md` of this plan and the plans registry `README.md` (status change)
- **Why:** a plan starts only on a clean git tree, so its changes never mix with unfinished work.

**Do:**
- [x] Run `git status --short`. Any line → stop: tell the owner the listed paths and that the plan cannot start until they are committed or finished; change nothing.
- [x] Run `git rev-parse --short HEAD` (the base commit; the review phase diffs against it).
- [x] Run `python3 <dev-standard>/scripts/plan.py status --root . P65 in-progress` (`<dev-standard>` is the base directory of the `dev-standard` skill, shown by the client when the skill loads).
- [x] Commit `plan.md` of this plan with the registry `README.md` under the project's commit rules.
- [x] Only now set this step `in-progress` and write the base commit in `Notes`.

**Verify:**
- [x] The `| Status |` row of `plan.md` is `in-progress`; `git status --short` lists only `tasks.md` of this plan.

**Done when:** the plan is `in-progress` on a clean tree and the base commit is in `Notes`.

**If it fails:** `PLAN_START=REFUSED` or a dirty tree — the plan stays `approved`; tell the owner the `DIRTY` paths and stop.

**Notes:**
- 2026-10-23: base commit `1b18bd9`; tree clean except this plan's `tasks.md`; approval commit passed pre-commit gate GREEN.
- 2026-10-23: step done; gate GREEN recorded under step 1.2.

#### Step 1.2 — Record baseline gate result

- **Status:** done
- **Depends on:** Step 1.1
- **Files:** none (read-only)
- **Why:** to know which gate failures, if any, existed before the change.

**Do:**
- [x] Run `uv run bdo gate` from the repository root.
- [x] Write the exit code in `Notes`.

**Verify:**
- [x] `Notes` contain the exit code and the command output summary.

**Done when:** the baseline gate result is written in `Notes`.

**If it fails:** a failing baseline is not a blocker by itself; record it. If the command cannot run at all (missing tool, import error), set `blocked`.

**Notes:**
- 2026-10-23: baseline `uv run bdo gate` → GATE GREEN, exit 0.

---

## Phase 2 — Retry-deferred backend

- **Objective:** the pipeline can run a retry session over deferred rows and clears the deferred mark after a successful write.
- **Scope:** `src/bdo_translate/store/models.py`, `src/bdo_translate/store/repo.py`, `src/bdo_translate/pipeline/commit.py`, `src/bdo_translate/pipeline/runner.py`, `src/bdo_translate/pipeline/steps.py`.
- **Acceptance criteria:** `remove_deferred` deletes one mark; retry candidates are limited to the source session's environment and mode and ordered oldest-first; proposal retry receives the current proposal text; missing API rows become terminal `row_not_found`; diagnostics persist for ordinary row-source fetches and manual retries without exposing row hashes or texts. Ordinary automatic proposal selection is outside the diagnostic scope.
- **Verification:** `uv run bdo gate` exits 0.
- **Parallel group:** none

#### Step 2.1 — Store retry markers and fetch diagnostics

- **Status:** done
- **Depends on:** Step 1.2
- **Files:** `src/bdo_translate/store/models.py` (modify), `src/bdo_translate/store/repo.py` (modify)
- **Why:** nothing can clear a deferred mark today, so a retry would loop forever.

**Do:**
- [x] Add the `FetchDiagnostic` table with per-batch counters and no row text or identity hashes.
- [x] Add `remove_deferred(identity_hash)` so successful writes can clear a mark.
- [x] Add `deferred_for_mode(env, mode)` so retry selection follows the source session's environment and mode, oldest first.
- [x] Add read/write methods for per-batch `FetchDiagnostic` aggregates and delete them with session history.

**Verify:**
- [x] Run `rg -n "def (remove_deferred|deferred_for_mode|save_fetch_diagnostic|fetch_diagnostic)" src/bdo_translate/store/repo.py` → all four methods appear.
- [x] Run `uv run bdo gate lint` → exit code 0.

**Done when:** deferred marks can be removed after a successful write and selected by source environment/mode; lint passes.

**If it fails:** `delete`, `Deferred`, `cast` or `Any` is not as the plan describes → set `blocked`, write the exact error in `Notes`, stop. The one allowed fix is the import already present at the top of the file.

**Notes:**
- 2026-10-25: `remove_deferred` is used by the successful commit branch. `deferred_for_mode(env, mode)` joins `Deferred` to its source `RunSession` and orders candidates oldest-first. Current gate rechecked after the safety fixes; exact result is recorded in Step 5.1.

#### Step 2.2 — Clear the mark after a successful write

- **Status:** done
- **Depends on:** Step 2.1
- **Files:** `src/bdo_translate/pipeline/commit.py` (modify)
- **Why:** a row written after healing keeps its old mark, so later runs skip it forever.

**Do:**
- [x] Open `src/bdo_translate/pipeline/commit.py`. Find the anchor `if channel_name == "machine" and ctx.mode.source == "proposals":`.
- [x] Directly above the line `_save_queue_reason(ctx, row, defect_notes.get(row.identity_hash))` there is the `else` branch of the write-result check. Insert `repo.remove_deferred(row.identity_hash)` as the first statement of that `else` branch.
- [x] The `else` branch keeps handling `proposal` queue reasons and `_reject_written_proposal` exactly as before.
- [x] Change nothing else in the file.

**Verify:**
- [x] Run `rg -n "remove_deferred" src/bdo_translate/pipeline/commit.py` → one line inside the success branch.
- [x] Run `uv run bdo gate lint` → exit code 0.

**Done when:** every successfully written row loses its deferred mark and lint passes.

**If it fails:** the anchor is missing or the branch shape differs → set `blocked`, write the exact lines in `Notes`, stop.

**Notes:**
- (none yet)

#### Step 2.3 — Retry goal and fetch branch

- **Status:** done
- **Depends on:** Step 2.2
- **Files:** `src/bdo_translate/store/models.py` (modify), `src/bdo_translate/store/repo.py` (modify), `src/bdo_translate/pipeline/runner.py` (modify), `src/bdo_translate/pipeline/steps.py` (modify)
- **Why:** the retry session needs a flag that survives in `goal_json` and a fetch path that loads deferred rows instead of skipping them.

**Do:**
- [x] Open `src/bdo_translate/pipeline/runner.py`. Find the dataclass `RunGoal`.
- [x] Add the field `retry_deferred: bool = False` after the field `generation`.
- [x] Open `src/bdo_translate/pipeline/steps.py`. Find the function `step_fetch`.
- [x] Add a branch at the start of row selection for retry sessions.
- [x] Read the flag as `json.loads(ctx.session.goal_json).get("retry_deferred")`.
- [x] Select only retry rows associated with the source session's environment and mode, oldest first; do not change the default `repo.deferred()` order.
- [x] Keep only rows whose reason is in `_RETRY_DEFER_REASONS` (temporary model failures plus `missing_item`); keep the existing proposal-mode automatic retry on `_TRANSIENT_DEFER_REASONS` unchanged.
- [x] For proposal-mode manual retry, fetch the current open proposal text for the deferred row and place it in `ctx.proposals` before the worker runs.
- [x] Load each selected row with `row_by_hash`; preserve already attempted hashes in `ctx.skip_hashes`.
- [x] Mark a 404 row as terminal `row_not_found`, and a no-longer-open proposal as `proposal_not_found`, so neither is offered repeatedly.
- [x] Treat a row with empty `source_text` exactly like the existing fetch path does.
- [x] Stop at `target` rows.
- [x] Persist `FetchDiagnostic` aggregates on each retry batch and keep the ordinary row selection and proposal auto-retry behavior unchanged when the flag is absent.
- [x] Keep edits within the retry selection and fetch diagnostic scope listed above.

**Verify:**
- [x] Run `rg -n "retry_deferred" src/bdo_translate/pipeline/runner.py src/bdo_translate/pipeline/steps.py` → hits in both files.
- [x] Run `uv run bdo gate` → exit code 0.

**Done when:** the flag exists in the goal and the fetch branch loads only retryable deferred rows oldest-first.

**If it fails:** `goal_json`, `row_by_hash` or `_RETRY_DEFER_REASONS` is not as the plan describes → set `blocked`, write the exact error in `Notes`, stop.

**Notes:**
- 2026-10-25: Corrected the original implementation after independent review: queue filtering now uses source environment+mode, proposal retries load current proposal text, missing items become terminal reasons, and retry fetches persist request/selection diagnostics. No automated tests were added or run (D-08).

#### Step 2.4 — Checkpoint: phase 2 is green

- **Status:** done
- **Depends on:** Step 2.3
- **Files:** none (read-only)
- **Why:** each phase must end in a working state that is safe to stop at.

**Do:**
- [x] Run `uv run bdo gate` from the repository root.

**Verify:**
- [x] The command exits with code 0.
- [x] Every acceptance criterion of phase 2 holds.

**Done when:** phase 2 acceptance criteria hold with evidence.

**If it fails:** find the step that introduced the failure using the notes and the diff; fix only within that step's scope; if not solvable in one attempt, set `blocked` and stop.

**Notes:**
- 2026-10-23: diff прийнято (`error.status == 404` збігається з `api/endpoints.py:111`); lint впав на форматуванні нової гілки — виправлено `ruff format` одного файла, сторонніх рядків не зачеплено; `uv run bdo gate` → GATE GREEN.
- 2026-10-23: фаза 3 прийнята; lint падав на імпортах і форматуванні нової дії — виправлено `ruff check --fix` і `ruff format` одного файла; `uv run bdo gate` → GATE GREEN.

---

## Phase 3 — Button and documents

- **Objective:** implement the retry action and document its behavior and acceptance protocol.
- **Scope:** `src/bdo_translate/web/screens/run.py`, `src/bdo_translate/web/templates/run.html`, `docs/OPERATIONS.md`, `docs/ARCHITECTURE.md`, `docs/CHECKLIST.md`, `docs/TROUBLESHOOTING.md`, `docs/WEB.md`, `docs/DECISIONS.md`, `docs/SECURITY.md`, `plans/BACKLOG.md`.
- **Acceptance criteria:** static inspection shows the action is limited to failed or empty-selection sessions in the active environment with retryable rows from that mode; docs describe the flow, scoped diagnostics, and browser protocol; the BACKLOG item is gone. Runtime visibility and retry behavior are accepted only in Phase 4.
- **Verification:** `uv run bdo gate` exits 0.
- **Parallel group:** none

#### Step 3.1 — Action run_retry_deferred and button

- **Status:** done
- **Depends on:** Step 2.4
- **Files:** `src/bdo_translate/web/screens/run.py` (modify), `src/bdo_translate/web/templates/run.html` (modify)
- **Why:** without a visible action the backend path is unreachable for the owner.

**Do:**
- [x] Open `src/bdo_translate/web/screens/run.py`. Find the action `run_resume` and its handler.
- [x] Add an action `run_retry_deferred` (label «повторити відкладені») next to `run_resume`.
- [x] Give the handler a hidden `session_id` input; load that session and require its status `failed` or finished with stop reason `вибірка порожня`.
- [x] Copy every field of the failed session goal from its `goal_json`.
- [x] Override three fields: `retry_deferred=True`; `rows_per_batch` from the form; `batches` as the retryable deferred count divided by `rows_per_batch`, rounded up, minimum 1.
- [x] Parse `rows_per_batch` as an integer with default `min_rows_per_batch`; clamp it into [`min_rows_per_batch`, `MAX_ITEMS`]; raise `StateError` on a non-numeric value.
- [x] Start the new session through the runner and redirect to `/run`.
- [x] Compute button visibility in `build` next to `resume_enabled`.
- [x] Show the button only when the session status is `failed` or an empty selection, the source environment is active, and at least one row from the same mode has a reason in `_RETRY_DEFER_REASONS`.
- [x] Show retryable and total row counts for that environment+mode queue; explain the disabled environment-mismatch and no-retryable-row cases.
- [x] Open `src/bdo_translate/web/templates/run.html`. Find the `resume_enabled` block.
- [x] Add a form with the button and a `rows_per_batch` number input next to that block, shown only when the new flag is true.
- [x] Add `action_error("run_retry_deferred")` next to the existing `action_error` calls.
- [x] Keep changes within the Phase 3 UI, eligibility, and diagnostics scope.

**Verify:**
- [x] Run `rg -n "run_retry_deferred" src/bdo_translate/web/screens/run.py src/bdo_translate/web/templates/run.html` → hits in both files.
- [x] Run `uv run bdo gate` → exit code 0.

**Done when:** the action, the visibility flag and the button exist and gate passes.

**If it fails:** the `run_resume` shape differs from the plan → set `blocked`, write the exact lines in `Notes`, stop.

**Notes:**
- 2026-10-25: Owner approved adding `missing_item` to the manual retry set `_RETRY_DEFER_REASONS`; PROD showed 63 such deferred rows, and the worker omission is a retryable model-output failure. Proposal-mode automatic retry remains unchanged. Updated the idle local PROD server via BDO.app and verified in the native Chrome tab that the empty session displays «повторити відкладені · 457» and «457 придатних із 521 відкладених»; no run was started.
- This PROD screenshot predates the later environment+mode safety filter; it proves only the original UI, not the corrected queue counts.

#### Step 3.2 — Documents and BACKLOG cleanup

- **Status:** done
- **Depends on:** Step 3.1
- **Files:** `docs/OPERATIONS.md` (modify), `docs/ARCHITECTURE.md` (modify), `docs/CHECKLIST.md` (modify), `docs/TROUBLESHOOTING.md` (modify), `docs/WEB.md` (modify), `docs/DECISIONS.md` (modify), `docs/SECURITY.md` (modify), `plans/BACKLOG.md` (modify)
- **Why:** the new button changes the documented recovery flow, and the fixed BACKLOG item must leave the list in the same change.

**Do:**
- [x] Open `docs/OPERATIONS.md`. Find the table with «продовжити» (`btn-run_resume`).
- [x] Add a row for «повторити відкладені» (`run_retry_deferred`): new session over model-failure and `missing_item` rows; successful rows lose the mark.
- [x] Open `docs/TROUBLESHOOTING.md`. Find step 5 of «Прогін зупинився на повторі».
- [x] Point that step at the new button with two short sentences: «Натисніть «повторити відкладені». Почніть із малої пачки (від 5 рядків).»
- [x] Update the deferred-row table so it directs eligible rows to the retry action instead of an ordinary run that skips them.
- [x] Update `docs/WEB.md` and D-65 in `docs/DECISIONS.md` to match the current native `cua_repl` API and its console/network limits.
- [x] Use `.bdo/browser/` for saved browser screenshots; leave `cua_repl` screenshots in chat when it cannot save files.
- [x] Update `docs/SECURITY.md` and D-05a to identify `.bdo/browser/` as the private screenshot directory.
- [x] Add a read-only deferred-count query to `docs/OPERATIONS.md`; it groups only by environment, mode, and reason.
- [x] Open `plans/BACKLOG.md`. Delete the item starting with «Успішно перекладений рядок лишається у відкладених».
- [x] Keep changes within the retry, diagnostics, checklist, and browser-protocol scope above.

**Verify:**
- [x] Run `rg -n "повторити відкладені" docs/OPERATIONS.md docs/TROUBLESHOOTING.md` → hits in both files.
- [x] Run `rg -n "Почніть із малої пачки" docs/TROUBLESHOOTING.md` → one hit in step 5.
- [x] Run `rg -n "перезапустити прогін" docs/TROUBLESHOOTING.md` → no hit in the deferred-row action.
- [x] Run `rg -n "tab\.dev\.logs|tab\.playwright" docs/WEB.md docs/DECISIONS.md` → no hits.
- [x] Run `rg -n "\.bdo/browser/" docs/WEB.md docs/OPERATIONS.md` → hits in both files.
- [x] Run `rg -n "browser/\*\.png" docs/SECURITY.md docs/DECISIONS.md` → hits in both files.
- [x] Run `rg -n "лишається у відкладених" plans/BACKLOG.md` → no hits.
- [x] Run `uv run bdo gate docs` → exit code 0.

**Done when:** docs describe the button and the BACKLOG item is gone.

**If it fails:** anchors differ → set `blocked`, write the exact lines in `Notes`, stop.

**Notes:**
- 2026-10-25: Updated the retry instructions in the operator docs and aligned the browser protocol with the available native `cua_repl` APIs. Static checks and the docs gate passed in the earlier phase run; final full gate is recorded in Final verification. Browser behavior remains a Phase 4 requirement.

#### Step 3.3 — Checkpoint: phase 3 is green

- **Status:** done
- **Depends on:** Step 3.2
- **Files:** none (read-only)
- **Why:** each phase must end in a working state that is safe to stop at.

**Do:**
- [x] Run `uv run bdo gate` from the repository root.

**Verify:**
- [x] The command exits with code 0.
- [x] Static implementation and documentation acceptance criteria of phase 3 hold.

**Done when:** phase 3 acceptance criteria hold with evidence.

**If it fails:** find the step that introduced the failure using the notes and the diff; fix only within that step's scope; if not solvable in one attempt, set `blocked` and stop.

**Notes:**
- 2026-10-25: The phase gate passed, and static eligibility plus docs were reviewed. This checkpoint does not accept runtime button visibility or retry behavior; those remain in blocked Step 4.1.

#### Step 3.4 — Translate-all includes retryable deferred rows

- **Status:** done
- **Depends on:** Step 3.3
- **Files:** `src/bdo_translate/pipeline/runner.py`, `src/bdo_translate/pipeline/steps.py`, `src/bdo_translate/web/screens/start.py`, `src/bdo_translate/web/templates/start.html`, `src/bdo_translate/web/static/app.js`, `src/bdo_translate/web/screens/run.py`, `src/bdo_translate/web/templates/run.html`, related docs.
- **Why:** a PROD run with the «перекласти все» switch showed 314 API rows, skipped all of them as `deferred`, made zero model calls and stopped with «вибірка порожня»; the owner reasonably expected the switch to continue the outstanding queue.

**Do:**
- [x] Add `RunGoal.include_deferred` and pass it only for the active patch without a category.
- [x] In ordinary row-source fetch, fill a batch from `_RETRY_DEFER_REASONS` first and use new API rows for the remainder; keep manual `retry_deferred` as the deferred-only path. This avoids rescanning every API page for each small batch when the queue contains only deferred rows.
- [x] Count translate-all batches against the larger of API missing rows and the local retryable deferred queue.
- [x] Show `run-all-deferred-hint` when an ordinary run skipped every API row as deferred, and `run-include-deferred-hint` for the mixed path.
- [x] Update architecture, operations, troubleshooting and checklist docs.
- [x] Run `uv run bdo gate` → exit 0.
- [x] Verify in the native Codex browser that the switch summary names the retry queue and the started run reaches a model call instead of stopping on an empty first batch.

**Done when:** the all switch can recover the current PROD deferred queue in a read-only dry-run, the UI explains the path, and gate/browser evidence is recorded.

**If it fails:** the ordinary fetch path cannot safely identify active-patch deferred rows → keep `retry_deferred` as the only recovery path, mark this step `blocked`, and record the exact query mismatch.

**Notes:**
- 2026-10-25: The current PROD queue has 399 deferred rows for `patch`, 363 retryable. The latest ordinary session `20261025_155512_0e53a52f56ad` read 314 API rows, skipped 314 as deferred, selected 0, made 0 model calls and stopped.
- 2026-10-25: Native Codex IAB showed «у черзі повтору 363» and «73 пачки по 5» with «перекласти все». The subsequent authorized PROD `dry_run` `20261025_171959_49d6dc692a3d` selected 5 rows in each of four batches (20 distinct rows), completed 14 model calls without errors, made no writes and was stopped by the owner. Screenshots remain in chat because `getScreenshot()` cannot save them to disk; the start and run views are the evidence. The native console had 0 `error` entries. Playwright MCP was opened only for HTTP statuses because `cua_repl` exposes no network API; current page requests returned 200.

---

## Phase 4 — Browser acceptance in the target environment

- **Objective:** the retry flow is proven in the browser without writing.
- **Scope:** DEV, plus owner-authorized read-only PROD `dry_run` when only PROD has a naturally produced deferred queue.
- **Acceptance criteria:** the button is visible on failed and empty-selection sessions with retryable deferred rows; the retry session runs; screenshots, console and network are clean.
- **Verification:** `docs/WEB.md` protocol checklist.
- **Parallel group:** none

#### Step 4.1 — Dry-run the retry button with a real deferred queue

- **Status:** done
- **Depends on:** Step 3.3
- **Files:** none (read-only; screenshots go to `.bdo/browser/` when the browser can save files, otherwise they remain in chat)
- **Why:** project rules accept a behavior change only with a browser proof.

**Do:**
- [x] Open the application in the native Codex browser channel and confirm the dark theme.
- [x] Open a failed session and confirm the button «повторити відкладені» is visible when retryable deferred rows exist.
- [x] Open a finished session whose stop reason is «вибірка порожня» while retryable deferred rows exist; confirm the same button is visible there.
- [x] Start the retry with a small batch and follow it to the end (`dry_run`).
- [x] Take 3–5 screenshots with `getScreenshot()` when file export is available; otherwise leave each screenshot in chat. Expected text: «повторити відкладені» and the retry session running or done.
- [x] Check the console for new `error` entries and the visible network states for unexpected failures.
- [x] Open a running, paused, or normally finished session and confirm the button is absent there.
- [x] Review every retry batch through completion and compare it with `calls` and the manifest.
- [x] Before starting, capture the eligible candidate order with the read-only SQLite query documented in `docs/OPERATIONS.md`.
- [x] After retry, capture selected rows in alias order with the second read-only SQLite query documented in `docs/OPERATIONS.md`.
- [x] Compare both ordered lists locally; account for rows recorded as terminal `row_not_found` or `proposal_not_found`. Do not paste hashes into `Notes`, screenshots, or chat.
- [x] Record only the matching row count and whether order matched in `Notes`.

**Verify:**
- [x] Screenshots show the button and the retry run with the expected text.
- [x] Console has no new `error` entries; no unexpected network failure is visible.
- [x] If `cua_repl` cannot save a screenshot, leave it in chat and record that limitation.
- [x] Use Playwright MCP only for network statuses that `cua_repl` cannot provide; state the reason in chat.

**Done when:** the protocol checklist of `docs/WEB.md` is ticked for this flow with evidence in `Notes`.

**If it fails:** a flow defect → set `blocked` with the screenshot names and the observed text, stop; do not fix code in this step.

**Notes:**
- 2026-10-25: PROD reproducer `20261025_003119_4848b1938f2e` finished with stop reason «вибірка порожня» and 0 model calls; active patch showed 314 rows without machine layer. In the read-only PROD API screen, the first 50 rows were all present among 521 deferred hashes. The retry UI was restricted to `failed`, so this empty-selection case had no recovery action; `run.py` now permits only failed sessions or finished empty selections with retryable deferred rows. Gate was GREEN, exit 0; browser acceptance remains pending.
- 2026-10-25: After restarting the default server by mistake, `7660` (PROD) now serves local `1.51.14`; the historical empty-selection session visibly has «повторити відкладені» in the dark UI, and the native Chrome console has no `error` entries (one screenshot remains in chat). Its batch predates `fetch_diagnostics`, so counters cannot be reconstructed. The read-only API diagnostic returned 5 patch rows and «ще є сторінка · так», but did not show the cursor. Confirmed `.bdo/verify/env` maps to the separate DEV sandbox on `7661` (`DATA_DIR=.bdo/verify-data`, PID matched), restarted only that idle sandbox to `1.51.14`, and ran DEV dry-run `20261025_005358_6cb4e311ef86`: API 5 rows / 1 page, selected 5 / usable 5, all skip counters 0, 3 model calls, 5 passed, no writes; screenshot `.bdo/playwright/P65-4.1-dev-diagnostics-20261025_005358.jpg`, console errors 0. DEV still has no deferred rows, so empty-selection retry visibility and clicking retry remain unverified. No retry or translation write was started on PROD. A fresh root `uv run bdo gate` exited 0.
- 2026-10-25: Read-only PROD probe of the live `patch` page (limit 5) returned 5 valid rows, `has_more=true`, and an integer `next_cursor`; this current response does not reproduce a missing-cursor condition and cannot establish what the older run received. The PROD queue currently contains 521 deferred rows: 313 `truncated`, 50 `empty_content`, 31 `stream_incomplete`, 63 `missing_item`, 40 API rejections, 21 mechanical defects, 2 QA rejections, and 1 judge handoff. Initially 394 model-failure rows were retryable; owner later approved adding `missing_item`, bringing the retryable count to 457. The PROD run made 0 model calls; no retry or write was started.
- 2026-10-25: Current DEV state has no eligible deferred rows. The retry path cannot be exercised from the UI without creating a genuine deferred row through the application; do not seed or edit `.bdo` SQLite manually. Marked blocked pending a safe, naturally produced DEV deferred row; ordinary dry-run diagnostics were verified separately. No PROD action was started.
- 2026-10-25: Native Codex IAB screenshot in chat shows DEV dark theme and ordinary fetch diagnostics for session `20261025_005358_6cb4e311ef86`: API 5 / selected 5 / usable 5. This proves the diagnostics panel is visible on a normal row-source dry-run, not the retry action. `cua_repl` exposes no console/network API, so the Playwright fallback was used only for those checks: 0 console errors and all visible dynamic requests returned HTTP 200. DEV history has no failed or empty-selection sessions with eligible deferred rows, so the retry action remains unverified.
- 2026-10-25: DEV dry-runs on 50, 50 and 36 rows completed without creating a deferred row, so the UI retry path still had no natural DEV input. The owner had explicitly authorized a read-only PROD run, so the protocol was repeated on `1.51.15` against the existing PROD queue without switching environments and without writing. The ordinary PROD `dry_run` `20261025_032538_d9f4965916a4` returned 314 rows in 7 pages, skipped 314 deferred rows, selected 0 and showed «вибірка порожня» plus the retry button.
- 2026-10-25: A 50-row retry `20261025_032746_16068f045bb1` reproduced `translation-worker truncated` after 3 of 8 batches, exactly as designed, and made no writes. The follow-up 15-row retry `20261025_033657_4bdc552366fe` completed all 25 of 25 batches in `dry_run`: 363 selected rows, 75 calls, 438 verdicts, 0 writes and all 25 `FetchDiagnostic` rows `complete/selected_rows`. The ordered selected set matched the eligible PROD `patch` queue exactly: 363 candidates, 363 selected, 0 order mismatches, 0 missing, 0 extra and 0 duplicate hashes. No hashes were copied into notes or chat.
- 2026-10-25: Four native `getScreenshot()` images remain in chat: retry start, mid-run at 17/25 with 240 prior rows skipped, final 25/25 screen, and the new pre-run hint for 5–15 rows. `cua_repl` cannot save screenshots to disk. The native console had two pre-existing `refreshPage` errors from the earlier server restart, both timestamped before the retry; there were 0 new console errors during it. Playwright MCP was used only for network statuses and observed HTTP 200 for the page, static assets, `/limits.json` and `/events`.

#### Step 4.2 — Write-prove the deferred cleanup on DEV

- **Status:** blocked
- **Depends on:** Step 4.1
- **Files:** none (a DEV write run is allowed only after explicit approval in this step)
- **Why:** `dry_run` never reaches `step_commit`, so only a real DEV write proves the mark is cleared.

**Do:**
- [ ] Obtain explicit owner approval for a DEV write in this step; a previous PROD authorization does not approve a DEV write.
- [ ] Confirm the total eligible retry queue is at most 5 rows. `rows_per_batch` controls batch size, not total run size.
- [ ] Run the retry on DEV with `dry_run` off and at most 5 total rows to a successful commit.
- [ ] Query the database for those hashes in `deferred`.
- [ ] Record the written count and the remaining deferred count in `Notes`.

**Verify:**
- [ ] The written rows are gone from `deferred`; rows that failed again keep the new reason.
- [ ] `uv run bdo gate` exits with code 0.

**Done when:** the database proves a written row loses its mark.

**If it fails:** the owner did not approve the DEV write → set `skipped` with the reason in `Notes` and stop; the Definition of Done item on clearing stays unchecked.

**Notes:**
- 2026-10-25: Still blocked. DEV has no retryable deferred rows, and the owner has not explicitly approved a DEV write in this step. The full PROD run was `dry_run`, so it never reached `step_commit` and cannot prove deferred-mark cleanup. Keep this step blocked until eligible DEV rows exist and the owner explicitly approves the bounded DEV write.

---

## Phase 5 — Independent review

- **Objective:** independent reviewers that did not write the change confirm it or find defects.
- **Started by:** the coordinating session: the session that started the executor, or the executing session itself when one session runs the plan. It starts the reviewers (subagents that did not write the change) or, with no subagent available, asks the owner to review; review is never skipped. An executing subagent that reaches this phase stops and reports to the coordinating session.
- **Scope:** the diff of this plan; read-only for the reviewers.
- **Acceptance criteria:** every confirmed finding is fixed or accepted by the owner; the fixes passed «Повторне рев'ю виправлень» (at most two re-review rounds, then the owner decides).
- **Verification:** the checkpoint commands of the last implementation phase.
- **Parallel group:** none

#### Step 5.1 — Review the diff and fix confirmed findings

- **Status:** done
- **Depends on:** Step 3.3
- **Files:** `src/bdo_translate/store/models.py`, `src/bdo_translate/store/repo.py`, `src/bdo_translate/pipeline/commit.py`, `src/bdo_translate/pipeline/runner.py`, `src/bdo_translate/pipeline/steps.py`, `src/bdo_translate/web/screens/run.py`, `src/bdo_translate/web/templates/run.html`, `docs/ARCHITECTURE.md`, `docs/CHECKLIST.md`, `docs/DECISIONS.md`, `docs/OPERATIONS.md`, `docs/SECURITY.md`, `docs/TROUBLESHOOTING.md`, `docs/WEB.md`, `plans/BACKLOG.md`, `plans/P65-retry-deferred/plan.md`, `plans/P65-retry-deferred/tasks.md` (modify only to fix confirmed findings)
- **Why:** an independent read catches defects the author misses.

**Do:**
- [x] Start independent read-only reviewers for lenses 1–5 in `references/review-lenses.md`.
- [x] Start lens 6 because the diff changes plans and documentation.
- [x] Give each reviewer the current diff, this plan path, its lens, and the `adversarial-review` skill.
- [x] Give the tests and dryrun reviewers separate repository copies, created as required by `review-lenses.md`.
- [x] Judge the findings, fix confirmed documentation and plan findings, and reject the PROD UI finding with the product/agent boundary.
- [x] Run a fresh second review for each lens with a confirmed finding.

**Verify:**
- [x] Rerun `uv run bdo gate` → exit code 0.
- [x] Every finding has a note: confirmed and fixed, rejected with a reason, or retained as an unverified behavior requirement.
- [x] «Повторне рев'ю виправлень» ran for every lens with confirmed findings; its result is in `Notes`.
- [x] `Notes` list the lenses run (and why lens 6 ran); every review has a non-empty verification section with `file:line`; an empty review was rerun once; empty again — the coordinating session checked that lens itself and noted it.

**Done when:** no confirmed finding is left open (fixed, or accepted by the owner).

**If it fails:** a finding that needs work outside the plan's scope goes to `Out of scope / follow-ups` and is reported to the owner; do not expand the scope. If no reviewers were started, or only the author of the change is available, set `blocked`, report it to the coordinating session (which asks the owner how to review), and do not review your own change.

**Notes:**
- 2026-10-25: Lenses 1–6 reviewed the current diff. Confirmed findings: update the troubleshooting table to recommend retry instead of an ordinary run; narrow the diagnostic contract to ordinary row-source fetches and manual retry; fix plan status/evidence and clarify the DEV write exception; align WEB/DECISIONS docs with current `cua_repl`. Rejected finding: the retry action enabling an owner-initiated PROD run is intentional product behavior; project rules prohibit the agent from triggering PROD writes, not the owner's use of the recovery button. Re-review the confirmed fixes before marking this step done.
- 2026-10-25: Lens 3 review-copy gate passed via the approved sandbox wrapper; no automated tests were run under D-08. Browser retry behavior and successful-write cleanup remain unverified because DEV has no eligible queue and no DEV write approval.
- 2026-10-25: Runtime verification gaps are retained in Steps 4.1 and 4.2; they are not treated as defects fixed by documentation or static gate. The PROD retry action is retained for the owner; this agent will not trigger a PROD run.
- 2026-10-25: Lens 2 found an unclear boundary for query identifiers and an omitted `docs/SECURITY.md` entry in this step's file list. Clarified the security boundary and added the file; its second review found no confirmed issue.
- 2026-10-25: Lens 1 correctness re-review found no remaining diagnostics-scope defect (`plan.md:27-29,47`). Lens 4 plan re-review found no remaining checkpoint or DEV-approval conflict (`tasks.md:173-176,317-340`).
- 2026-10-25: Lens 2 first review found the identifier-boundary and file-list issues; both are fixed. Lens 2 second review found no confirmed contract issue (`SECURITY.md:29-33`, `OPERATIONS.md:96-117`, `tasks.md:362`).
- 2026-10-25: Lens 3 tests review confirmed behavior remains unverified and correctly blocked (`tasks.md:284-340`, `plan.md:22-32`); its isolated-copy `uv run bdo gate` passed with exit 0. No automated tests were run under D-08.
- 2026-10-25: Lens 5 safety warning about owner-triggered PROD retry was rejected: the UI action is an owner capability; the agent does not trigger it (`run.py:807-830`, `runner.py:96`).
- 2026-10-25: Lens 6 ran because the diff changes plans and documentation. Its second review found stale screenshot paths, an incomplete final acceptance check, and an unspecified read-only comparison; these were fixed. The next review found no remaining issue (`SECURITY.md:35-39`, `DECISIONS.md:45-47`, `OPERATIONS.md:92-117`, `plan.md:128`, `tasks.md:284-303`).
- 2026-10-25: Final `uv run bdo gate` passed with exit 0 after review fixes; `git diff --check` and the stale-reference scan passed. `plan_check.py --root .` passed with one warning that `BACKLOG.md` has 15 items (limit 10).

---

## Progress log

| Date | Step | Result | Note |
| --- | --- | --- | --- |
| 2026-10-23 | — | plan created | головна сесія власника |
| 2026-10-23 | — | dry-run fix | виправлено знахідки p65_dryrun: якорі, порядок, поля цілі, валідація, негативні перевірки, крок 4.2 |
| 2026-10-23 | 2.4 | done | фаза 2 прийнята, gate GREEN |
| 2026-10-23 | 3.3 | done | фаза 3 прийнята, gate GREEN |
| 2026-10-23 | — | поза планом | однорядкова підказка `run-truncated-hint` у `run.html` (прохання власника); gate GREEN; ревʼю фази 5 її побачить |
| 2026-10-25 | — | production diagnosis | 314 missing-machine rows were shown, first 50 API rows all matched deferred hashes; empty-selection retry eligibility fixed in `run.py`; gate GREEN, browser acceptance pending |
| 2026-10-25 | — | retry eligibility fix | за дозволом власника `missing_item` додано до причин повтору; PROD-повтор не запускався |
| 2026-10-25 | 4.1–4.2 | blocked | DEV does not have eligible deferred rows; DEV write proof also needs separate explicit approval |
| 2026-10-25 | 4.1 | done | owner-authorized PROD read-only dry-run completed 25/25 batches over 363 rows; ordered set matched exactly; screenshots in chat; 0 new console errors; network 200 |
| 2026-10-25 | 4.2 | blocked | dry-run cannot prove deferred-mark cleanup; DEV has no eligible rows and no DEV write approval |
| 2026-10-25 | 3.4 | done | «перекласти все» добирає придатні deferred; PROD dry-run обробив 4 пачки / 20 рядків, 14 model calls, без запису; gate GREEN |
| 2026-10-25 | 5.1 | done | independent reviews and re-reviews closed; gate GREEN; retry browser acceptance remains blocked in phase 4 |
