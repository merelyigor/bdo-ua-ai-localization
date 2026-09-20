# bdo-ua-ai-localization

<img src="docs/assets/banner.png" alt="BDO UA AI Localization · браузерний інтерфейс і конвеєр локалізації" width="935" height="1683">

Набір інструментів для української локалізації **Black Desert Online** у
проєкті [BDO UA Translate](https://bdo-ua.com.ua). Це клієнт Agent API, а не
сервер: база даних, адмінка й серверна логіка живуть в окремому проєкті.

Основний шлях для власника — `./bdo`: набір відкриває браузерну сторінку з
прогоном як чатом, станами кроків, чергою до людини та історією сесій. Без
браузера доступний той самий flow у `./bdo tui`. Порядок кроків тримає PHP-код,
мовну роботу виконують локальні моделі, а перед записом працюють механічні
перевірки identity, розмітки, placeholders, довжини й мовних дефектів.

## Швидкий старт

Потрібні PHP CLI 8.3+, Bash для розробницької оснастки, `jq`, `curl`,
ShellCheck, Agent API key і локальний runtime моделей. Модель, endpoint, схеми й
температури задає [`config/roles.json`](config/roles.json); не дублюйте ці
параметри в README.

```bash
git clone https://github.com/merelyigor/bdo-ua-ai-localization.git
cd bdo-ua-ai-localization
git config core.hooksPath .githooks
cp .env.example .env
./bdo
```

У `.env` власник задає `BDO_ENV=PROD|DEV` і ключ відповідного середовища.
`./bdo` бере вільний порт і друкує адресу сторінки. У Windows є `bdo.bat`, на
macOS — `BDO.app`, на Linux — `./bdo desktop --install`.

## Як працює конвеєр

Одна пачка проходить через спільний рушій і драйвер:

```text
mode start → run drive → loop → model client → deterministic checks → write route
```

Ролі отримують payload файлом і відповідають за strict JSON-схемою. Драйвер
сам переходить до наступного кроку, повторює безпечні відмови, продовжує
наступну пачку або зупиняється з машиночитаною причиною. Модель не керує
workflow і не отримує доступу до shell чи API.

Поточний порядок і стани: [`WORKFLOW.md`](WORKFLOW.md) та
[`docs/FLOW_STATE.md`](docs/FLOW_STATE.md). Межі системи й шари:
[`docs/PROJECT_OVERVIEW.md`](docs/PROJECT_OVERVIEW.md).

## Де шукати факти

| Потреба | Канонічне джерело |
|---|---|
| Публічний quick start | цей файл |
| Повний користувацький flow | [`WORKFLOW.md`](WORKFLOW.md) |
| Архітектура й межі | [`docs/PROJECT_OVERVIEW.md`](docs/PROJECT_OVERVIEW.md) |
| Поточні стани й переходи | [`docs/FLOW_STATE.md`](docs/FLOW_STATE.md) |
| Agent API | [`docs/API.md`](docs/API.md) |
| Контракт запису | [`API_WRITE_CONTRACT.md`](API_WRITE_CONTRACT.md) |
| Безпека й класи даних | [`docs/SECURITY.md`](docs/SECURITY.md) |
| Команди | [`docs/COMMANDS.md`](docs/COMMANDS.md), генерується з `cli/command-registry.json` |
| Перевірки | [`docs/CHECKLIST.md`](docs/CHECKLIST.md) |
| Правила агента | [`AGENTS.md`](AGENTS.md), [`docs/AI_AGENT_RULES_REFERENCE.md`](docs/AI_AGENT_RULES_REFERENCE.md) |
| Поточна незавершена робота | [`docs/plans/README.md`](docs/plans/README.md), [`docs/plans/BACKLOG.md`](docs/plans/BACKLOG.md) |
| Відкриті дефекти й прийняті ризики | [`docs/plans/DEFECTS.md`](docs/plans/DEFECTS.md) |

Повна навігація по документації — [`docs/README.md`](docs/README.md).

## Канали запису

- `machine` — звичайний автоматичний шар;
- `manual` — ручний шар із серверними дозволами;
- `proposal` — черга модерації без автоматичного схвалення.

Локальні перевірки й API validate виконуються до запису. Проблемний рядок не
маскується під успішний результат: він переходить у визначений контрактом
маршрут або зупиняє крок із причиною.

## Перевірки для розробника

```bash
./bdo gate touched   # пропорційна перевірка змінених шляхів
./bdo gate docs      # правила, плани, посилання, публічна безпека
./bdo api            # read-only перевірка доступності Agent API
./bdo gate touched   # селективні перевірки змінених шляхів
```

`docs/COMMANDS.md` не редагують вручну. `state/`, `output/` і `.env` — локальні
дані; ключі та повні API-відповіді не додаються до репозиторію. Детальні правила
публічного репозиторію — [`docs/SECURITY.md`](docs/SECURITY.md).

## Повʼязані проєкти

| Проєкт | Роль |
|---|---|
| [bdo-ua.com.ua](https://bdo-ua.com.ua) | сайт, глосарій, модерація й Agent API |
| [bdo-ua-client](https://github.com/merelyigor/bdo-ua-client) | встановлення українізатора в гру |

Потреба змінити серверний API передається за
[`docs/API_CHANGE_HANDOFF.md`](docs/API_CHANGE_HANDOFF.md); цей репозиторій не
змінює зовнішній проєкт.

## Ліцензія

MIT — [`LICENSE`](LICENSE).
