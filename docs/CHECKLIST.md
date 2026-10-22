# Що перевіряти

Список екранів, контрольних `id` і доказу кроку. Канон правил — [`AGENTS.md`](../AGENTS.md),
протокол звірки — [`WEB.md`](WEB.md); цей файл перелічує, що саме дивитися на екрані.

## Перед зміною

1. `git status --short` · визначити незакомічені шляхи й не чіпати чужу роботу.
2. «Відкладене» в [`plans/BACKLOG.md`](../plans/BACKLOG.md) · перевірити, чи дефект уже зареєстрований.
3. Прочитати реалізацію та всі місця виклику.
4. Назвати клас дефекту й інші екрани, де він проявиться.

## Після зміни

1. `uv run bdo gate` → `GATE GREEN`, код 0.
2. Звірити зміну у справжньому браузері штатним браузером Codex за протоколом звірки `docs/WEB.md`;
   нову механічну перевірку показати на навмисно зламаному вході.
3. На екрані перевірити потрібний стан за `id` з таблиці нижче; записати
   очікуваний і фактичний текст у `Notes` відповідного кроку плану.
4. Перевірити console без `error`, network без неочікуваних статусів ≥ 400,
   зберегти 3–5 знімків і відкрити кожен для огляду.
5. Якщо змінились карта модулів, стани чи схема БД · оновити
   `docs/ARCHITECTURE.md`.
6. Якщо знайдено дефект, якого не виправлено в цій зміні · додати рядок до
   «Відкладене» в [`plans/BACKLOG.md`](../plans/BACKLOG.md) з кроком відтворення у браузері.
7. Переглянути diff: секрети, `.env`, `.bdo/`, `*.sh`, `test_*.py` і зміни
   поза планом не потрапили до коміту.

## Доказ кроку

Доказ кроку — артефакти, за яким інша сесія перевіряє виконання кроку. Повний
протокол — [`WEB.md`](WEB.md); тут його короткий склад.

У доказ входить:

- шляхи 3–5 знімків екрана (або самі знімки в чаті, якщо канал не дає записати файл);
- очікуваний і фактичний текст екрана після дії — у `Notes` відповідного кроку плану;
- консоль без записів рівня `error`;
- мережа без неочікуваних статусів ≥ 400.

Не є доказом: знімок без звірки очікуваного тексту, `curl`, DOM-звірка без
знімків, самозвіт коду, зелений `gate` замість браузерної звірки.

Коли звірки немає (недоступний і штатний канал, і Playwright, або екран
неможливо побачити): крок не переходить у `done` і не в `skipped`, причина
пишеться в `Notes` кроку, план не закривається. Для кроку, що змінює лише
документацію або плани, доказом є відповідний профіль `uv run bdo gate` із
кодом 0 плюс diff; це теж записують у `Notes` кроку.

## Екрани й контрольні `id`

Перевіряй відповідний рядок таблиці для кожної зміни екрана. Динамічні частини
`<name>`, `<role>`, `<code>` та `N` замінюються фактичним імʼям провайдера,
ролі, коду дефекту або номером рядка. Усі `id` у цій таблиці реально є в
шаблонах `src/bdo_translate/web/templates/`; екран без жодного `id` позначено
окремо, і для нього перевіряють текст, а не вигаданий `id`.

Частина `id` зникла разом зі зміною екранів: `run-batch-id`, `run-rows`,
`roles-table`, `role-<name>-think`, `role-<name>-present`, `role-<name>-smoke`,
`models_think`, `limits-panel` більше не існує ні в шаблонах, ні в таблиці.
Не шукайте їх у коді — замість них перевіряйте наведені тут нові.

Для `/run`, `/start`, `/review`, `/sessions`, `/models` і `/call` порівнюй
загальний вигляд із [`reference/ui-old/README.md`](../reference/ui-old/README.md)
та відповідними знімками: спільна шапка, індикатор оновлення, чипи моделі,
`temp`, `ctx`, `think`, підзаголовок і темні панелі. Відмінності мають бути
пояснені відповідним планом.

| Екран | Що перевірити | Контрольні `id` |
|---|---|---|
| `/status` · стан | середовище, хост, маскований стан ключа, версія й редагування журналу | `st-env`, `st-host`, `st-key`, `st-version`, `redact-verdict`, `redact-log` |
| `/api` · API | профіль, вибірка, контекст, памʼять, validate і resolve | `me-user`, `me-key`, `me-max-items`, `me-max-page`, `me-remaining`, `me-abilities`, `me-channels`, `rows-count`, `context-count`, `memory-count`, `validate-channel`, `resolve-result` або `resolve-error` |
| `/models` · моделі | доступність провайдерів, роль, її модель і think, результат smoke та ліміти | `providers-table`, `provider-<name>-reach`, `provider-<name>`, `models-catalog`, `models-roles-title`, `models-role-form-N`, `models-effort-N`, `models_choice_reset`, `model-action-feedback`, `models-role-feedback`, `limits-drawer`, `limits-drawer-body`, `limits-drawer-widget`, `limits-tab` |
| `/calls` · виклики | кількість і стан робочих та діагностичних викликів, посилання на деталі | `calls-count`, `calls-table` або `calls-empty`, `calls-show-diag`, `call-N-state`, `call-N-link` |
| `/call?id=<id>` · деталі виклику | модель, стан, запит, жива відповідь, JSON і replay | `call-id`, `call-model`, `call-state`, `request-user`, `call-content`, `call-thinking`, `call-parsed`, `replay-panel`, `replay-last`, `btn-call_replay` |
| `/quality` · якість | пʼять рядків, кожен навмисний дефект, skip-пояснення й payload без хешів | `qrows-table`, `q-row`, `q-text`, `q-break-row`, `q-break-skip`, `btn-quality-break-<code>`, `q-defect-N`, `q-clean`, `q-fixed`, `q-payload-hashes`, `q-payload`, `quality-morph`, `quality-morph-count` |
| `/start` · почати прогін | DEV, патч, режим, розмір, кількість пачок, dry-run і передбачуваний запис | `start-env`, `start-mode`, `start-patch`, `start-rows`, `start-batches`, `start-summary`, `start-preview`, `start-confirm`, `start-dry`, `start-scope`, `start-corpus`, `start-corpus-rows`, `start-corpus-status`, `btn-run_start`, `btn-run_start_dry` |
| `/run` · прогін | сесія й пачка, живі виклики, стани рядків і зрозуміла причина відмови | `run-session`, `statePhrase`, `run-role-cards`, `run-calls`, `live-<role>-thinking`, `live-<role>-content`, `live-<role>-request`, `live-<role>-think-icon`, `run-failure`, `run-states`, `run-outcome`, `run-verdict-panel`, `verdicts`, `run-empty`, `btn-run_pause`, `btn-run_resume`, `btn-run_stop` |
| `/sessions` · сесії роботи | статус сесії, пачки й причина завершення | `sessions-table`, `session-<id>`, `session-N-batch-N`, `sessions-empty`, `sessions-db-size` |
| `/queue` · карантин і запис | відкладені, карантин, модерація, записи та збіг ключа повтору | `queue-deferred`, `queue-quarantine`, `queue-moderation`, `queue-writes`, `write-key-check`, `write-N`, `btn-quarantine_clear` |
| `/stats` · статистика | ролі, час пачки, паритет та A/B replay | `stats-roles`, `stats-role-<role>`, `stats-session-table`, `stats-parity`, `stats-ab-panel`, `stats-ab`, `btn-stats_ab_think` |
| `/review` · черга до людини | загальна кількість, завантаження, список пропозицій, текст і рішення | `review-total`, `review-shown`, `review-loading`, `review-list`, `review-item-N`, `review-text-N`, `review-empty`, `review-search`, `review-bulk-approve`, `review-bulk-reject` |
| `/compare` · порівняти моделі | вибір пачки, моделі й ролі, кнопка порівняння, таблиця результатів | `compare-form`, `compare-batch`, `compare-selected-models`, `compare-selected-roles`, `compare-table`, `btn-compare_run` |
| `/setup` · підключення | без `id` · дивитися заголовок «Підключення», підказку про локальний `.env`, рядок середовища й адреси API та поля форми ключів і адрес із кнопками «зберегти» / «прибрати» | без `id` |
| `/history` · історія рядка | без `id` · дивитися заголовок «Історія рядка», короткий hash під ним, форму пошуку за `identity_hash`, таблицю рядків пачки та блоки версій шарів | без `id` |

Спільна шапка (`base.html`) на всіх екранах: `nav`, `nav-work`, `nav-diag`,
`nav-env`, `nav-live`, `nav-live-dot`, `nav-review-count`, `nav-version`.

## Після dry-run на DEV

1. `/run` · `run-session`, `run-calls`, `run-states`, `run-verdict-panel`: усі
   пачки переглянуті до кінця, а стани рядків і переходів відповідають
   завершенню.
2. `/calls` · `calls-count`, `calls-table`, `call-N-state`: кожен виклик має
   роль, стан і видиму причину відмови; за потреби відкрити `/call?id=<id>` та
   звірити `call-id`, `call-state`, `call-parsed`.
3. `/stats` · `stats-roles`, `stats-session-table`: час ролей і пачок пояснює
   хід прогону; підозрілу кількість повторів звірити з відповідним викликом.
4. `/queue` · `queue-writes`, `write-key-check`: для dry-run записів немає;
   перевірка ключів повтору узгоджується з `WriteRecord`.
5. `/sessions` · `sessions-table`, `session-N-batch-N`: підсумок і
   причини завершення сесії збігаються з `/run`.

Автотести не додаються й не запускаються (D-08). Gate перевіряє статику;
поведінкове приймання робиться у браузері штатним браузером Codex за протоколом `docs/WEB.md`.
