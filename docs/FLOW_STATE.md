# Стан флоу: як конвеєр працює зараз

Цей документ описує фактичний workflow. Плани живуть у
[`plans/`](plans/README.md), а архітектурні межі — у
[`PROJECT_OVERVIEW.md`](PROJECT_OVERVIEW.md). Старий OpenCode flow не є
альтернативним entrypoint; поточна реалізація — PHP у `lib/**` і `cli/bdo.php`.

У робочому флоу немає bash-скриптів: браузер, `./bdo`, `bdo.bat`, `BDO.app`,
драйвер і виклик моделі працюють через PHP. Bash лишається в `tests/**` та
`scripts/**` як розробницька оснастка.

## 1. Хто чим керує

| Шар | Канонічний код | Відповідальність |
|---|---|---|
| Інтерфейс власника | `web/*.html`, `lib/Web/*` | шість екранів: прогін, черга, сесії, старт, моделі, виклик |
| Спільний планувальник | `lib/Run/Actions.php` | вибір людини → перевірений масив аргументів |
| Драйвер | `lib/Cli/Command/Run/RunLoopCommand.php` | виконує конверт, переходить між кроками й пачками |
| Рушій | `lib/Cli/Command/Run/RunDriveCommand.php` | визначає наступну дію за state machine |
| Машина станів | `lib/Pipeline/StateMachine.php` | дозволені переходи |
| Клієнт моделі | `cli/model/client.php` | один виклик локальної ролі під strict-схемою |
| Реєстр ролей | `config/roles.json` | модель, схема й температура |

Порядок кроків тримає код. Модель отримує один payload файлом, не бачить стану
пачки та не вирішує, що робити далі.

## 2. Життя однієї пачки

```text
selected → awaiting_terminology → prepared → awaiting_worker
        → candidate_valid → deterministic_valid → awaiting_qa
        → qa_valid → healing → awaiting_judge → ready_to_commit
        → names_pass → ready_to_commit → committing → committed → verified
```

`names_pass` необовʼязковий: фінальна валідація може повернути
`glossary_violation` з точним `expected`; тоді рушій будує один короткий прохід
по назвах і застосовує адресу правки кодом. Кожен перехід дозволяє
`StateMachine::TRANSITIONS`.

Конверт рушія:

| `kind` | Дія драйвера |
|---|---|
| `child` | виклик `cli/model/client.php` із роллю, payload і шляхом відповіді |
| `continue` | наступний крок із причиною в журналі |
| `retry` | backoff; після ліміту без руху — `blocked` |
| `continue_run` | наступна пачка за перевіреними полями `goal` |
| `complete` / `goal_complete` | завершення прогону |
| `blocked` | зупинка з машиночитаною причиною |

Драйвер виконує лише перевірені поля конверта: довільний рядок `command` не
виконується. Безпечні повтори й наступна пачка визначаються кодом, не моделлю.

## 3. Важливі інваріанти

- Payload передається файлом і не переказується між кроками.
- Рядки, закриті памʼяттю без механічних дефектів, отримують `PASS` від коду;
  QA бачить текст, який дала модель у цій пачці.
- `state/row-attempts.jsonl` обмежує повтори за identity; досягнення стелі
  прибирає рядок із наступної вибірки й показує його людині.
- Модель не бачить повного `identity_hash`: на межі моделі використовуються
  короткі `r1…rN`, а код відновлює справжній identity.
- Валідація повторюється після repair і judge, без довіри до попереднього
  статусу.
- Кожна роль і кожна відмова мають власний step report і рядок у
  `state/model-calls.jsonl`; порожній output не є успіхом.
- Вебсервер лише читає `state/**` через `Bdo\Translate\Web\Snapshot`. Дії
  сторінки йдуть через POST → `cli/command-registry.json` → `Web\Runner`.
- Запис у PROD захищений кодом і підтвердженням; галочка у markup не є guard.
- Пачка належить сесії роботи. Квитанції, журнали й write evidence не
  видаляються тихо; очищення йде лише штатними командами набору.

## 4. Контракт виклику моделі

Протокол відділений від змісту. Вибір транспорту задають
`config/roles.json` та `roles.<роль>.provider`; типовий провайдер — `ollama`.

| Провайдер | Протокол | Схема | Роздуми |
|---|---|---|---|
| `ollama` | `POST /api/chat`, NDJSON | `format` | `think: true/false` явно |
| `openai`-compatible | `POST /chat/completions`, SSE | `response_format.json_schema`, `strict` | `reasoning_effort` |

Для обох транспортів схема передається, коли вона визначена; `think` передається
явно; всі перевірки робляться на зібраній відповіді; API keys беруться тільки з
оточення.

Кожна відмова зупиняє крок і має окрему причину:

`model_unreachable` · `model_error` · `truncated` · `context_overflow` ·
`empty_content` · `thinking_loop` · `not_json` · `stream_incomplete` ·
`provider_key_missing` · `unknown_provider` · `missing_model`.

`state/model-calls.jsonl` зберігає роль, модель, провайдер, час, токени й вирок.
Для thinking додатково пишуться counters і причина зупинки. Це джерело для
`./bdo audit`, а не самозвіт моделі.

## 5. Ролі та механічна якість

| Роль | Призначення |
|---|---|
| `translation-terminology` | відповідники невідомих термінів |
| `translation-worker` | переклад рядків пачки |
| `translation-qa` | PASS/REVIEW/REJECT для кожного рядка |
| `translation-repair` | виправлення рядків із вироком |
| `translation-names` | адресна підстановка канонічних назв |
| `translation-judge` | маршрут рядка, не його текст |
| `translation-glossary` | черга описів термінів |
| `translation-smoke` | перевірка каналу моделі |

Між моделлю й записом працюють `lib/Quality/**`: identity, placeholders, PA
markup, довжина, русизми, гомогліфи, чужа писемність і glossary constraints.
Механічний дефект сильніший за вирок моделі.

## 6. Поточні обмеження й невирішені питання

- Карантин після серверного виправлення сканера глосарія має окремі класи:
  відсутня назва, відмінкова форма зі зміненою основою та брудний запис
  глосарія. Їх не можна звести до одного показника якості; активні рішення —
  у [`plans/DEFECTS.md`](plans/DEFECTS.md) та [`plans/BACKLOG.md`](plans/BACKLOG.md).
- Економія нового flow і калібрування судді не підтверджені живими даними;
  відповідні виміри не вигадуються.
- Вибір моделі, її резидентність і параметри Ollama належать власнику. Набір
  доводить лише власний контракт виклику й журналює факт кожної спроби.

## 7. Канонічні перевірки

Після зміни перевірка пропорційна scope:

```bash
./bdo gate touched
./bdo api
```

Для документації — `./bdo gate docs`; для механізму перевірки —
`./bdo gate full`. Команди, параметри й актуальні маршрути не копіюються сюди:
їхні джерела — [`COMMANDS.md`](COMMANDS.md),
[`API.md`](API.md) і [`PROJECT_OVERVIEW.md`](PROJECT_OVERVIEW.md).
