# Плани: реєстр і життєвий цикл

> **Уся черга робіт одним списком · [BACKLOG.md](BACKLOG.md).** Реєстр нижче є
> джерелом правди про статус самих планів.

`docs/*.md` описують поточний фактичний стан. `docs/plans/**` описують майбутню,
активну або завершену роботу. План не підміняє довідник, а закритий план не
переписується як новий roadmap.

## Статуси

| Тека | Статус | Значення |
|---|---|---|
| `active/` | у роботі | Реалізація почалася, але Definition of Done ще не виконаний. |
| `backlog/` | не починався | Узгоджений намір без реалізації. |
| `done/` | закрито | Усе виконано або залишок явно передано в інший план. |

## Обов'язковий заголовок

```markdown
# Назва плану

- **Статус:** active | backlog
- **Створено:** YYYY-MM-DD
- **Реєстр:** [docs/plans/README.md](../README.md)
```

У `done/` статус має вигляд `done (закрито YYYY-MM-DD)`, а назва файла ·
`YYYY-MM-DD_SLUG.md`.

## Правила ведення

1. Новий план і запис у цьому реєстрі створюються разом.
2. `backlog` переходить в `active` з першою зміною реалізації.
3. `active` переходить у `done`, лише коли кожен пункт підтверджений файлом,
   командою або тестом чи явно переданий в інший план.
4. Реєстр і `BACKLOG.md` оновлюються разом зі зміною статусу.
5. Формулювання «готово» без доказу не приймається.

## Реєстр

### У роботі (`active/`)

Активних планів немає.

### Не починалися (`backlog/`)

| План | Створено | Відомі зовнішні gates |
|---|---|---|
| [2026-08-22_TRANSLATION_QUALITY_IMPROVEMENTS.md](backlog/2026-08-22_TRANSLATION_QUALITY_IMPROVEMENTS.md) · що дати моделі (`unresolved`, `examples`) і що прибрати (суперечність про `[Title]`, розмір пачки, ціна terminology) | 2026-08-22 | Q2 потребує терміна `Title` -> `Титул` у глосарії через адмінку (`manage_glossary`); агентське API термінів не створює. |

### Закриті (`done/`)

| План | Закрито | Відомі зовнішні gates |
|---|---|---|
| [2026-08-22_WSL2_AND_MODEL_ROUTING.md](done/2026-08-22_WSL2_AND_MODEL_ROUTING.md) · один flow для WSL2 та provider-neutral профілі субагентів | 2026-08-22 | OpenCode smoke потрібен один раз для кожного нового зовнішнього provider/model. |
| [2026-08-22_UNATTENDED_OPENCODE_TRANSLATION_SYSTEM.md](done/2026-08-22_UNATTENDED_OPENCODE_TRANSLATION_SYSTEM.md) · українські режими OpenCode, child sessions, retry/resume, idempotent PROD write | 2026-08-22 | Live patch acceptance: 1/1 записано в `machine`, manifest `verified`; сім gates exit 0. |
| [2026-08-21_PIPELINE_ENGINE_AND_REPO_STRUCTURE.md](done/2026-08-21_PIPELINE_ENGINE_AND_REPO_STRUCTURE.md) · машина станів, `bdo`, масштабована структура `cli/**` | 2026-08-22 | Root `*.sh`: 0; shell gate перевірив 47 файлів і 10 категорій. |
| [2026-08-21_PUBLIC_REPOSITORY_RULES_AND_DOCUMENTATION.md](done/2026-08-21_PUBLIC_REPOSITORY_RULES_AND_DOCUMENTATION.md) · правила, публічна безпека, документація, планування й quality gate | 2026-08-21 | Local Agent API `/me` повернув HTTP 401; потрібен чинний local key у приватному `.env` для повторного read-only smoke. |
