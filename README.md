# bdo-ua-ai-localization

Публічний toolkit агентного й субагентного перекладу Black Desert Online
українською для [BDO UA Translate](https://bdo-ua.com.ua). Локальні GGUF-моделі
виконують мовну роботу, а shell/PHP gates перевіряють identity, markup і якість
перед записом через Agent API.

Це не універсальний перекладач і не серверний застосунок. Тут немає БД,
moderation UI або deploy: серверний проєкт надає authoritative Agent API, а цей
репозиторій є окремим клієнтом із prompts, orchestration, state та quality gates.

## Вимоги

| Компонент | Вимога |
|---|---|
| API | Agent key у локальному `.env`; local і production мають окремі keys |
| Моделі | Ollama з allowlisted GGUF; MLX заборонений |
| Runtime | Bash, PHP CLI 8.3+, jq, curl, ShellCheck |
| Опційно | OpenCode для супервізованого flow з видимими child sessions |

## Швидкий старт

```bash
cp .env.example .env
git config core.hooksPath .githooks
bash scripts/agent-check.sh preflight
bash scripts/agent-check.sh full
bash scripts/agent-check.sh runtime
bash scripts/agent-check.sh api
./translate-menu.sh
```

Заповнюйте ключі лише в `.env`. Не вставляйте їх у команди, документацію, issue,
prompts або логи. `runtime` викликає локальну модель; `api` виконує read-only smoke
проти local target за замовчуванням.

## Публічна безпека

- `.env` і `.env.*` ніколи не комітяться; у Git є лише безпечний `.env.example`.
- API keys, tokens, passwords, credential/session hashes, private URLs, dumps,
  домашні шляхи та персональні дані заборонені у tracked files і повідомленнях.
- `identity_hash`, `source_hash` та checksum є технічними contract IDs, а не
  credentials; повні payload/state dumps однаково лишаються приватними.
- `output/`, `state/`, `state-auto/`, OpenCode sessions і runtime logs локальні.
- Production write потребує дозволу власника на конкретний прогін; default · local.

Повний contract і порядок дій при витоку · [docs/SECURITY.md](docs/SECURITY.md).

## Два translation flows

### OpenCode flow

Primary agent оркеструє видимі named child sessions. Worker, repair і QA працюють
під constrained schema без tools; provider/model pin-яться frontmatter, plugin
guard та allowlist. Фактичний provider/model/tool usage після run перевіряє
`verify-run.sh`, а не self-report моделі.

Canonical sequence · [UI_SUBAGENT_WORKFLOW.md](UI_SUBAGENT_WORKFLOW.md).

### Автономний flow

`translate-patch.sh` і `translate-menu.sh` ведуть довгі прогони через ті самі
prompts і gates. State живе в `state-auto/`, cursor окремий для кожної selection і
рухається лише після завершення batch. Dry run cursor не змінює.

OpenCode та autonomous flow не запускаються одночасно: state ізольований, але
Ollama спільна, і конкурентні запити пошкоджують відповіді.

## Безпечна послідовність batch

1. Отримати rows через штатний fetch helper.
2. Перевірити glossary gaps і translation memory.
3. Побудувати constrained schema для rows, які лишилися.
4. Передати worker лише компактний текстовий payload.
5. Розгорнути memory/twins, нормалізувати homoglyphs.
6. Пройти deterministic identity/quality gates та API validation.
7. Запустити незалежний QA й одне bounded healing коло.
8. PASS записати у вибраний layer; defects · у moderation; transport failures ·
   у quarantine.
9. Перемістити cursor лише після повного завершення batch.

Ad-hoc API write, alternate model runner або власний payload builder заборонені:
вони обходять guards, через які цей toolkit існує.

## Канали запису

| Channel | API semantics | Призначення |
|---|---|---|
| `machine` | `layer=machine`, `mode=direct` | Машинний шар після validation |
| `manual` | `layer=manual`, `mode=proposal`, auto-approve за правом | Контрольований ручний flow |
| `proposal` | `layer=manual`, `mode=proposal`, без auto-approve | Moderation queue |

Роль і capability завжди перевіряються через `/me`. Деталі ·
[API_WRITE_CONTRACT.md](API_WRITE_CONTRACT.md).

## Структура

```text
.opencode/agents/   prompts і frontmatter named translation agents
.opencode/plugin/   routing/model/schema guard
lib/                PHP identity, batch, quality та API payload logic
scripts/            єдиний quality gate
docs/               фактичні довідники
docs/plans/         backlog/active/done lifecycle
state/              локальний state OpenCode flow
state-auto/         локальний state autonomous flow
output/             локальні responses, diagnostics, benchmarks
```

Навігація по документації · [docs/README.md](docs/README.md). Архітектурні межі ·
[docs/PROJECT_OVERVIEW.md](docs/PROJECT_OVERVIEW.md). Фактичні виміри та incidents ·
[docs/FLOW_STATE.md](docs/FLOW_STATE.md).

## Quality gate

```bash
bash scripts/agent-check.sh preflight  # до роботи
bash scripts/agent-check.sh docs       # rules, plans, env, public safety
bash scripts/agent-check.sh shell      # bash, ShellCheck, PHP syntax
bash scripts/agent-check.sh agents     # OpenCode config, prompts, allowlist
bash scripts/agent-check.sh runtime    # локальна модель
bash scripts/agent-check.sh api        # read-only local API smoke
bash scripts/agent-check.sh full       # deterministic local gates
```

`full` навмисно не викликає модель або API. Gate не пише в API, не деплоїть, не
видаляє state і не змінює Git.

## Планування

Уся робота має єдиний lifecycle:

- реєстр планів · [docs/plans/README.md](docs/plans/README.md);
- загальна черга · [docs/plans/BACKLOG.md](docs/plans/BACKLOG.md);
- незавершені плани · `docs/plans/backlog/` і `docs/plans/active/`;
- доказово закриті плани · `docs/plans/done/`.

`docs/*.md` описують поточний стан; план не видається за реалізовану поведінку.
