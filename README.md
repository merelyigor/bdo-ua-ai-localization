# bdo-ua-ai-localization

AI-assisted localization toolkit for [BDO UA Translate](https://bdo-ua.com.ua) ·
the Ukrainian translation of Black Desert Online. Local models do the language
work, shell scripts hold the guarantees, and nothing reaches the database that a
mechanical gate has not checked.

This is **not** a general-purpose translation tool. It talks to one specific
server · the BDO UA Translate Agent API · and it encodes that project's rules:
row identity, translation layers, glossary, moderation queue, PA markup. Read it
as a working reference for how to run batch machine translation with local models
and keep the result auditable; reuse the pattern, not the endpoints.

## What it needs

| | |
|---|---|
| API | An agent key for the BDO UA Translate Agent API (`X-API-Key`). Local and production targets are separate keys. |
| Models | [Ollama](https://ollama.com) serving a GGUF model. Default `qwen3.6:35b-a3b-mtp-q4_K_M` (quality) / `qwen3.5:9b` (fast). MLX builds are rejected: their runner ignores constrained decoding. |
| Runtime | `bash`, `php` (CLI, 8.3+), `jq`, `curl`. No Composer packages · `lib/` is plain PHP with its own autoloader. |
| Optional | [OpenCode](https://opencode.ai) for the supervised flow with visible child sessions. The autonomous flow needs only the shell. |

## Quick start

```bash
cp .env.example .env    # put in the API key and base URL
./paths.sh              # check the on-disk layout resolves
./check-runtime.sh      # check the local model honours the flow contract
./test-api.sh           # read-only API connectivity test
./translate-menu.sh     # control panel for the autonomous flow
```

## Keys and safety

The API key lives in `.env` and nowhere else. `.env` is git-ignored and has never
been committed. A `pre-commit` hook is shipped with the repository to keep it that
way · enable it once per clone:

```bash
git config core.hooksPath .githooks
```

It refuses a commit that stages `.env`, that contains any value from your local
`.env` (the usual way a key escapes is a copy-pasted `curl` example, not the file
itself), or that looks like someone else's secret. Bypass deliberately with
`git commit --no-verify`.

`output/`, `state/` and `state-auto/` hold run artefacts · API responses, batch
workspaces, saved cursors. They stay local; only the directory markers are tracked.

## How the language work runs

Language work runs only through visible OpenCode child sessions. The primary
agent may use a remote model; `translation-*` child agents have an explicit
local Ollama model in `.opencode/agents/` (`qwen3.6:35b-a3b-mtp-q4_K_M` quality / `qwen3.5:9b` fast).

There are TWO separate flows sharing the same prompts, schemas and gates:

1. **OpenCode flow** - the paid model orchestrates visible child sessions.
   The canonical process is in [UI_SUBAGENT_WORKFLOW.md](UI_SUBAGENT_WORKFLOW.md).
2. **Autonomous flow** - `./translate-patch.sh` orchestrates from the terminal,
   calling the same local models directly via `agent-call.sh`. Its state lives
   in `state-auto/` and never intersects with the OpenCode flow. Built for long
   mass runs (whole patch, full game retranslation). Do not run both at once:
   they share one Ollama model and concurrent requests corrupt each other.
   Day-to-day control is `./translate-menu.sh` - status, background start,
   graceful stop, resume, per-selection cursors.

## Autonomous flow: control surface

```bash
./translate-menu.sh
```

The menu is a five-step wizard, and the steps are orthogonal on purpose - any
combination is reachable:

1. **Where from** - the active patch, or the whole game.
2. **Which rows** - all of them, or one category (item names, quest names, quest
   texts, NPC names, world, knowledge, dialogue, titles, UI, pearl shop, market,
   skill effects, missions, or a custom domain + semantic type).
3. **What kind of translation** - manual (take rows with no manual layer, write
   the manual layer), AI (take rows with no AI layer, write the AI layer),
   manual-but-everything-to-moderation, or retranslate over the top.
4. **Where to** - local, or production.
5. **How much** - batch size, batch count, preview without writing.

A confirmation screen restates the choice in plain words, shows the composed API
query, whether any work is left, and whether this direction already has a saved
position.

Under the hood the wizard passes `--query`, `--channel`, `--env`, `--size` to
`translate-patch.sh`; the same flags remain available directly, and `--scope
patch|all|manual-all|retranslate` still works as a shorthand.

Rows flagged by QA go to moderation regardless of channel and role. A new item
name goes to moderation only in a manual run - in an AI-layer run it is an
ordinary new translation, not a defect.

Memory (`--memory all|manual`) picks which layers count as translation memory.
A manual or proposal channel defaults to `manual`: with 941,273 machine heads
against 23 manual ones (measured 2026-08-16), unfiltered memory would copy the
very AI text the manual pass is meant to replace.

A preview run (`--dry`) deliberately does not save the position: otherwise
"just look at it" would silently consume rows that never got written.

Stopping. Graceful - the stop menu or `touch state-auto/stop`: the current batch is
finished, then the run exits and the cursor is saved. Hard - Ctrl+C: the batch
dies mid-flight, but its rows are **not** lost, because the cursor only advances
after a batch completes. Each selection keeps its own cursor
(`state-auto/cursor-<query hash>`), so switching between patch and manual passes
does not make one skip the other's rows.

## Remaining helpers

The remaining shell scripts only interact with the BDO Agent API. They do not
call a language model and do not create OpenCode subagents.

- `patch-info.sh`: read active patch statistics.
- `fetch-rows.sh`: fetch an explicitly requested row batch.
- `row-context.sh`: read context for one immutable row identity.
- `memory-lookup.sh`: ask whether this exact English source is already translated.
- `memory-apply.sh`: close rows from memory, deduplicate identical sources in the
  batch, leave the rest to the model.
- `memory-expand.sh`: reassemble the full batch from model output, twins and memory.
- `show-rows.sh`: print a fetched batch in readable form.
- `glossary-resolve.sh`: confirm the immutable identity of a canonical name.
- `glossary-gaps.sh`: list canonical terms of a batch that have no approved rendering.
- `build-schema.sh`: stage the constrained-decoding schema for the current batch.
- `worker-payload.sh`: print the compact payload to paste into worker/repair.
- `qa-payload.sh`: print the compact payload to paste into translation-qa.
- `subset-rows.sh`: cut a subset of rows for minimal-cost retry or repair.
- `check-russianisms.sh`: dictionary scan for russianisms written in Ukrainian
  letters; pass `rows.json` too, so an approved glossary term is not flagged.
- `qa-fixes.sh`: turn QA verdicts into a ready fixes file.
- `heal-plan.sh`: drive a batch to full PASS - applies the free fixes, prepares
  the repair payload for the remaining rows, caps attempts per row.
- `sync-opencode-models.sh`: check (and with `--apply` fix) that the OpenCode
  provider declares the models the project agents use.
- `merge-items.sh`: merge repair fixes into the candidate without re-translation.
- `set-translation-profile.sh`: switch the subagent model between quality and fast.
- `check-runtime.sh`: verify the local Ollama runtime honours the flow contract.
- `verify-run.sh`: audit real subagent sessions from the OpenCode database.
- `moderation-queue.sh`: list the pending translation proposals and approve or
  reject them in batches over the API (`--approve`, `--reject --reason`,
  `--approve-batch N`, `--row <hash>`, `--dry`). Needs the `translations:review`
  ability on the key; the same claim+decide workflow the admin UI uses.
- `translate-patch.sh`: autonomous patch translation - the whole batch cycle
  from the terminal; modes: --scope, --channel, --memory, --batches, --rows,
  --size, --dry, --env, --query, --reset.
- `translate-menu.sh`: control panel for the autonomous flow - the wizard above,
  status, quota, named per-selection positions, background start with a log,
  graceful/hard stop, failures, file rotation. Refuses a production run while
  the deployed API is older than 1.8.8, because such a server auto-approves what
  should have gone to moderation.
- `agent-call.sh`: call one subagent directly (worker/repair/qa) with the same
  project prompts, model allowlist and constrained schema as in OpenCode.
- `merge-verdicts.sh`: overlay control-QA verdicts onto the full verdict set.
- `audit-dump.sh`: dump full OpenCode session contents for deep run audits.
- `model-ab.sh`: benchmark one local model on a real batch (speed, format,
  russianisms). The only script here that calls a model; its output lands in
  `output/benchmark/` and the write path refuses that directory.
- `build-items.sh`: build a safe write payload and reject foreign or duplicate
  identities.
- `validate.sh`: validate a prepared candidate batch.
- `run-start.sh`: pin one environment for the whole run.
- `batch-new.sh`: start a batch - creates its own isolated directory.
- `batch-dir.sh`: print the current batch directory.
- `batch-assert.sh`: verify that rows/candidate belong to the current batch.
- `batch-clean.sh`: rotate finished batch directories and old API responses.
- `batch-commit.sh`: close a batch - write PASS rows, quarantine the rest.
- `write-translations.sh`: explicit machine-layer write after owner approval.
- `test-api.sh`: read-only API connectivity test.
- `select-env.sh`: pick the local or production API target; sourced by the others.
- `run-in-docker.sh`: run a helper inside the project PHP container.
- `paths.sh`: resolve where the agent prompts, the OpenCode config and the served
  project live; sourced by the scripts that need them, and runnable on its own to
  print the resolution. See "On-disk layout" below.

## On-disk layout

Nothing here hardcodes a position inside one specific project. The scripts that
need the subagent prompts or the OpenCode config resolve them through
`paths.sh`, which looks first next to this toolkit and then one level up, so the
same code works both as a subdirectory of the served project and as a separate
repository sitting beside it:

```bash
./paths.sh
```

The report prints the four resolved paths and exits non-zero if one is missing.
Every one of them can be overridden by an environment variable · the full list,
with the docker and env-file variables, is documented in `.env.example`.

`TRANSLATE_PROJECT_ROOT` is the one that has no useful default here: it points at
the checkout of the served Laravel project, and is only needed when you want to
read its docs or reach its container. The API itself is reached over HTTP, so the
flow runs without it.

The routing plugin finds the staged schemas through `TRANSLATE_TOOLKIT_DIR`, which
defaults to `.` · the toolkit is the repository root. Set it to a subdirectory
name if you ever vendor this toolkit inside another project.

## Batch isolation

Each batch gets its own directory `state/batches/<time>_<identity-key>/` created
by `batch-new.sh`; every working file of that batch lives there. Before this,
working files had fixed names in `state/` and the second batch silently
overwrote the first, while rows and candidate filenames were invented per run -
nothing prevented merging one batch's candidate with another batch's rows.

`manifest.json` stores the batch's identity-set key, so membership is checked
rather than assumed: `batch-assert.sh` (also called by `heal-plan.sh`) refuses
rows whose identity set differs and a candidate carrying identities from
outside the batch.

Two things are deliberately NOT per-batch. The staged schema stays at the shared
`state/current-*.json` because it is the "what is constrained right now" pointer
that the OpenCode plugin reads by a fixed path - and a stale schema cannot leak
into another batch anyway, since it pins both the array length and the identity
enum. `state/quarantine.jsonl` is an append-only ledger across batches and is
never rotated.

Subagents write nothing: `translation-worker`, `translation-repair` and
`translation-qa` have `read` only and `edit: deny`. The primary writes every
file, so isolation is a property of how the primary names paths - which is
exactly why it is enforced by a script instead of a convention.

## Structure

Shell scripts are the CLI surface: arguments, `select-env.sh`, `curl`, exit
codes. Everything else lives in `lib/` as classes under `Bdo\Translate\`,
autoloaded by `lib/autoload.php` (PSR-4, no Composer - these run inside and
outside the container, often before any `composer install`).

```
lib/
  Batch/     Row, RowSet, Candidate      - структура пачки й перекладів
  Quality/   Russianisms, Defects,       - що є дефектом і який fix прийнятний
             VerdictSet, FixPolicy
  Api/       Response, WritePayload,     - конверт відповіді, тіло запиту, коди
             ErrorCodes
```

HTTP deliberately stays in bash. PHP on this machine cannot reach the API over
HTTPS - both `file_get_contents` and ext-curl fail with "unable to get local
issuer certificate" because they do not see the local CA that the system `curl`
does. `Api\Response` therefore parses a body that bash already fetched.

Run `@translation-smoke` in the OpenCode UI to verify that a local child agent
is visible and uses its configured model. Model calls happen only through the
sanctioned entrypoints: OpenCode child sessions, `agent-call.sh` (autonomous
flow) and `model-ab.sh` (benchmark). Anything else inventing its own model call
is a bug.
