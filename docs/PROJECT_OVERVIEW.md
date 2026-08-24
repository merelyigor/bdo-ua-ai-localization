# Огляд проєкту

## Призначення

`bdo-ua-ai-localization` · окремий публічний клієнтський toolkit для перекладу
рядків Black Desert Online українською. Він читає й записує дані через BDO UA
Translate Agent API, запускає моделі через OpenCode та механічно перевіряє
identity, markup і якість до запису.

Toolkit не містить серверної БД, Laravel application, moderation UI або deploy.
Серверна реалізація живе в іншому проєкті й доступна звідси лише read-only через
шлях `TRANSLATE_PROJECT_ROOT`.

## Єдиний вхід

`./bdo` · дерево команд усього набору; `./bdo help flow` · порядок однієї пачки.
Скрипти в корені лишаються реалізацією підкоманд і викликаються напряму без
різниці в поведінці, але штатний шлях в документації й промптах · через `bdo`.
Причина не косметична: агент, який не знайшов штатну команду, писав власну й
обходив гейт identity.

Для власника штатний UX інший: він вручну змінює лише локальний `.env` і працює
через primary-режими OpenCode `патч`, `ручний`, `пропозиції`, `покращення`.
Primary сам виконує всі `./bdo` кроки, gates, аудит і фінальну
`./bdo gate full && ./bdo api`; CLI нижче · довідка розробника/діагностики, не
основний користувацький workflow.

## Один flow

| Flow | Оркестратор | Мовна робота | State |
|---|---|---|---|
| Супервізований | primary agent в OpenCode | named `translation-*` child agents | `state/` |

Автономний flow (`translate-patch.sh` і його пульт) **видалено з репозиторію**
2026-08-22: робочий flow один, і другого entrypoint не існує.

Код лишився в історії Git. Останній коміт, у якому файли присутні · `dac631e`.
Відновлення:

```bash
git show dac631e:archive/legacy-script-flow/translate-patch.sh   # один файл
git checkout dac631e -- archive/legacy-script-flow/              # усю теку
```

Разом із ним прибрано `state-auto/` · це був стан саме того flow; тека тепер
ігнорується цілком, локальні файли лишаються на диску.

Детальна послідовність · [UI_SUBAGENT_WORKFLOW.md](../UI_SUBAGENT_WORKFLOW.md),
фактичні виміри й incidents · [FLOW_STATE.md](FLOW_STATE.md).

## Ціль прогону

`BDO_ENV=PROD|DEV` у локальному `.env` жорстко задає середовище для читання й запису
разом. PROD бере `BDO_API_BASE_PROD` або production default; DEV бере
`BDO_API_BASE_DEV`. Застарілий `BDO_API_BASE` ігнорується. У `.env` лишаються
ключі `BDO_API_KEY_PROD` і `BDO_API_KEY_DEV` та потрібний override адреси.

Розвʼязує це `cli/system/select-env.sh`, і воно ж відмовляє, коли префікс `BDO_API_ENV=`
суперечить файлу · щоб частина прогону не поїхала в інше середовище. Показує
поточну ціль `./bdo env`.

`BDO_ENV` є і ціллю, і дозволом: окремого підтвердження на прод-запис агент не
запитує. Свідома дія власника · правка `.env`; агент лише оголошує ціль перед
першою пачкою. Механічні запобіжники лишились: `./bdo run start` фіксує ціль
прогону, а `./bdo commit --write` звіряє з нею кожну пачку й перевіряє квоту.

## Шари

| Шар | Відповідальність |
|---|---|
| Shell | CLI, environment selection, HTTP transport, orchestration, exit codes |
| `lib/` PHP | stable identity, batch membership, quality defects, safe payloads |
| `.opencode/agent-templates/` → generated/ignored `.opencode/agents/translation-*.md` | tracked child-промпти → локальні ролі worker, QA, repair, terminology, smoke |
| `.opencode/plugin/` | provider/model route, schema й no-thinking guards |
| Agent API | authoritative rows, glossary, validation, revisions, moderation |

HTTP write, model invocation та state lifecycle мають штатні entrypoints. Ad-hoc
`curl`, alternate model runner або саморобний payload обходять guards і заборонені.

## Критичні інваріанти

- Identity: `source_language + key0 + record_id + key1`; API `identity_hash` не
  змінюється й не вигадується.
- PA markup, placeholders, newlines і `tokens.must_preserve` проходять
  deterministic та server validation. Квадратні дужки зберігаються, а вміст
  усередині перекладається, коли теґа немає в `keep`.
- Manual, machine і proposal не взаємозамінні; human revisions та moderation
  history не перезаписуються.
- Batch належність перевіряє manifest; cursor рухається після завершення batch.
- Worker/repair/QA під schema не мають tools; payload передається текстом.
- Маршрути моделей задає generated/ignored `.opencode/translation-models.json`,
  створений із tracked `.opencode/templates/translation-models.json`; Ollama MLX не
  забезпечує constrained decoding, а платні fallback за замовчуванням заборонені.
- Windows підтримується через WSL2; native PowerShell flow не дублюється.
- Ціль і дозвіл на запис дає `BDO_ENV`; `run start` фіксує ціль, `commit --write` її звіряє.

## Локальні дані

`.env`, `output/`, `state/`, model/runtime logs і OpenCode session
database не є публічними артефактами. Вони не комітяться, не публікуються й не
передаються зовнішнім моделям. Деталі · [SECURITY.md](SECURITY.md).

## Перевірки

Єдиний entrypoint · `./bdo gate <профіль>` (реалізація · `scripts/agent-check.sh`):

- `preflight` · layout, environment, rules, env contract;
- `docs` · mirrors, норматив, plans, посилання в усіх документах і промптах, public secret scan;
- `shell` · Bash/ShellCheck/PHP syntax;
- `agents` · OpenCode JSON, frontmatter, allowlist, guard;
- `runtime` · локальна Ollama capability-перевірка або інструкція OpenCode smoke;
- `api` · read-only API smoke проти цілі з `.env`;
- `full` · усі deterministic local gates без model/API calls.
