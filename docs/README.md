# Документація bdo-ua-ai-localization

Це навігація по фактичному стану публічного toolkit. Майбутня й завершена робота
винесена в окремий lifecycle планів.

Власник не запускає project bash/CLI вручну: він змінює лише локальний `.env` і
передає роботу одному з primary-режимів OpenCode. Primary сам матеріалізує
runtime, веде flow та виконує перевірки; command snippets у документації є
внутрішнім agent flow або developer/diagnostics довідником.

## Почати тут

| Потреба | Документ |
|---|---|
| Які взагалі є команди | `./bdo` · дерево, `./bdo help flow` · порядок пачки |
| Запуск на Windows | [WINDOWS_WSL2.md](WINDOWS_WSL2.md) · повний WSL2 setup і діагностика |
| Призначення, межі й структура | [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) |
| Публічна безпека, `.env`, класи даних | [SECURITY.md](SECURITY.md) |
| Повний норматив для агентів | [AI_AGENT_RULES_REFERENCE.md](AI_AGENT_RULES_REFERENCE.md) |
| Маршрутизація правил агентів | [AGENT_RULE_ROUTING.md](AGENT_RULE_ROUTING.md) |
| Стан, виміри та дорогі знахідки flow | [FLOW_STATE.md](FLOW_STATE.md) |
| Супервізований OpenCode flow | [UI_SUBAGENT_WORKFLOW.md](../UI_SUBAGENT_WORKFLOW.md) |
| Ендпоінти й параметри Agent API | [API.md](API.md) |
| Контракт запису через Agent API | [API_WRITE_CONTRACT.md](../API_WRITE_CONTRACT.md) |
| Плани, реєстр і черга | [plans/README.md](plans/README.md), [plans/BACKLOG.md](plans/BACKLOG.md) |

## Політика документації

- `docs/*.md` описують те, що працює зараз.
- `docs/plans/active/` і `docs/plans/backlog/` описують незавершену роботу.
- `docs/plans/done/` є доказовим архівом і не використовується як актуальний roadmap.
- Зміна flow оновлює `FLOW_STATE.md`; зміна security contract · `SECURITY.md`;
  зміна навігації · цей файл.
- Неперевірені зовнішні факти позначаються разом із причиною та ризиком.
