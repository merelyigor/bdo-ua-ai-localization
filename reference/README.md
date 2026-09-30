# reference/ · де брати знання з PHP-попередника

PHP-проєкт `bdo-ua-ai-localization` лежить локально в
`../bdo-ua-ai-localization` (далі `$OLD`). Агент-розробник
читає його ЛИШЕ в режимі read-only: відкривати файли можна, запускати там
команди, тести, `./bdo`, змінювати чи створювати файли · заборонено. Коду
PHP у цей репозиторій не копіюють; переносяться словники, правила, контракти
й дизайн-токени, переписані на Python. Файлами копіюються РІВНО два:
`web/app.css` і `web/assets/bdo-background.webp` (AGENTS.md п. 3а). HTML
екранів `$OLD/web/*.html` · лише зразок розмітки для читання, не копія.

| Що потрібно | Де в `$OLD` | Куди в новому проєкті |
|---|---|---|
| механічні перевірки: словник русизмів, гомогліфи, чужа писемність, токени, роздільники, злиття вироків | `lib/Quality/Russianisms.php`, `Homoglyphs.php`, `ForeignScript.php`, `Defects.php`, `HallucinatedTokens.php`, `VerdictSet.php`, `lib/Batch/Row.php` | `src/bdo_translate/quality/*` (P04) |
| стани й переходи пачки | `lib/Pipeline/StateMachine.php` | `pipeline/states.py` (P05), рішення D-19 |
| підміна `identity_hash` → `rN` у payload і схемі | `lib/Model/RowAlias.php` | `model/alias.py` (P04) |
| зациклення за повторами | `lib/Model/RepeatWatch.php` | `model/repeat_watch.py` (P03) |
| транспорти: тіло запиту, стрім, причини відмов | `lib/Model/Transport/Ollama.php`, `OpenAi.php`, `cli/model/client.php` | `model/ollama.py`, `model/openai_compat.py`, `model/caller.py` (P03) |
| тіло запису, retry/backoff API, коди помилок, розбір конверта | `lib/Api/WritePayload.php`, `lib/Http/Client.php`, `lib/Api/ErrorCodes.php`, `lib/Api/Response.php`, `lib/Api/TranslationWriter.php` | `api/*` (P02, P07) |
| побудова payload ролей, поля рядка API | `lib/Cli/Command/Prepare/*.php`, `lib/Batch/Row.php` | `batch/payload.py`, `batch/row.py` (P04) |
| дизайн-система: токени, теми, класи | `web/app.css`, екрани `web/*.html` | `web/static/app.css` (P01), шаблони екранів (P01–P09) |
| закриті дефекти як чеклист класів помилок | `docs/plans/DEFECTS.md` і git-історія | приклади зламаного вводу для екрана «Якість» (P04, P09) |
| журнал викликів для паритету (лише читання) | `state/model-calls.jsonl` | екран «Статистика», P08 |
| вигляд екранів попередника | знімки живого UI в [`ui-old/`](ui-old/README.md) (не в `$OLD`) | екрани власника, P09 |

Форми payload і схем зафіксовані тут · [`payload-shapes.md`](payload-shapes.md),
щоб не залежати від наявності `$OLD` під час розробки.
