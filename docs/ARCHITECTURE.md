# Архітектура (цільова)

Документ описує, ЯК влаштований проєкт після виконання планів P01–P11.
Кожна назва модуля, функції, таблиці й екрана тут є контрактом для планів:
плани називають ті самі імена. Чому саме так · [`DECISIONS.md`](DECISIONS.md).

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
| `cli.py` | typer-застосунок `bdo` | `app`: запуск вебсторінки без аргументів (`--no-open` вимикає відкриття браузера), `version`, `env`, `gate`, `web serve/start/stop/status` | P01, P11 |
| `api/errors.py` | підказки за кодами помилок | `ERROR_HINTS`, `hint_for(code)` | P02 |
| `modes.py` | `config/modes.json` | `ModesConfig`, `ModeSpec`, `ChannelSpec`, `load_modes()` | P02 |
| `services.py` | спільні клієнти процесу | `Services` (`api`, `repo`, `modes`, `roles`, `transport`, `aclose`) | P01–P03 |
| `api/models.py` | pydantic-моделі відповідей | `Me`, `MeBatch`, `WriteChannel`, `RowsPage`, `MemoryEntry`, `MemoryVariant`, `ItemResult` | P02 |
| `api/client.py` | HTTP, конверт, повтори tenacity | `ApiClient` (`get`, `post`, `aclose`) | P02 |
| `api/endpoints.py` | типізовані виклики | `chunks`, `me`, `rows_page`, `rows_context`, `memory_find`, `active_patch_snapshot_id`, `validate` (P02), `glossary_resolve` (P06), `write` (P07), `patches`, `missing_total`, `proposals`, `proposal_approve`, `proposal_reject` (P09) | P02, P06, P07, P09 |
| `store/models.py` | таблиці SQLModel | `RunSession`, `Batch`, `BatchRow`, `Call`, `Verdict`, `Transition`, `WriteRecord`, `TermCache`, `RowAttempt`, `Deferred`, `Quarantine`, `ModelChoice` | P03, P05–P09 |
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
| `batch/payload.py` | payload ролей | `worker_payload`, `qa_payload`, `repair_payload`, `judge_payload`, `names_payload`, `terminology_payload` | P04, P06 |
| `quality/tokens.py` | `must_preserve`, `{BDO_NL}`, дужки | `token_violations`, `hallucinated_tokens`, `segment_violations` | P04 |
| `quality/glossary_case.py` | регістр назв глосарія | `glossary_case_hits`, `fix_glossary_case` | P04 |
| `quality/russianisms.py` | русизми, російські літери | `russianism_hits(text)` | P04 |
| `quality/homoglyphs.py` | латиниця в кириличному слові | `homoglyph_hits(text)` | P04 |
| `quality/foreign_script.py` | чужа писемність | `foreign_script_hits(source, text)` | P04 |
| `quality/limits.py` | межі довжини, тире | `limit_violations(row, text)` | P04 |
| `quality/defects.py` | зведення | `Defect`, `check_translation(row, text)`, `autofix(row, text)` | P04 |
| `quality/verdicts.py` | злиття вироків | `RowVerdict`, `merge_verdicts(mechanical, qa, judge)` | P04 |
| `pipeline/states.py` | стани й переходи | `BatchState`, `TRANSITIONS`, `assert_transition(a, b)` | P05 |
| `pipeline/events.py` | шина подій для SSE | `EventBus`, `Event` | P05 |
| `pipeline/machine.py` | перехід із записом | `transition(repo, bus, batch_id, to, reason)` | P05 |
| `pipeline/routing.py` | куди йде рядок | `Route`, `route_row(...)` | P05, P06 |
| `pipeline/steps.py` | кроки пачки | `step_fetch`, `step_memory`, `step_terminology`, `step_worker`, `step_checks`, `step_qa`, `step_validate` | P05–P07 |
| `pipeline/runner.py` | сесія, пачки, курсор, deferred і живі виклики | `RunGoal`, `Runner` (`start`, `pause`, `stop`, `current`), `LiveCalls` | P05, P09 |
| `pipeline/preflight.py` | перевірка наявності моделей до першої пачки | `check_models()` | P11 |
| `pipeline/heal.py`, `judge.py`, `names.py`, `commit.py` | лікування, суддя, назви, запис | `step_heal`, `step_judge`, `step_names`, `step_commit`, `idempotency_key`, `markup_repair` | P06, P07 |
| `pipeline/stats.py` | статистика | `role_stats`, `session_stats` | P08 |
| `web/screens/compare.py` | повторні виклики збереженої пачки з перевизначенням моделей | `compare_run` | P11 |
| `web/screens/sessions.py` | історія сесій і видалення локальної історії завершеної сесії | `session_delete` | P11 |
| `web/app.py` | FastAPI, guards, екрани, SSE й маршрут лімітів | `create_app(settings)`, `GET /limits.json` | P01+, P09 |
| `web/labels.py` | українські підписи відомих станів і кодів | `label`; Jinja-фільтр `human` зареєстровано в `web/app.py` | P09 |
| `web/registry.py` | типи реєстру | `Screen`, `Action`, `WebState` | P01 |
| `web/screens/*.py` | екран і його дії | `SCREEN`, `ACTIONS`; `screens/__init__.py` · `SCREENS`, `ACTIONS`, `NAV` | P01+ |
| `web/screens/review.py` | перегляд і рішення щодо пропозицій | `build`, `review_approve`, `review_reject` | P09 |
| `web/templates/`, `web/static/` | екрани й стилі | див. «Екрани» | P01+ |
| `pipeline/events.py`, `pipeline/runner.py` | потік подій прогону | SSE `/events`; `call_live` несе дельти thinking/content, `LiveCalls` зберігає їх для екрана виклику | P05, P09 |
| `web/screens/models.py` | вибір моделі й параметра think | `models_choose`, `models_choice_reset`, `models_think`; модель зберігає `ModelChoice` | P09 |
| `model/usage.py`, `web/app.py` | ліміти OpenCode Go | `read_usage`; маршрут `GET /limits.json` і кеш у памʼяті процесу | P09 |

## Екрани (D-34)

| Шлях | Шаблон | Що видно | План |
|---|---|---|---|
| `/status` | `status.html` | `BDO_ENV`, хост API, «ключ · задано», версія, перевірка редагування логів | P01 |
| `/api` | `api.html` | `GET /me` (роль, канали, ліміти, `batch.max_items`), вибірка за режимом, контекст, памʼять, помилка API з кодом і підказкою | P02 |
| `/models` | `models.html` | провайдери, досяжність, вибір моделі й `think`, ролі, smoke-перевірки та ліміти Go | P03, P09 |
| `/calls` | `calls.html` | останні 50 викликів: роль, модель, стан, помилка, мс, токени | P03 |
| `/call?id=<id>` | `call.html` | запит як бачила модель, роздуми, відповідь, розібраний JSON, кнопка «Повторити» | P03 |
| `/quality` | `quality.html` | перевірка введеного тексту, приклади зламаного вводу для девʼяти кодів, пошук рядків і payload worker | P04, P10 |
| `/start` | `start.html` | середовище, режим, патч і категорія, розмір та кількість пачок, вибір моделі, dry-run або запис із PROD-підтвердженням | P05, P07, P09 |
| `/run` | `run.html` | сесія й пачка, стрічка станів, картки живих викликів, причини відмов, рядки й їхні маршрути, пауза/стоп | P05, P06, P09 |
| `/sessions` | `sessions.html` | сесії й пачки, стан, причина | P05 |
| `/queue` | `queue.html` | deferred, quarantine, moderation, записи й перевірка збереженого ключа повтору | P07 |
| `/stats` | `stats.html` | час ролей і сесій, паритет, A/B replay із `think` | P08 |
| `/review` | `review.html` | пропозиції каталогу, локальний пошук, одиничне й пакетне approve/reject із причиною | P09 |
| `/compare` | `compare.html` | порівняння результатів повторного виклику ролей на збереженій пачці | P11 |

`/` перенаправляє на `/run`. `/call?id=<id>` · діагностика одного запису з
`calls`; він не входить до навігації.

Кожен екран має фіксовані `id` елементів, названі в плані: на них дивиться
ЗВІРКА. Навігація показує лише зареєстровані екрани (`web/screens/__init__.py`).

## Життя пачки

```
selected → memory_checked → terminology_done → worker_done → checks_done → qa_done
        → healing (цикл ≤ heal_max_attempts) → judge_done → names_done → validated
        → dry_run_done                      (dry-run: кінець пачки)
        → committing → committed            (запис)
побічні: failed_terminal · paused
```

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
| `Batch` (`batches`) | `id` str PK · `session_id` str (index) · `seq` int · `state` str · `created_at` str · `updated_at` str · `reason` str? |
| `BatchRow` (`batch_rows`) | `batch_id` str PK · `identity_hash` str PK · `alias` str · `source_hash` str · `source_text` str · `row_json` str · `memory_text` str? · `candidate_text` str? · `final_text` str? · `route` str? · `route_reason` str? |
| `Call` (`calls`) | `id` str PK · `batch_id` str? (index) · `role` str · `provider` str · `model` str · `think` str · `started_at` str · `ms` int · `in_tokens` int? · `out_tokens` int? · `thinking_bytes` int · `state` str (`ok`,`failed`) · `error` str? · `attempt` int · `rows` int · `json_salvaged` bool · `answer_loop_detected` bool · `request_json` str · `content` str · `thinking` str · `parsed_json` str? · `replay_of` str? |
| `Verdict` (`verdicts`) | `id` int PK auto · `batch_id` str (index) · `identity_hash` str · `source` str (`mechanical`,`qa`,`judge`,`api_validate`,`api_write`) · `status` str · `severity` str? · `code` str? · `issue` str? · `fix` str? · `created_at` str |
| `Transition` (`transitions`) | `id` int PK auto · `batch_id` str (index) · `from_state` str · `to_state` str · `reason` str · `at` str |
| `WriteRecord` (`writes`) | `id` int PK auto · `batch_id` str · `identity_hash` str · `channel` str · `idempotency_key` str · `result` str · `response_json` str · `created_at` str |
| `TermCache` (`term_cache`) | `session_id` str PK · `canonical_source` str PK · `result_json` str · `created_at` str |
| `RowAttempt` (`row_attempts`) | `identity_hash` str PK · `attempts` int · `last_reason` str? · `updated_at` str |
| `Deferred` (`deferred`) | `identity_hash` str PK · `batch_id` str · `reason` str · `created_at` str |
| `Quarantine` (`quarantine`) | `id` int PK auto · `identity_hash` str · `batch_id` str · `reason` str · `payload_json` str · `created_at` str · `archived` bool |

`store/db.py`: `SCHEMA_VERSION = 1`; `open_db()` створює `.bdo/`, engine
`sqlite:///.bdo/bdo.sqlite`, вмикає `PRAGMA journal_mode=WAL`, викликає
`SQLModel.metadata.create_all`, застосовує `UPGRADES[v]` для кожної версії між
`PRAGMA user_version` і `SCHEMA_VERSION`, пише нову `user_version`.

## Контракти даних на межі моделі

Форми payload і відповідей · [`../reference/payload-shapes.md`](../reference/payload-shapes.md).
Відповідь worker/repair/names · `roles/schema/response.json`; QA ·
`roles/schema/qa.json`; суддя · `roles/schema/translation-judge.json`;
термінолог · `roles/schema/translation-terminology.json`; smoke ·
`roles/schema/translation-smoke.json`. У схемах поле `id` має `enum` рівно з
alias-ів цієї пачки; `RowAlias.alias_schema(schema)` підставляє їх.

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
