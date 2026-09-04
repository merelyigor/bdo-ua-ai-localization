# Документація bdo-ua-ai-localization

Це навігація по фактичному стану публічного toolkit. Майбутня й завершена робота
винесена в окремий lifecycle планів.

Власник не запускає CLI вручну: він змінює лише локальний `.env` і працює через
меню `./bdo`. Команди в документації · довідка для розробника й діагностики, а
не щоденний workflow.

## Почати тут

| Потреба | Документ |
|---|---|
| Які взагалі є команди | [COMMANDS.md](COMMANDS.md) · генерується з реєстру; у терміналі `./bdo help` |
| Запуск на Windows | [WINDOWS_WSL2.md](WINDOWS_WSL2.md) · повний WSL2 setup і діагностика |
| Призначення, межі й структура | [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) |
| Публічна безпека, `.env`, класи даних | [SECURITY.md](SECURITY.md) |
| Що перевіряти після зміни й після прогону | [CHECKLIST.md](CHECKLIST.md) |
| Що ламалося й чим закрито | [plans/DEFECTS.md](plans/DEFECTS.md) |
| Повний норматив для агентів | [AI_AGENT_RULES_REFERENCE.md](AI_AGENT_RULES_REFERENCE.md) |
| Маршрутизація правил агентів | [AGENT_RULE_ROUTING.md](AGENT_RULE_ROUTING.md) |
| Як влаштований конвеєр і що заміряно | [FLOW_STATE.md](FLOW_STATE.md) |
| Як перекладати цим набором | [../WORKFLOW.md](../WORKFLOW.md) |
| Ендпоінти й параметри Agent API | [API.md](API.md) |
| Контракт запису через Agent API | [API_WRITE_CONTRACT.md](../API_WRITE_CONTRACT.md) |
| Потрібна зміна в API на серверному боці | [API_CHANGE_HANDOFF.md](API_CHANGE_HANDOFF.md) · формат передачі |
| Плани, реєстр і черга | [plans/README.md](plans/README.md), [plans/BACKLOG.md](plans/BACKLOG.md) |

## Прототипи інтерфейсу

Макети браузерного інтерфейсу · [prototypes/README.md](prototypes/README.md).
Це документація НАМІРУ на живих числах, а не робочий інструмент: доказом
працездатності лишається тест.

## Політика документації

- `docs/*.md` описують те, що працює зараз.
- `docs/plans/active/` і `docs/plans/backlog/` описують незавершену роботу.
- Архіву документації немає: історія попередньої архітектури (оркестрація
  OpenCode) і закриті плани видалені 2026-09-04 і лишились лише в zip у
  `legacy/`. Доказом закритої роботи є код, тест або рядок у `plans/DEFECTS.md`.
- Зміна flow оновлює `FLOW_STATE.md`; зміна security contract · `SECURITY.md`;
  зміна навігації · цей файл.
- Неперевірені зовнішні факти позначаються разом із причиною та ризиком.
