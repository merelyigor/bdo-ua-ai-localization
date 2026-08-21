# bdo-ua-ai-localization: коротка карта для AI-агента

Це публічний toolkit скриптів і промптів для агентного та субагентного перекладу
Black Desert Online через BDO UA Translate Agent API. Тут немає серверної БД або
вебзастосунку. Повний норматив ·
[`docs/AI_AGENT_RULES_REFERENCE.md`](docs/AI_AGENT_RULES_REFERENCE.md).

`AGENTS.md`, `.cursorrules`, `CLAUDE.md` і `QWEN.md` мають бути byte-identical.
`§N.M` нижче завжди означає правило нормативного довідника. Відповідь власнику ·
українською; код, ідентифікатори, команди та логи не перекладати.

## 1. Пріоритет і стоп-умови

1. Вказівка власника в поточній задачі має пріоритет, крім безпекових і
   юридичних заборон.
2. Не вигадуй файл, API, прапорець, ENV-змінну, модель або результат перевірки.
   Спочатку факт: `rg`, targeted read, код, лог або реальна команда.
3. Після двох однакових невдалих спроб зупини повторення, встанови причину й
   зміни підхід. Третя ідентична спроба заборонена.
4. Зупинись і попроси рішення, якщо вимога суперечить правилам, ціль суттєво
   неоднозначна, потрібен новий дозвіл або дія необоротна.
5. Не розширюй задачу рефакторингом, залежністю чи абстракцією без потреби.

## 2. Публічність і незмінні заборони

- Репозиторій читає будь-хто. Ключі, токени, паролі, credential/session hashes,
  приватні URL, дампи, prod-env, персональні дані й домашні шляхи не потрапляють
  у tracked files, prompts, логи, коміти або відповіді. Деталі · §2 і §3.
- Чутливі значення живуть лише в локальному `.env`, який заборонено комітити.
  У Git є тільки `.env.example` з порожніми або явно безпечними прикладами.
- Технічні `identity_hash`, `source_hash` і checksum не є credentials: вони
  дозволені там, де потрібні контрактом, але дампи payload/state публікувати не можна.
- `git commit`, `push`, force/rebase/tag та зміна історії · лише за одноразовим
  явним дозволом. AI-атрибуція у файлах і commit messages заборонена.
- Production write (`--env prod`) · лише з дозволом на конкретний прогін. За
  замовчуванням `local`; production read-only діагностика дозволена.
- Не стирати й не перезаписувати manual revisions, moderation decisions,
  glossary або audit trail. Не підміняти `manual`, `machine` і `proposal`.
- Не видаляти `output/`, `state/`, `state-auto/`: там курсори, квитанції й
  карантин. `batch-clean.sh` без `--apply` лише показує.
- Не чіпати чужі незакомічені зміни. Ніколи `git add -A`, `git add .` або
  `git commit -a`; перед стартом і фіналом звіряти status та власний diff.
- Не змінювати identity (`source_language + key0 + record_id + key1`), PA markup,
  placeholders і квадратні теги. Підстановка згадок · лише для предметів.
- Субагентам під constrained schema заборонені всі tools; payload передається
  текстом. Лише GGUF-моделі з allowlist; MLX заборонений.
- OpenCode flow і `translate-patch.sh` не запускати одночасно: вони ділять Ollama.

## 3. Обов'язковий цикл

1. `bash scripts/agent-check.sh preflight`.
2. Сформулюй одну ціль і Definition of Done; велику задачу розбий на кроки.
3. Знайди реалізацію, конфіг, тести й усі call sites. Читай лише документи своєї
   категорії з таблиці нижче.
4. Зроби найменшу цілісну зміну. Доказ: реальний приклад -> вузька перевірка ->
   профіль gate. Доказ має бути в цільовій конфігурації.
5. Для поведінкового бага додай regression test. Не змінюй тест, доки не доведено,
   що саме очікувана поведінка змінилась.
6. Перед необоротною дією назви, що зникне, як відновити і що перевірити після.
7. Переглянь diff: secrets, `output/`, `state*/`, `tmp-*`, scope drift і чужі зміни.
8. Зміни flow синхронізуй із `docs/FLOW_STATE.md`; план · з реєстрами plans.

## 4. Маршрутизація знань

| Зміна | Прочитати до редагування | Gate |
|---|---|---|
| Shell/PHP helper, batch або state | `docs/PROJECT_OVERVIEW.md`, релевантні call sites, §4-§6 | `agent-check.sh shell` |
| Agent API read/write contract | `API_WRITE_CONTRACT.md`, серверні API docs через `TRANSLATE_PROJECT_ROOT`, §7 | `agent-check.sh shell` + `api` |
| OpenCode agent/plugin/model | `UI_SUBAGENT_WORKFLOW.md`, `docs/FLOW_STATE.md`, §8 | `agent-check.sh agents` + `runtime` |
| Translation quality/identity/glossary | `UI_SUBAGENT_WORKFLOW.md`, `docs/FLOW_STATE.md`, §6-§8 | `agent-check.sh full` |
| Secrets, env, public safety | `docs/SECURITY.md`, §2-§3 | `agent-check.sh docs` |
| Правила або документація | `docs/AI_AGENT_RULES_REFERENCE.md`, `docs/README.md`, §9-§10 | `agent-check.sh docs` |
| План або статус роботи | `docs/plans/README.md`, `docs/plans/BACKLOG.md`, §9 | `agent-check.sh docs` |

Серверна реалізація живе в `bdo_ua_translate` і звідси лише читається через
`TRANSLATE_PROJECT_ROOT`. Не дублювати й не редагувати її в межах цього repo.

## 5. Єдиний quality gate

```bash
bash scripts/agent-check.sh preflight
bash scripts/agent-check.sh docs
bash scripts/agent-check.sh shell
bash scripts/agent-check.sh agents
bash scripts/agent-check.sh runtime
bash scripts/agent-check.sh api
bash scripts/agent-check.sh full
```

`runtime` викликає локальну модель, `api` робить read-only API smoke. `full` не
викликає зовнішні runtime/API gates. Ніколи не заявляй успіх без exit 0; недоступну
перевірку назви окремо з причиною та ризиком. Гейт не пише в API, не деплоїть,
не видаляє state і не змінює Git.

## 6. Ключова структура й інваріанти

| Що | Де |
|---|---|
| Публічна навігація | `README.md`, `docs/README.md` |
| Повний норматив і security | `docs/AI_AGENT_RULES_REFERENCE.md`, `docs/SECURITY.md` |
| Два translation flows | `UI_SUBAGENT_WORKFLOW.md`, `docs/FLOW_STATE.md` |
| Контракт запису | `API_WRITE_CONTRACT.md` |
| Промпти/guard/allowlist | `.opencode/agents/`, `.opencode/plugin/`, `.opencode/validate-translation-agents.sh` |
| Layout/env | `paths.sh`, `.env.example` |
| Планування | `docs/plans/README.md`, `docs/plans/BACKLOG.md` |
| Єдиний gate | `scripts/agent-check.sh` |

- Стек: Bash, PHP CLI 8.3+, jq, curl, Ollama GGUF, опційно OpenCode.
- Shell є transport/orchestration; PHP у `lib/` тримає identity і quality logic.
- HTTP лише через штатні helpers; ad-hoc запис або власний model runner заборонені.
- Стан пачок ізольований manifest-ом; cursor рухається лише після завершення пачки.
- Видимий текст українською, без російської, латинських гомогліфів у кирилиці й
  типографського тире. `BDO` означає Black Desert Online.

## 7. Git і фінал

- Commit message після дозволу · тільки за `.codex/prompts/commit-message-ua.txt`;
  версія зростає, жодних trailers або AI-атрибуції. Hooks path · `.githooks`.
- Фінал має два блоки: `## Звіт`, останнім `## Що далі`.
- `## Звіт`: **Зроблено** -> **Зʼясовано** з доказом кожного висновку ->
  **Перевірки** з командами, результатами, пропусками та ризиками -> `SEO-check`
  -> `OSM-check`. Виправлення власної хибної заяви · окремий рядок.
- `## Що далі`: статус, 2-4 варіанти, перший рекомендований, потреба від власника,
  Done criteria. Аналіз над звітом короткий; звіт фіксує результат, не процес.
