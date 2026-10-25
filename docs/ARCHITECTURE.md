# Архітектура

Документ описує, ЯК влаштований проєкт **зараз**. Кожна назва модуля,
функції, таблиці й екрана тут є контрактом для планів: плани називають ті
самі імена. Чому саме так · [`DECISIONS.md`](DECISIONS.md).

Кожне ім'я, таблиця, екран і механізм, згадані нижче, перевірено з
`src/bdo_translate/`; якщо документ розходиться з кодом, правильний код.

## Один процес, код керує, браузер · єдина поверхня

```
браузер ──GET екран / POST /action/<name>──► web/app.py ─► web/screens/*
                         ▲                                        │
                    GET /events (SSE) ◄── pipeline/events.py ◄────┤
                                                                  ▼
                              pipeline/runner.py ─► pipeline/machine.py ─► pipeline/steps.py
                                        │                                   ├─► api/endpoints.py ─► Agent API (httpx + tenacity)
                                        │                                   ├─► quality/defects.py
                                        │                                   └─► model/caller.py ─► model/ollama.py (SDK ollama)
                                        │                                                        └► model/openai_compat.py (SDK openai)
                                        └─► store/repo.py ─► .bdo/bdo.sqlite (sqlmodel)
```

- Модель отримує один payload (dict → JSON) і повертає JSON за схемою. Вона не
  бачить стану пачки, не має інструментів і не вирішує наступний крок.
- Сторінка викликає ті самі функції, що й конвеєр; логіки в `web/` немає.
- Прогін · `asyncio`-задача в процесі `bdo web serve` (D-36). Сховище ·
  синхронний `sqlmodel.Session` короткими транзакціями (дані малі).
- Локальні дані лише в `.bdo/` (D-05a).

## Межа й реалізація

Репозиторій містить лише Python. PHP-код попередника копіювати заборонено.
Канон [`AGENTS.md`](../AGENTS.md) дозволяє запозичення з попередника лише двох
файлів: `web/app.css` → `src/bdo_translate/web/static/app.css` і
`web/assets/bdo-background.webp` → `src/bdo_translate/web/static/bdo-background.webp`.
Окремим рішенням власника (D-46, D-48) дозволено також іконку
`src/bdo_translate/macapp/BDO.icns` (копія `BDO.app/Contents/Resources/BDO.icns`) і
`src/bdo_translate/web/static/favicon.ico`; саме цю іконку `bdo app build`
кладе у `BDO.app/`, зібраний бандл лежить у git. Решта коду попередника
переписана на Python; походження запозиченої логіки називає docstring, а
карта перенесень · [`../reference/README.md`](../reference/README.md). Заборону
інших мов і `*.sh` перевіряє `uv run bdo gate lint`.

Розробник і конвеєр — різні шари: правила цього документа стосуються розробки, а `roles/*.md` і `config/roles.json` — викликів моделі під час перекладу. Код задає порядок і guards; модель одержує один мінімальний JSON payload і повертає відповідь за схемою. Промпт кожної ролі самодостатній; runtime include і спільна композиція промптів не використовуються. JSON не містить значень, які може визначити код: хешів, порядку, повторів чи готового перекладу з памʼяті.

Модулі отримують `Repo`, `Settings` і транспорт параметрами. Логіка кроків не читає глобальний стан; час передається як параметр `now` або `clock`. Винятки предметної області походять від `BdoError`; перехоплення загального `Exception` дозволене лише на межі CLI/веб із логом і машиночитаною причиною. Нові залежності потребують дозволу власника й запису в `DECISIONS.md`. `type: ignore[код]` і `noqa: КОД` мають пояснювальний коментар.

## Цілісність даних конвеєра

- `identity_hash` надходить із API, не обчислюється й не виправляється клієнтом. Повноту й належність рядка пачці перевіряє сам код: `RowAlias.restore()` повертає помилки `unknown_id`, `duplicate_id` і `missing_id`; `api/endpoints.py::write` вимагає в кожному елементі непорожні `identity_hash`, `source_hash` і `text`; `validate` і `write` звіряють кількість і порядок результатів із запитом. Моделі хешів не бачать: `RowAlias` дає alias `id` (`r1`, …), а код повертає початкові хеші.
- `keep`, placeholders, PA markup і `{BDO_NL}` зберігаються байт у байт і в тій самій кількості: `quality/tokens.py` ловить зламані keep-токени, зміну кількості переносів і вигадані дужкові токени. Видимий текст перекладається, якщо його позначка не належить до `keep`; квадратні дужки лишаються. Кінцева `;` у джерелі вимагає тієї самої кількості роздільників і кінцевої `;` у перекладі (`quality/tokens.py::segment_violations`).
- Видимий український текст не має російських літер `ыэъё`, словникових русизмів, латинських гомогліфів у кириличних словах чи сторонньої писемності, якої немає у джерелі. Довге тире `—` механічна перевірка **не** ловить: `quality/limits.py` перевіряє лише довжину (`min_chars`, `max_chars`).
- `manual`, `machine`, `proposal` — окремі шари. Ручні ревізії, глосарій і рішення модерації не перезаписуються. Механічний дефект сильніший за вирок моделі; QA не може присвоїти `PASS` рядку з дефектом. Суддя визначає маршрут, а не переписує текст.
- Ізоляцію пачок забезпечує `pipeline/steps.py`: кожен рядок має `BatchRow` із `batch_id`, `identity_hash`, `alias` і `route`; наступна пачка не бере рядки попередніх (`skip_hashes` у `pipeline/runner.py`). Курсор API рухається після `committed` або `failed_terminal`; `dry_run` нічого не записує в API. Лічильник `row_attempts` відстежує спроби лікування за `identity_hash`: `pipeline/heal.py` робить щонайбільше `min(3, heal_max_attempts)` раундів і не бере рядок у черговий раунд, коли в нього вже 3 спроби; далі рядок іде за маршрутом `pipeline/routing.py` — у `proposal`, у `moderation` (за вердиктом судді) або в `deferred`.
- Ручний повтор відкладених — окрема сесія в активному середовищі й з тим самим режимом джерела, що й вибрана завершена сесія. `pipeline/steps.py::step_fetch` бере тільки причини з `_RETRY_DEFER_REASONS` (тимчасові відмови моделі та `missing_item`) у порядку часу відкладення. Для режиму пропозицій використовується актуальний текст пропозиції API. Якщо API більше не має рядка (404), його позначають `row_not_found`, тож він не пропонується для повтору знову. Успішний запис прибирає мітку `deferred`.
- Перемикач «перекласти все» на `/start` для активного патча без категорії встановлює `RunGoal.include_deferred`. Звичайний прогін спершу добирає придатні `deferred` того самого середовища й режиму, а залишок пачки заповнює новими рядками сторінками API; причини поза `_RETRY_DEFER_REASONS` не беруться. Ручний повтор з `retry_deferred` лишається окремим шляхом і не читає звичайні сторінки. Кількість пачок для «перекласти все» рахується за більшим із двох чисел: рядки без ШІ-шару за версією API та локальна черга повтору.
- `FetchDiagnostic` зберігає агрегати вибірки для звичайного читання рядків і ручного повтору в таблиці `fetch_diagnostics` за `batch_id`. Звичайне читання містить кількість сторінок і рядків API, лічильники відсіву, придатні рядки та ознаку сторінки без курсора; повтор рахує API-запити й результати пошуку за окремими `identity_hash`, а не сторінки переліку. Звичайний автоматичний відбір пропозицій цією діагностикою поки не охоплено.
- Перевірка механіки відбувається у браузері на пачці 5 рядків; якість моделі вимірюється на робочому розмірі пачки, типово 50. Джерело числа — `RunGoal.rows_per_batch`.

## Ролі й моделі

Активну модель ролей власник обирає на `/models`; `config/roles.json` задає схему, температуру й стартове значення `think` для ролі. Екран зберігає бажання та рівень роздумів, але фактичну підтримку визначають можливості моделі. Джерело фактичних викликів — таблиця `calls` та екрани «Виклики» й «Виклик».

Промпти написані наказовими реченнями з нумерованими правилами, точною формою відповіді й явними умовами зупинки. Поле у промпті називається `id`, не `identity_hash`; `uv run bdo gate lint` перевіряє цю заборону в `roles/*.md`. Рамка — офіційна українська локалізація Black Desert Online: знання гри пояснює сенс, а відповідник дають лише glossary/terms/examples; російську локалізацію не переносити.

Нову модель кваліфікують smoke-кнопкою «Моделі» (реальний `translation-smoke` за схемою) і серією повторів з екрана виклику; одного прикладу недостатньо. Зміну промпту спершу перевіряють повтором на збережених викликах і порівнюють відповіді. Ціль — не лишати людині доробку; кількість викликів сама по собі не є підставою пропускати лікування в межах `heal_max_attempts`.

## Карта модулів `src/bdo_translate/`

| Модуль | Відповідальність | Публічні імена | План |
|---|---|---|---|
| `__init__.py` | версія | `__version__` | P01 |
| `errors.py` | ієрархія помилок | `BdoError`, `ConfigError`, `ApiError`, `TransportError`, `StateError` | P01 |
| `clock.py` | єдине джерело часу | `now()`, `iso(moment)`, `new_id(moment)` | P01 |
| `settings.py` | `.env` через pydantic-settings | `Settings`, `ApiTarget`, `load_settings()` | P01 |
| `logging_setup.py` | JSON-логи, редагування секретів | `configure_logging()`, `redact()`, `RedactSecrets` | P01 |
| `gate.py` | статичний gate | `run_gate(profile, echo)`, `PROFILES` | P01 |
| `webctl.py` | старт/стоп сторінки для звірки | `start()`, `stop()`, `status()` | P01 |
| `cli.py` | typer-застосунок `bdo` | `app`: запуск вебсторінки без аргументів (`--no-open` вимикає відкриття браузера), `version`, `env`, `gate`, `hook` (`pre-commit`/`commit-msg`/`pre-push`), `web serve/start/stop/status/restart`, `app start/open/restart/build/alive/stop` | P01, P11 |
| `hooks.py` | логіка git-хуків | `pre_commit()`, `commit_msg(path)`, `pre_push(lines)`; перевіряють секрети, формат повідомлення, версію та приватність | P01, P11 |
| `api/errors.py` | підказки за кодами помилок | `ERROR_HINTS`, `hint_for(code)` | P02 |
| `modes.py` | `config/modes.json` | `ModesConfig`, `ModeSpec`, `ChannelSpec`, `load_modes()` | P02 |
| `services.py` | спільні клієнти процесу | `Services` (`api`, `repo`, `modes`, `roles`, `transport`, `aclose`) | P01–P03 |
| `api/models.py` | pydantic-моделі відповідей | `Me`, `MeBatch`, `WriteChannel`, `RowsPage`, `MemoryEntry`, `MemoryVariant`, `ItemResult` | P02 |
| `api/client.py` | HTTP, конверт, повтори tenacity | `ApiClient` (`get`, `post`, `aclose`) | P02 |
| `api/endpoints.py` | типізовані виклики | `chunks`, `me`, `rows_page`, `row_by_hash`, `row_history`, `rows_context`, `memory_find`, `active_patch_snapshot_id`, `validate` (P02), `glossary_resolve` (P06), `write` (P07), `patches`, `facets`, `machine_generations`, `missing_total`, `proposals`, `proposals_of_row`, `proposal_approve`, `proposal_reject` (P09) | P02, P06, P07, P09 |
| `store/models.py` | таблиці SQLModel | `RunSession`, `RunCheckpoint`, `ModelChoice`, `ModelLock`, `RoleThink`, `ModelCapability`, `Batch`, `BatchRow`, `FetchDiagnostic`, `Call`, `Verdict`, `Transition`, `WriteRecord`, `TermCache`, `RowAttempt`, `Deferred`, `Quarantine`, `QueueReason` | P03, P05–P09, P65 |
| `store/db.py` | engine, створення, `user_version` | `open_db(settings)`, `SCHEMA_VERSION`, `UPGRADES` | P03 |
| `store/repo.py` | запити для кроків і екранів | `Repo` | P03, P05–P08 |
| `model/roles.py` | `config/roles.json`, промпти, схеми | `RolesConfig`, `ProviderSpec` (`reasoning_off`, `models_filter`), `RoleSpec`, `load_roles()` | P03, P11 |
| `model/transport.py` | контракт транспорту | `ModelRequest`, `ModelReply`, `FailureReason`, `ModelCallError`, `Transport` (Protocol) | P03 |
| `model/repeat_watch.py` | зациклення за повторами | `RepeatWatch` | P03 |
| `model/ollama.py` | SDK `ollama` | `OllamaTransport` | P03 |
| `model/openai_compat.py` | SDK `openai` | `OpenAiTransport` | P03 |
| `model/factory.py` | провайдер → транспорт | `build_transport(provider, settings, roles)` | P03 |
| `model/caller.py` | виклик ролі + рядок `calls` + replay | `call_role()`, `replay_call()`, `Override`, `CallOutcome` | P03 |
| `model/alias.py` | `identity_hash` ↔ `rN` | `RowAlias` | P04 |
| `batch/row.py` | обгортка рядка API | `Row` | P04 |
| `batch/payload.py` | payload ролей | `worker_payload`, `qa_payload`, `terminology_payload`, `encode_newlines`, `decode_newlines`, `NEWLINE_MARKER` | P04, P06 |
| `quality/tokens.py` | `must_preserve`, `{BDO_NL}`, дужки | `token_violations`, `hallucinated_tokens`, `segment_violations` | P04 |
| `quality/glossary_case.py` | регістр назв глосарія | `glossary_case_hits`, `fix_glossary_case` | P04 |
| `quality/russianisms.py` | русизми, російські літери | `russianism_hits(text)` | P04 |
| `quality/homoglyphs.py` | латиниця в кириличному слові | `homoglyph_hits(text)` | P04 |
| `quality/foreign_script.py` | чужа писемність | `foreign_script_hits(source, text)` | P04 |
| `quality/limits.py` | межі довжини | `limit_violations(row, text)` | P04 |
| `quality/morph.py` | леми української морфології | `lemmas(text)`, `term_used(text, expected)` | P04 |
| `quality/defects.py` | зведення | `Defect`, `check_translation(row, text)`, `autofix(row, text)` | P04 |
| `quality/verdicts.py` | злиття вироків | `RowVerdict`, `merge_verdicts(mechanical, qa, judge)` | P04 |
| `pipeline/states.py` | стани й переходи | `BatchState`, `TRANSITIONS`, `assert_transition(a, b)` | P05 |
| `pipeline/events.py` | шина подій для SSE | `EventBus`, `Event` | P05 |
| `pipeline/machine.py` | перехід із записом | `transition(repo, bus, batch_id, to, reason)` | P05 |
| `pipeline/routing.py` | куди йде рядок | `route_row(...)` | P05, P06 |
| `pipeline/steps.py` | кроки пачки | `step_fetch`, `step_memory`, `step_terminology`, `step_worker`, `step_checks`, `step_qa`, `step_validate` | P05–P07 |
| `pipeline/runner.py` | сесія, пачки, курсор, deferred і живі виклики | `RunGoal`, `Runner` (`start`, `pause`, `stop`, `current`), `LiveCalls` | P05, P09 |
| `pipeline/preflight.py` | перевірка наявності моделей до першої пачки | `check_models()` | P11 |
| `pipeline/heal.py` | цикл лікування роль `translation-repair` | `step_heal`, `fix_rejections` | P06 |
| `pipeline/judge.py` | маршрут роль `translation-judge` | `step_judge`, `is_disputed` | P06 |
| `pipeline/names.py` | адресні заміни роль `translation-names` | `step_names`, `glossary_used` | P06 |
| `pipeline/commit.py` | запис у шар | `step_commit`, `idempotency_key`, `markup_repair` | P07 |
| `pipeline/stats.py` | статистика | `role_stats`, `session_stats` | P08 |
| `web/screens/compare.py` | повторні виклики збереженої пачки з перевизначенням моделей | `compare_run` | P11 |
| `web/screens/sessions.py` | історія сесій і видалення локальної історії завершеної сесії | `session_delete` | P11 |
| `web/app.py` | FastAPI, guards, екрани, SSE й маршрут лімітів | `create_app(settings)`, `GET /limits.json` | P01+, P09 |
| `web/labels.py` | українські підписи відомих станів і кодів | `label`; Jinja-фільтр `human` зареєстровано в `web/app.py` | P09 |
| `web/registry.py` | типи реєстру | `Screen`, `Action`, `WebState` | P01 |
| `web/screens/*.py` | екран і його дії | `SCREEN`, `ACTIONS`; `screens/__init__.py` · `SCREENS`, `ACTIONS`, `NAV`, `NAV_WORK`, `NAV_DIAG` | P01+ |
| `web/screens/review.py` | перегляд і рішення щодо пропозицій | `build`, `review_approve`, `review_reject` | P09 |
| `web/templates/`, `web/static/` | екрани й стилі | див. «Екрани» | P01+ |
| `pipeline/events.py`, `pipeline/runner.py` | потік подій прогону | SSE `/events`; подія `Event` має `kind`, `session_id`, `batch_id`, `data`, `at`; `call_live` несе `role`, `channel` і `delta` каналів `request`/`thinking`/`content`, `LiveCalls` зберігає їх для екрана виклику | P05, P09 |
| `web/screens/models.py` | вибір моделі й параметра think | `models_choose`, `models_choice_reset`, `models_lock`, `models_unlock`, `models_check`, `models_think`; модель зберігає `ModelChoice`, замкнення — `ModelLock` | P09 |
| `model/usage.py`, `web/app.py` | ліміти OpenCode Go | `read_usage`, `clear_usage_cache`; маршрут `GET /limits.json` і кеш у памʼяті процесу | P09 |

## Екрани (D-34)

| Шлях | Шаблон | Що видно | План |
|---|---|---|---|
| `/status` | `status.html` | `BDO_ENV`, хост API, «ключ · задано», версія, перевірка редагування логів | P01 |
| `/api` | `api.html` | `GET /me` (роль, канали, ліміти, `batch.max_items`), вибірка за режимом, контекст, памʼять, помилка API з кодом і підказкою | P02 |
| `/models` | `models.html` | провайдери, досяжність, вибір моделі й `think`, замкнення моделі, ролі, smoke-перевірки та ліміти Go | P03, P09 |
| `/calls` | `calls.html` | останні 50 викликів: роль, модель, стан, помилка, мс, токени | P03 |
| `/call?id=<id>` | `call.html` | запит як бачила модель, роздуми, відповідь, розібраний JSON, кнопка «Повторити» | P03 |
| `/quality` | `quality.html` | перевірка введеного тексту, приклади зламаного вводу для девʼяти кодів, пошук рядків і payload worker | P04, P10 |
| `/start` | `start.html` | середовище, режим, патч і категорія, розмір та кількість пачок, «перекласти все» з придатними відкладеними, вибір моделі, dry-run або запис із PROD-підтвердженням | P05, P07, P09, P65 |
| `/run` | `run.html` | сесія й пачка, стрічка станів, картки живих викликів, причини відмов, рядки й їхні маршрути, пауза/стоп, повтор відкладених і діагностика вибірки | P05, P06, P09, P65 |
| `/sessions` | `sessions.html` | сесії й пачки, стан, причина | P05 |
| `/queue` | `queue.html` | deferred, quarantine, moderation, записи й перевірка збереженого ключа повтору | P07 |
| `/stats` | `stats.html` | час ролей і сесій, паритет, A/B replay із `think` | P08 |
| `/review` | `review.html` | пропозиції каталогу, локальний пошук, одиничне й пакетне approve/reject із причиною | P09 |
| `/compare` | `compare.html` | порівняння результатів повторного виклику ролей на збереженій пачці | P11 |
| `/setup` | `setup.html` | середовище й адреси API, ключі BDO API (PROD/DEV) та локальних моделей (Ollama, oMLX, llama-swap); значення секретів на сторінку не потрапляють | P27 |
| `/history` | `history.html` | історія версій шарів одного рядка («ШІ-шар» і «ручний шар») з пословним diff; за `hash` — один рядок, за `batch` — список рядків пачки | P52 |

`/` перенаправляє на `/setup`, якщо ключ активного середовища не задано, і на
`/run` — якщо задано. `/call?id=<id>` · діагностика одного запиту з `calls`;
він не входить до навігації. `/history` · історія рядка; також поза навігацією.

Кожен екран має фіксовані `id` елементів: на них дивиться звірка. Навігація
показує лише зареєстровані екрани (`web/screens/__init__.py`), розділені на
`NAV_WORK` (робочі) і `NAV_DIAG` (діагностичні). Протокол звірки ·
[`WEB.md`](WEB.md).

## Життя пачки

```
selected → memory_checked → terminology_done → worker_done → checks_done → qa_done
        → healing (цикл ≤ heal_max_attempts) → judge_done → names_done → validated
        → dry_run_done                      (dry-run: кінець пачки)
        → committing → committed            (запис)
побічні: failed_terminal · paused
```

Граф переходів задає `pipeline/states.py::TRANSITIONS`. Основний шлях —
пряма лінія; дозволені відхилення такі:

- `memory_checked → worker_done` без термінології — коли в пачці немає термінів
  без відповідника (`step_terminology` не викликає модель і пише причину
  «немає термінів без відповідника»).
- `qa_done → validated` без лікування й судді — коли `step_validate` одразу
  завершує пачку; зворотно `qa_done → judge_done → validated` без `names_done`
  — коли рядків для підстановки назв немає.
- `failed_terminal` — з будь-якого нетермінального стану.
- `paused` — з будь-якого стану, крім термінальних; після паузи можна
  повернутися лише до стану, з якого пішли (`pipeline/machine.py`).

Кожен крок: читає вхід із SQLite → виконує роботу (API, модель або механіка) →
пише результат у SQLite → викликає `transition()`, який пише рядок
`transitions` і шле подію в `EventBus`. Заборонений перехід · `StateError`.

## Таблиці SQLite (`store/models.py`, sqlmodel)

Час · ISO-8601 UTC рядком із суфіксом `Z` (`clock.iso`). Ідентифікатори сесії,
пачки й виклику · `clock.new_id` (`YYYYMMDD_HHMMSS_<12 hex>`; 6 hex давали колізію `UNIQUE calls.id`). JSON-поля ·
`str` із `json.dumps(..., ensure_ascii=False)`.

| Клас (`__tablename__`) | Поля (тип; `PK` · первинний ключ) |
|---|---|
| `RunSession` (`sessions`) | `id` str PK · `started_at` str · `finished_at` str? · `env` str · `mode` str · `rows_per_batch` int · `batches_planned` int · `dry_run` bool · `status` str (`running`,`paused`,`stopped`,`finished`,`failed`,`interrupted`) · `stop_reason` str? · `goal_json` str |
| `RunCheckpoint` (`run_checkpoints`) | `session_id` str PK · `batch_id` str · `seq` int · `next_step` int · `cursor_json` str · `ctx_json` str? |
| `ModelChoice` (`model_choices`) | `id` int PK auto · `provider` str? · `model` str? · `think` bool? · `updated_at` str |
| `ModelLock` (`model_locks`) | `provider` str PK · `model` str PK · `locked_at` str |
| `RoleThink` (`role_think`) | `role` str PK · `think` bool · `effort` str? |
| `ModelCapability` (`model_capabilities`) | `provider` str PK · `model` str PK · `think_mode` str · `efforts` str? · `source` str · `checked_at` str |
| `Batch` (`batches`) | `id` str PK · `session_id` str (index) · `seq` int · `state` str · `created_at` str · `updated_at` str · `reason` str? |
| `BatchRow` (`batch_rows`) | `batch_id` str PK · `identity_hash` str PK · `alias` str · `source_hash` str · `source_text` str · `row_json` str · `memory_text` str? · `candidate_text` str? · `final_text` str? · `route` str? · `route_reason` str? |
| `FetchDiagnostic` (`fetch_diagnostics`) | `batch_id` str PK · `pages_received` int · `api_rows_received` int · `skipped_duplicate` int · `skipped_deferred` int · `skipped_prior_batch` int · `non_translatable` int · `empty_source` int · `selected_rows` int · `usable_rows` int · `has_more_without_cursor` bool · `status` str · `reason` str? · `updated_at` str |
| `Call` (`calls`) | `id` str PK · `batch_id` str? (index) · `role` str · `provider` str · `model` str · `think` str · `started_at` str · `ms` int · `in_tokens` int? · `out_tokens` int? · `thinking_bytes` int · `state` str (`ok`,`failed`) · `error` str? · `attempt` int · `rows` int · `json_salvaged` bool · `answer_loop_detected` bool · `request_json` str · `content` str · `thinking` str · `parsed_json` str? · `replay_of` str? |
| `Verdict` (`verdicts`) | `id` int PK auto · `batch_id` str (index) · `identity_hash` str · `source` str (`mechanical`,`qa`,`judge`,`api_validate`,`api_write`) · `status` str · `severity` str? · `code` str? · `issue` str? · `fix` str? · `created_at` str |
| `Transition` (`transitions`) | `id` int PK auto · `batch_id` str (index) · `from_state` str · `to_state` str · `reason` str · `at` str |
| `WriteRecord` (`writes`) | `id` int PK auto · `batch_id` str · `identity_hash` str · `channel` str · `idempotency_key` str · `result` str · `response_json` str · `created_at` str |
| `TermCache` (`term_cache`) | `session_id` str PK · `canonical_source` str PK · `result_json` str · `created_at` str |
| `RowAttempt` (`row_attempts`) | `identity_hash` str PK · `attempts` int · `last_reason` str? · `updated_at` str |
| `Deferred` (`deferred`) | `identity_hash` str PK · `batch_id` str · `reason` str · `created_at` str |
| `Quarantine` (`quarantine`) | `id` int PK auto · `identity_hash` str · `batch_id` str · `reason` str · `payload_json` str · `created_at` str · `archived` bool |
| `QueueReason` (`queue_reasons`) | `env` str PK · `identity_hash` str PK · `reason` str · `detail` str? · `mode` str · `session_id` str · `batch_id` str · `created_at` str |

`store/db.py`: `SCHEMA_VERSION = 3`; `open_db()` створює `.bdo/`, engine
`sqlite:///.bdo/bdo.sqlite`, вмикає `PRAGMA journal_mode=WAL` і
`PRAGMA busy_timeout=5000`, викликає `SQLModel.metadata.create_all`,
застосовує `UPGRADES[v]` для кожної версії між `PRAGMA user_version` і
`SCHEMA_VERSION`, пише нову `user_version`. Версія схеми новіша за
`SCHEMA_VERSION` · `RuntimeError`.

Міграції в `UPGRADES`:

| Версія | Що додає |
|---|---|
| 2 | `ALTER TABLE model_capabilities ADD COLUMN efforts TEXT` |
| 3 | `ALTER TABLE run_checkpoints ADD COLUMN ctx_json TEXT` |

Обидві перевіряють `PRAGMA table_info(...)` перед `ALTER` і не повторюють
додавання колонки, якщо вона вже є.

## Контракти даних на межі моделі

Форми payload і відповідей · [`../reference/payload-shapes.md`](../reference/payload-shapes.md).
Відповідь worker/repair/names · `roles/schema/response.json`; QA ·
`roles/schema/qa.json`; суддя · `roles/schema/translation-judge.json`;
термінолог · `roles/schema/translation-terminology.json`; smoke ·
`roles/schema/translation-smoke.json`.

Перейменування на alias відбувається **під час виконання**, а не в самій
схемі: `RowAlias.alias_schema(schema)` копіює схему, перейменовує
`identity_hash` на `id` і підставляє `enum` рівно з alias-ів цієї пачки;
`RowAlias.alias_payload(items)` так само перейменовує поле в елементах
payload, а `RowAlias.restore(items)` повертає відповіді до початкових хешів.
Схема судді `roles/schema/translation-judge.json` досі має поле
`identity_hash` — це зроблено під час виконання, а не в файлі.

## Відмови й повтори

- API (`tenacity`): повтор на HTTP 408, 429, 500, 502, 503, 504 і таймауті
  (спроба 30 с, зʼєднання 10 с); очікування `Retry-After` (≤ 30 с), інакше
  `2^(n-1)` ≤ 30 с; вікно повторів 570 с; `daily_row_quota_exceeded` не
  повторюється; далі `ApiError` з кодом `retry_exhausted`, `timeout` або
  `network_error` і прогін зупиняється.
- Модель: `rate_limited` і `upstream_unavailable` чекають `Retry-After` або
  `min(900, 60·2^min(n-1, 4))` с без ліміту спроб; зациклення дає ще рівно
  одну спробу; кожна спроба · рядок `calls`; зрив поведінки (`truncated`, `not_json`, `schema_mismatch`,
  `answer_loop`, `thinking_loop`, `empty_content`, `stream_incomplete`,
  `timeout`, `context_overflow`) закриває пачку `failed_terminal`, рядки йдуть у
  `deferred`, прогін бере наступну пачку; та сама роль зривається на другій
  пачці поспіль · прогін зупиняється «винна модель, а не рядки».
  `model_unreachable`, `model_error`, ключ, провайдер · зупинка одразу.

## Guards сторінки

`Host` лише `127.0.0.1|localhost|[::1]:<порт>`; `Sec-Fetch-Site` лише
`same-origin`, `none` або відсутній; POST лише з локальним `Origin` або без
нього. Інакше 403 з кодом `host_not_allowed`, `cross_site_forbidden`,
`origin_forbidden`.
