# Огляд проєкту

## Призначення

`bdo-ua-ai-localization` · окремий публічний клієнтський toolkit для перекладу
рядків Black Desert Online українською. Він читає й записує дані через BDO UA
Translate Agent API, запускає локальні GGUF-моделі в Ollama та механічно перевіряє
identity, markup і якість до запису.

Toolkit не містить серверної БД, Laravel application, moderation UI або deploy.
Серверна реалізація живе в іншому проєкті й доступна звідси лише read-only через
шлях `TRANSLATE_PROJECT_ROOT`.

## Два flows

| Flow | Оркестратор | Мовна робота | State |
|---|---|---|---|
| Супервізований | primary agent в OpenCode | named `translation-*` child agents | `state/` |
| Автономний | `translate-patch.sh` | ті самі prompts через `agent-call.sh` | `state-auto/` |

Flows не запускаються паралельно: state ізольований, але Ollama спільна. Детальна
послідовність · [UI_SUBAGENT_WORKFLOW.md](../UI_SUBAGENT_WORKFLOW.md), фактичні
виміри й incidents · [FLOW_STATE.md](FLOW_STATE.md).

## Шари

| Шар | Відповідальність |
|---|---|
| Shell | CLI, environment selection, HTTP transport, orchestration, exit codes |
| `lib/` PHP | stable identity, batch membership, quality defects, safe payloads |
| `.opencode/agents/` | вузькі ролі translation worker, QA, repair, terminology, smoke |
| `.opencode/plugin/` | provider/model route, schema й no-thinking guards |
| Agent API | authoritative rows, glossary, validation, revisions, moderation |

HTTP write, model invocation та state lifecycle мають штатні entrypoints. Ad-hoc
`curl`, alternate model runner або саморобний payload обходять guards і заборонені.

## Критичні інваріанти

- Identity: `source_language + key0 + record_id + key1`; API `identity_hash` не
  змінюється й не вигадується.
- PA markup, placeholders, newlines і квадратні теги проходять deterministic та
  server validation.
- Manual, machine і proposal не взаємозамінні; human revisions та moderation
  history не перезаписуються.
- Batch належність перевіряє manifest; cursor рухається після завершення batch.
- Worker/repair/QA під schema не мають tools; payload передається текстом.
- Лише allowlisted GGUF; MLX не забезпечує constrained decoding.
- Production write потребує дозволу на конкретний прогін; default target · local.

## Локальні дані

`.env`, `output/`, `state/`, `state-auto/`, model/runtime logs і OpenCode session
database не є публічними артефактами. Вони не комітяться, не публікуються й не
передаються зовнішнім моделям. Деталі · [SECURITY.md](SECURITY.md).

## Перевірки

Єдиний entrypoint · `scripts/agent-check.sh`:

- `preflight` · layout, environment, rules, env contract;
- `docs` · mirrors, норматив, plans, references, public secret scan;
- `shell` · Bash/ShellCheck/PHP syntax;
- `agents` · OpenCode JSON, frontmatter, allowlist, guard;
- `runtime` · локальна Ollama-модель;
- `api` · read-only local API smoke;
- `full` · усі deterministic local gates без model/API calls.
