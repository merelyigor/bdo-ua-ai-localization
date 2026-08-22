# UI subagent workflow

Translation language work runs only in visible OpenCode child sessions. Model
routes are defined once in `.opencode/translation-models.json`, separately for
each role. Built-in `local-quality` and `local-fast` profiles use Ollama; custom
profiles may use any provider connected through OpenCode. Credentials remain in
OpenCode `/connect`, never in this repository. `./bdo profile status` shows the
active routes; `./bdo profile use NAME` activates one.

Windows uses this same flow through WSL2. Clone the repository into the Linux
filesystem, install the normal dependencies inside WSL, open it through the
OpenCode WSL server, and run `./bdo gate preflight`. Native PowerShell is not a
supported second implementation.

## Routing guarantees (mechanical, not instructional)

Independent layers prevent an unintended or hidden model route:

1. `opencode.json` denies `task` for every agent except the five named
   `translation-*` agents (`"*": "deny"` + explicit allows).
2. Frontmatter pins the first role route, while the session driver passes the
   exact provider/model explicitly, so a child never inherits the primary model.
3. The project plugin rejects any route absent from the active role policy.
   Paid routes require `allow_paid=true`; Ollama MLX is rejected because it
   ignores constrained decoding.
4. Retries use the ordered routes for that role and save the actual route in the
   session receipt. No route is discovered or enabled implicitly.
5. `subagent_depth: 1` plus `task: deny` in every child stops nested agents.
   `default_agent: translation` plus `disable: true` on `build`, `plan`,
   `general` and `explore` means the picker offers no general-purpose primary at
   all: the orchestrator cannot be swapped for one by accident. Their
   `permission.task` blocks stay in the config on purpose, so re-enabling one
   cannot silently restore unrestricted delegation.
6. `translation-worker`, `translation-repair`, `translation-qa` and
   `translation-smoke` disable every tool (`tools: {"*": false}`). Verified the
   hard way: a worker run reached `context7`, `playwright` and `skill`, spent
   85901 input tokens instead of 19838, and searched the web for BDO naming
   conventions instead of translating. Constrained decoding does NOT stop tool
   calls - only an empty tool list does. `translation-terminology` keeps `bash`
   alone as a narrow fallback for the glossary API and blocks every MCP server;
   its `read` was removed on 2026-08-22 once its input became a payload.

The same plugin sends `reasoning_effort = "none"` for the five agents (Qwen
thinking on the Ollama `/v1` endpoint returns the whole budget as `reasoning`
and leaves `content` empty) and refuses to run `translation-worker` or
`translation-repair` when no batch schema is staged, so a forgotten
`bdo schema build` fails before any tokens are spent, not after a full batch.
`translation-smoke` має вбудовану мінімальну strict JSON schema, тому його
успіх перевіряє не лише доступність зовнішньої моделі, а й критичну capability
constrained decoding до першої реальної пачки.

## Sequence

Every command below is a `./bdo` subcommand; `./bdo` alone prints the whole tree
and `./bdo help flow` prints this sequence without the reasoning. Batch files
live in the batch directory created by `./bdo batch new` and are always passed
by explicit path.

The run target is not chosen here: `BDO_ENV=PROD|DEV` in `.env` decides it for
reads and writes alike, and `./bdo env` prints what is currently set.

1. `./bdo fetch` - primary fetches one fixed snapshot batch (summary only
   goes into primary context).
2. `./bdo glossary gaps rows.json` - always. Deterministic, instant, free; its
   last line is the verdict. Only when it reports gaps start
   `./bdo payload terminology rows.json` and pass ITS OUTPUT to
   `translation-terminology`. The script resolves every term against the catalog
   first, retrying with the row's `identity_hash` on `blocked_identity`, so the
   child only proposes a rendering. It used to read the batch file itself, which
   made it the most expensive step of the whole flow.
3. `./bdo memory find rows.json` then `./bdo memory apply rows.json memory.json`
   - ask the project whether this exact English source is already translated
   somewhere, and close those rows without a model call. Measured: 58% of rows
   on a `missing=manual` fetch, 0% on a fresh patch where nothing is translated
   yet - but the rate grows inside a run, because rows written earlier become
   memory for their twins. The same step deduplicates identical sources inside
   the batch, so one English string is translated once.

   An applied memory text is not exempt from checks: it passes the same
   russianism, token and length rules as a fresh translation, and goes back to
   the model if it fails them.

   Everything after this step runs on `to-translate.json`, not on the full batch.
4. `./bdo schema build to-translate.json` - stage the constrained-decoding schema.
5. `./bdo payload worker to-translate.json` - print the compact payload; start
   `translation-worker` with that payload only. Save its response verbatim as
   the candidate file.

   Approved `examples` are included BY DEFAULT: the worker prompt calls them the
   strongest signal it gets, and they were opt-in for so long that they were
   effectively never used. Three guards keep the old objection (wasted calls on a
   fresh patch) from returning: the first 3 rows are probed and the rest are
   skipped when none yields an example, an existing `context.json` in the batch
   directory is reused instead of re-queried, and an unreachable API degrades to a
   payload without examples instead of failing the batch. Use `--no-context` to
   skip them outright.
6. `./bdo memory expand candidate.json twins.json memory-candidate.json > full.json`
   - assemble the whole batch back: model output, in-batch twins and memory.
7. `./bdo normalize full.json > clean.json` - deterministic repairs
   before any gate: Latin homoglyphs inside Cyrillic words. Free and unambiguous.
8. `./bdo items rows.json clean.json items.json "" --require-all` -
   deterministic gate; `./bdo russianisms clean.json rows.json` -
   dictionary scan; then `./bdo validate items.json` - API validation.
9. `./bdo schema qa rows.json` then `./bdo payload qa rows.json clean.json`;
   start `translation-qa` with that payload. It returns one verdict object per
   row: `identity_hash`, `status`, `severity`, `issue`, `fix`.
10. If QA found defects - exactly one healing round, then commit. See below.
11. Writing to local is the normal end of a batch, not a separate permission:
    PASS rows go to the AI layer, everything else goes to moderation, and
    `bdo commit --write` does both. Production is the exception and still
    requires explicit owner approval for that action.
12. `./bdo schema clear` and `./bdo batch end` once the batch is done.

## Glossary gaps come first

A term can be `severity: mandatory` while `ukrainian` is still `null`: the name
is declared canonical but nobody approved a rendering. Measured on a live active
patch: 12 terms in 15 rows, only 5 resolved, 6 mandatory-but-empty. Those rows
carry `canonical_pending` in both payloads, which tells the worker to stay
literal and tells QA there is nothing to verify canonicity against.

On a fresh patch run `translation-terminology` BEFORE the worker, not "if
needed". Whatever the worker invents for an unresolved mandatory term becomes
the de facto standard for the whole patch.

## Retranslation: improving existing AI layer

The existing machine layer was created from Russian reference text. The goal is
to replace it with translations from English source. Key differences from normal
patch translation:

1. **Fetch with `layers`:** add `layers` to the `fields=` parameter so rows.json
   contains the current machine translation text. `bdo fetch` does this
   automatically when `exclude_proposed` is in the query.
2. **`--with-current` flag on bdo payload worker:** passes the current machine
   translation as a `current` field in the payload. The worker model sees the
   existing text and decides whether to improve or keep it.
3. **`--memory manual`:** old machine translations are from RU and should NOT be
   used as translation memory. Only manual layer counts.
4. **No `missing=machine` filter:** the query uses `exclude_proposed=1` without
   `missing=` so rows with existing machine translations are included.

The worker prompt instructs: if `current` is already good and EN doesn't yield a
better result, return `current` unchanged. If `current` has abbreviations that fit
UI constraints ("Дод." not "Додаткова"), keep the abbreviation. Only retranslate
when the EN-based version is genuinely better.

## Three write channels, and why quarantine is gone

`bdo write --channel machine|manual|proposal`:

| Channel | API | What it is for |
|---|---|---|
| `machine` | `layer=machine, mode=direct` | the AI layer, as before (default) |
| `manual` | `layer=manual, mode=proposal, auto_approve=true` | same as editing on the site: approved at once if the role allows |
| `proposal` | same, `auto_approve=false` | stays in the moderation queue |

Three rules hold regardless of channel and role:

1. **A problematic row always goes to moderation** - non-PASS after the single
   healing round is written with `auto_approve=false` even when the actor's role
   would approve it. A defect must be seen by a human.
2. **A clean row follows the site's own rules.** `machine` writes the AI layer;
   `manual` writes a proposal that the server approves by itself when the actor
   holds `review_translation`, and leaves pending when it does not.
3. **A new item name is not a defect, and in an AI-layer run it does not go to
   moderation.** If nothing in the layers or the glossary translates it yet, it
   is simply a new translation. Measured: 13 of 20 rows in one batch - routing
   those to a human buries the real defects under a stream of new names. In a
   MANUAL run the opposite holds: the row is going to a human anyway, so a new
   item name is worth showing (`--channel manual --names-to-moderation`).
   Titles never go to moderation for this reason - only `item/name`.

The third channel replaces the file quarantine. A row that fails QA is not a
row to be hidden in `state/quarantine.jsonl`, where nobody sees it and the debt
piles up outside the site - it is a row to be shown in the admin moderation
queue, where it can be accepted or corrected in place. `bdo commit` sends
every non-PASS row with text through `--channel proposal`.

Quarantine still exists, but only for what is not a text-quality problem at all:
an empty answer, a run that was never started, an environment mismatch, an
exhausted quota. Those are infrastructure states, not translations.

The `auto_approve` flag had to be added to the API: without it an admin key
silently approves its own proposals, so the moderation queue could never be
reached from the agent flow.

## Continuous mode and quarantine

`bdo commit rows candidate verdicts [--write]` closes a batch without
stopping the run: PASS rows go to the API, everything else is appended to
`state/quarantine.jsonl` with a reason. A run over a whole patch is capped by
the API quota of 5000 written rows per day.

A run is pinned to one environment. The primary derives it from the owner's
wording (`на прод` -> prod, otherwise local), states it back in one line, and
calls `./bdo run start local|prod` before the first batch; `./bdo run end`
closes the run. Switching target mid-run is refused by the script, because half
a patch landing in the wrong environment is far more expensive than a restart.

`bdo commit --write` checks every batch against the pinned target. A run
that was never started, a mismatch with the current `BDO_API_ENV`, an exhausted
quota, or a QA verdict array shorter than the batch all quarantine the batch
instead of failing the run.

Payloads reach `translation-worker`, `translation-repair` and `translation-qa`
as TEXT in the prompt, never as a file path. These three have no tools at all,
and that is a correctness requirement, not a preference: a tool call turns
constrained decoding off, so the staged schema stops binding the answer. Measured
2026-08-20 on QA session `ses_fe11de584ffeLjGxtFaJkIuDzp` · four `read` calls, and
an answer of 20 objects carrying only 11 distinct `identity_hash` values, which
the schema's `enum` plus fixed array length makes impossible when it is in force.

An earlier revision passed file paths here to keep batches out of the paid
context (~6x in paid tokens on the live patch). Keep that saving through smaller
batches and `to-translate.json` instead. `translation-terminology` is the one
child without a schema, but it no longer reads files either: its input is a
compact payload too.

## Latin homoglyphs are a broken character, not a style issue

The model regularly writes a Latin `E` inside a Ukrainian word: `Eданa` instead
of `Едана`. It looks identical and breaks everything that compares strings -
search, sorting, glossary matching. On a live 20-row batch this hit 14 rows and
QA correctly marked every one of them REVIEW, which would have sent 70% of the
batch to moderation for a defect a script fixes for free.

`./bdo normalize candidate.json > clean.json` runs before the gates and
repairs it deterministically. The rule is mixed script, not Latin presence: a
word containing BOTH Cyrillic and Latin is contaminated and gets its Latin
letters mapped to Cyrillic twins; a purely Latin word (`HAN`, `Everlight`, `AP`)
is left alone, because those are legitimate and appear in a third of the corpus.

`Quality\Defects` also reports homoglyphs, so anything the normaliser misses
still surfaces as a defect instead of passing silently.

## Russianisms need a dictionary, not a letter check

Checking for `ы`, `э`, `ъ`, `ё` catches only part of the problem. The dangerous
russianisms are spelled with Ukrainian letters and pass straight through: on a
live 40-row batch the pre-MTP model wrote `Камень пересікування` in six rows and
the letter check reported zero defects. Only the dictionary in
`Quality\Russianisms` found them.

`bdo russianisms candidate.json rows.json` exits 1 when it finds any;
`Quality\FixPolicy` uses the same dictionary to refuse a fix that introduces one.

**The glossary always wins.** An approved canonical rendering may itself contain
a word from the dictionary - `Embers of Ynix - Armor` is canonically `Доспехи
Жарів Іксіна`. The translator is required to reproduce it, so the detector must
not block the batch for it: `Russianisms::allowedByGlossary($row)` legalises, for that
row only, every pattern present in that row's approved `ukrainian`. A `mandatory`
term with `ukrainian: null` legalises nothing. Always pass `rows.json`, otherwise
the glossary is invisible and canonical terms turn into false positives.

The list holds only words with an unambiguous Ukrainian counterpart, and each
pattern is matched as `/\b<pattern>\b/iu` with any suffix wildcard written
explicitly. A greedy stem is not a harmless over-catch: `камен(ь|я|ю)\w*` flagged
the Ukrainian `Каменюка`, and `каменя`/`каменю` are normal Ukrainian - only the
nominative `камень` is Russian. Same for `дерево`, `мешканець`, `молоток` and
`заданий`. A false positive blocks a good translation, which is worse than a
missed case.

## A QA fix is a proposal, not a verdict

`bdo qa-fixes` never passes a fix through untouched. Measured on a live 40-row
batch: QA returned 6 fixes and 4 were corrupted text - `Сутінки Кінця - Сережки`
came back as `Суттинки Слитинця - Серінка`, and one identical fix was emitted for
two different rows. Applying them blindly would have replaced good translations
with garbage.

Similarity alone does not separate the two: the correct fixes scored 95% and 40%,
the corrupted ones 72%, 76% and 78% - right between them. So the filter accepts
only a small edit (>=85% similar) that also keeps tokens, placeholders, limits,
carries no Russian letters and is not repeated across rows. Everything else goes
to `translation-repair`, which sees the source and the glossary. An extra repair
call costs seconds; a silent corruption costs data.

## Healing rotation: quarantine is the last resort, not the second step

The point of a run is delivered translations, not a tidy quarantine file. So a
non-PASS row is not written off after QA - it climbs a ladder, and each rung is
tried only because the cheaper one below it failed:

| Rung | Who fixes | Model calls |
|---|---|---|
| 1 | the API itself - `validate` returns `status: repaired` with `repaired_text` | none |
| 2 | QA's own `fix`, if it survives the `bdo qa-fixes` filter | none |
| 3 | `translation-repair`, on the failing rows only | one per round |
| 4 | quarantine - only what rung 3 could not fix in N attempts | - |

`./bdo heal rows.json candidate.json verdicts.json [validate.json]` runs the
whole ladder in one command. It writes `state/heal-merged.json` (the candidate
with rungs 1-2 already applied) and `state/heal-repair-payload.json` (only the
rows that still need a model, each with its source, current text, concrete
defects, keep-tokens, glossary and limits). It never calls a model itself.

Rung 1 is free and was being thrown away: the server repairs some rows on its
own and returns the text, and until now `bdo validate` only printed it.

**Exactly one healing round, and it is enforced by the script.** The sequence is
fixed: `worker -> QA -> heal-plan -> repair -> control QA -> batch-commit`. That
is at most five child sessions per batch, terminology aside.

`bdo heal` counts attempts per row in `state/heal-attempts.json`, keyed by a
hash of the batch's identity set, so a new batch starts from zero without anyone
remembering to reset. After `BDO_HEAL_MAX_ATTEMPTS` (1 by default) a row is no
longer sent to repair: whatever is still not PASS goes to moderation, where a
human looks at it.

The limit is 1 because chasing 100% PASS is expensive and buys little: on
2026-08-16 a 20-row batch consumed 11 child sessions (5 QA, 3 repair, 2
terminology) to rescue a handful of rows. Showing such a row in the moderation
queue costs nothing and is more useful than another model round.

Re-QA the subset, never the whole batch: a row that already passed does not get
re-judged, which keeps each round cheap and stops a healthy row from being
"fixed" into a defect.

## Recovery playbook: fix at minimal cost

Never restart the whole batch for a partial failure. Each failure has one
designated recovery step:

| Failure | Recovery (only the affected rows) |
|---|---|
| worker died mid-run / timeout | re-run `translation-worker` with the same staged schema and payload; nothing else changes |
| validation rejected K rows | `./bdo subset rows.json h1,h2 subset.json` -> `./bdo schema build subset.json` -> `./bdo payload worker subset.json` -> `translation-repair` with defects + payload -> `./bdo merge candidate.json fixes.json merged.json` -> re-validate merged |
| QA reported REVIEW/REJECT rows | `./bdo heal rows candidate verdicts [validate]` - it applies the free rungs and hands you the repair payload; see the healing rotation above |
| `bdo qa-fixes` rejected a fix | that row goes to `translation-repair`, never to merge. Do not override the filter |
| QA answer rejected by its schema | re-run `translation-qa` only, same payload, no re-translation |
| glossary term blocked | `translation-terminology` for that term only; rows wait, nothing is discarded |
| runtime doubt (wrong model, schema not applied) | `@translation-smoke`, then `./bdo runtime`; zero batch cost |

After any repair: re-stage the FULL batch schema (`./bdo schema build rows.json`)
before the next full-batch worker run, or clear it; a stale subset schema would
block a full-batch call by length mismatch.

## Primary token economy

- Child sessions run on the free local model; their tokens cost nothing. The
  primary pays for what it writes into a child prompt and reads back.
- Pass `bdo payload terminology` output to `translation-terminology`; it reads
  nothing. Measured before this change: 420 244 and 124 920 input tokens on two
  sessions, more than the rest of the flow combined.
- Pass only `bdo payload worker` output to worker/repair and only
  `bdo payload qa` output to qa - never the raw rows.json with classification
  and service fields. QA cannot read files: a schema-constrained answer cannot
  carry a tool call, so its whole input arrives in the prompt. That costs the
  primary a bounded ~1-2k tokens per batch and buys a guaranteed per-row
  verdict, which prose reporting failed to deliver.
- The primary never translates, reviews or repairs text itself and never
  "fixes up" a child answer: a defective answer goes back through the playbook.
- Helpers print one-line summaries; the primary does not re-read written files.

## Invariants

- Start one translation child session at a time. Wait for its final response
  before creating the next one.
- This is the ONLY flow. The autonomous script orchestrator was DELETED from the
  repository on 2026-08-22 (still in history, commit `dac631e`): it is not an
  alternative entrypoint, and no shell runner in this flow may invoke a language
  model. One narrow exception exists: `bdo bench` benchmarks a
  local model on a real batch. It produces a measurement, not a translation, and
  that is enforced rather than trusted - its output goes to `output/benchmark/`
  and both write paths (`bdo items`, `bdo commit`) refuse a candidate
  from that directory. It also builds its schema with `--out` into a temp file,
  so a benchmark can never overwrite the staged schema of a live batch.
- Model choice is decided by speed and format compliance, not by the quality of
  one sample. Measured on the chosen model: five runs over the same 40 rows
  produced 0, 6, 0, 6, 0 russianisms. Speed was stable to within 0.2 tok/s across
  runs; quality was not. Any quality claim needs 3-5 runs, and the mechanical
  detector stays mandatory regardless of which model is active.
- The plugin sends a staged schema as `response_format` for
  `translation-worker`, `translation-repair` (batch schema) and
  `translation-qa` (verdict schema). Each pins `identity_hash` through `enum`
  and fixes the array length, so the model cannot drop, duplicate or invent an
  identity, and cannot answer for fewer rows than the batch holds.
  `translation-terminology` answers in prose and is never constrained.
- `translation-worker`, `translation-repair` and `translation-qa` receive their
  rules and their whole input from the prompt and have no tools at all. A schema
  does not prevent tool calls, so the empty tool list is what keeps a child from
  wandering off into web search mid-batch.
- `translation-smoke` calls no tool at all. Its one-line answer is itself the
  proof: the plugin let the route through, thinking is off, the local model
  replied. Provider and model are shown by the UI Context panel.
- The staged schema never replaces the deterministic gate: `bdo items`
  rejects a hash outside `rows.json`, a duplicate hash, an empty text and,
  with `--require-all`, an incomplete batch.
- Primary agents may delegate only to the five named `translation-*` agents.
- `translation-smoke` is the fast no-side-effect runtime check. Invoke it with
  `@translation-smoke` in the OpenCode UI. `./bdo runtime` covers the same
  ground deterministically and without an LLM.
- Before restarting OpenCode, run `bash .opencode/validate-translation-agents.sh`.
  It checks config, frontmatter models and child permissions, not a live session.
- After a live run, `./bdo audit` reads the OpenCode database and reports the
  real provider, model, tokens and tool calls of every child session, flagging
  ROUTE, THINK, TOOLS and EMPTY violations. Trust it over any agent's self-report:
  a primary model already claimed a wrong provider and missed a plugin error.
- Use the `translation` primary agent for batch work. Its rules live
  in its own definition, so the five children never carry them in context.
- Child agents do not write files, call nested tasks or perform BDO write API
  requests.
