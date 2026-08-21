# Правила, безпека і документація публічного translation toolkit

- **Статус:** done (закрито 2026-08-21)
- **Створено:** 2026-08-21
- **Реєстр:** [docs/plans/README.md](../README.md)

## Мета

Актуалізувати `bdo-ua-ai-localization` як окремий публічний репозиторій для
агентного й субагентного перекладу через BDO UA Translate Agent API. Правила,
документація і gates мають одночасно захищати секрети та людські дані, точно
описувати два translation flows і не дублювати серверну реалізацію.

## Підтверджена база

- Серверний `AGENTS.md` маршрутизує клієнтський translation flow саме сюди, а в
  серверному репозиторії лишає Agent API.
- Шаблон правил задає структуру `коротка карта + нормативний довідник +
  виконуваний gate` і byte-identical `AGENTS.md`, `.cursorrules`, `CLAUDE.md`,
  `QWEN.md`.
- Поточний репозиторій уже має `.env` у `.gitignore`, pre-commit secret scan і
  заборону production write без дозволу, але не має нормативного довідника,
  єдиного профільного gate, docs index, security policy або lifecycle планів.

## Рішення власника

1. Чотири root rule-файли мають бути дослівно однаковими.
2. Заборонені credential/session/token/password hashes і дампи. Технічні
   `identity_hash`, `source_hash` та checksum артефактів є частиною контракту й
   дозволені у відповідному робочому контексті.
3. Основний `README.md` має бути українською.

## Межі

- Серверний репозиторій використовується read-only і не редагується.
- Production write, commit, push, переписування історії та видалення стану не
  входять у задачу.
- Поведінку перекладу, API payload та identity не змінювати без підтвердженого
  дефекту.
- Наявні робочі `output/`, `state/`, `state-auto/` не читати як джерело для
  документації й не видаляти.

## Етап 1. Структура правил

- [x] Залишити `AGENTS.md` короткою картою і винести повний норматив у
  `docs/AI_AGENT_RULES_REFERENCE.md` зі стабільними номерами `§N.M`.
- [x] Зробити чотири rule-файли byte-identical.
- [x] Додати task-to-doc routing для скриптів, API, OpenCode агентів, безпеки,
  планів і фактичної документації flow.
- [x] Зберегти всі чинні project-specific заборони без послаблення.

## Етап 2. Security contract публічного репозиторію

- [x] Додати `docs/SECURITY.md`: `.env` як єдине локальне сховище чутливих
  значень, `.env.example` лише з порожніми/безпечними прикладами, порядок дій при
  витоку й межа між credential hashes та technical hashes.
- [x] Посилити механічний scan tracked і staged content: `.env*`, приватні ключі,
  токени, credential hashes, персональні домашні шляхи та підозрілі dumps.
- [x] Заборонити передачу `.env`, API responses, state, logs і dumps будь-яким
  remote/free агентам; translation children отримують лише мінімальний payload.
- [x] Прибрати з документації рекомендацію обходити secret hook через
  `--no-verify`.

## Етап 3. Єдиний виконуваний gate

- [x] Створити `scripts/agent-check.sh` з реальними профілями
  `preflight|docs|shell|agents|runtime|api|full` без порожніх заглушок.
- [x] Перевіряти структуру планів, docs links, rule mirrors, hooks, `.gitignore`,
  `.env.example`, secret patterns, shell syntax і наявні project validators.
- [x] Залишити сумісний `check-rules.sh` як вузький entrypoint або wrapper без
  дублювання реалізації.
- [x] Додати негативні fixture-перевірки, що secret gate справді падає, не
  створюючи tracked чи робочих секретів.

## Етап 4. Документація і навігація

- [x] Переписати `README.md` українською та явно відокремити quick start,
  security, OpenCode flow, autonomous flow, API boundary і локальні артефакти.
- [x] Додати `docs/README.md`, `docs/PROJECT_OVERVIEW.md` і
  `docs/AI_AGENT_RULES_REFERENCE.md` як точки входу до фактичного стану.
- [x] Узгодити `API_WRITE_CONTRACT.md`, `UI_SUBAGENT_WORKFLOW.md` і
  `docs/FLOW_STATE.md` з актуальними правилами без вигаданих змін поведінки.
- [x] Документувати зв'язок із серверним Agent API без приватних шляхів,
  контейнерів, ключів або внутрішньої інфраструктури власника.

## Етап 5. Доказ і закриття

- [x] Запустити найвужчі docs/security/shell/agent перевірки.
- [x] Запустити повний безпечний gate; runtime/API позначити точно, якщо локальні
  залежності недоступні.
- [x] Переглянути diff і tracked files на секрети, персональні дані, state,
  output, tmp та scope drift.
- [x] Оновити цей план і обидва реєстри доказами, перемістити план у `done/` лише
  після виконання Definition of Done.

## Definition of Done

- Root rules byte-identical, короткі та маршрутизують у повний норматив.
- `.env` і будь-які credential secrets/hashes не можуть пройти docs gate або
  pre-commit hook; `.env.example` не містить реальних значень.
- Технічні identity/checksum hashes не заборонені й контракт API не зламаний.
- Публічний README та docs index пояснюють призначення, структуру, два flows,
  локальні дані й серверну межу українською.
- Усі профілі gate реальні, недеструктивні та повертають ненульовий код при
  порушенні інваріанта.
- Повний релевантний набір перевірок завершився кодом 0 або кожен недоступний
  зовнішній gate має точну причину й ризик.

## Докази закриття

- `bash scripts/agent-check.sh docs` · exit 0; mirrors, plans, ENV contract,
  secret fixtures й technical `identity_hash` перевірені.
- `bash scripts/agent-check.sh shell` · exit 0; `bash -n` 47 файлів,
  ShellCheck і `php -l` 14 файлів пройдені.
- `bash scripts/agent-check.sh agents` · exit 0; active model узгоджена між
  OpenCode config і frontmatter.
- `bash scripts/agent-check.sh full` · exit 0.
- `bash scripts/agent-check.sh runtime` · exit 0; endpoint, GGUF, no-thinking,
  constrained decoding і OpenCode provider declaration пройдені.
- `bash scripts/agent-check.sh api` · не пройшов: local `/me` повернув HTTP 401.
  Записів не було. Ризик: актуальна local API authentication/connectivity не
  підтверджена до надання чинного локального key у приватному `.env`.
