# Що перевіряти

## Перед зміною

1. `git status --short` · визначити незакомічені шляхи й не чіпати чужу роботу.
2. `docs/plans/DEFECTS.md` · перевірити, чи дефект уже зареєстрований.
3. Прочитати реалізацію та всі місця виклику.
4. Назвати клас дефекту й інші екрани, де він проявиться.

## Після зміни

1. `uv run bdo gate` → `GATE GREEN`, код 0.
2. Звірити зміну у справжньому браузері через MCP Playwright за §9.5;
   нову механічну перевірку показати на навмисно зламаному вході.
3. На екрані перевірити потрібний стан за `id` з таблиці нижче; записати
   очікуваний і фактичний текст у Notes відповідного кроку плану.
4. Перевірити console без `error`, network без неочікуваних статусів ≥ 400,
   зберегти 3–5 знімків і відкрити кожен для огляду.
5. Якщо змінились карта модулів, стани чи схема БД · оновити
   `docs/ARCHITECTURE.md`.
6. Якщо знайдено дефект · додати його до `docs/plans/DEFECTS.md` з кроком
   відтворення у браузері.
7. Переглянути diff: секрети, `.env`, `.bdo/`, `*.sh`, `test_*.py` і зміни
   поза планом не потрапили до коміту.

## Екрани й контрольні `id`

Перевіряй відповідний рядок таблиці для кожної зміни екрана. Динамічні частини
`<name>`, `<id>` та `N` замінюються фактичним імʼям провайдера, запису або
номером рядка.

Для `/run`, `/start`, `/review`, `/sessions`, `/models` і `/call` порівнюй
загальний вигляд із [`reference/ui-old/README.md`](../reference/ui-old/README.md)
та відповідними знімками: спільна шапка, індикатор оновлення, чипи моделі,
`temp`, `ctx`, `think`, підзаголовок і темні панелі. Відмінності мають бути
пояснені відповідним планом.

| Екран | Що перевірити | Контрольні `id` |
|---|---|---|
| `/status` · стан | середовище, хост, маскований стан ключа, версія й редагування журналу | `st-env`, `st-host`, `st-key`, `st-version`, `redact-verdict`, `redact-log` |
| `/api` · API | профіль, вибірка, контекст, памʼять, validate і resolve | `me-user`, `me-key`, `me-max-items`, `me-max-page`, `me-remaining`, `me-abilities`, `me-channels`, `rows-count`, `context-count`, `memory-count`, `validate-channel`, `resolve-result` або `resolve-error` |
| `/models` · моделі | доступність провайдерів, роль, її модель і think, результат smoke та ліміти | `providers-table`, `provider-<name>-reach`, `roles-table`, `role-<name>-think`, `role-<name>-present`, `role-<name>-smoke`, `models_think`, `limits-panel` |
| `/calls` · виклики | кількість і стан робочих та діагностичних викликів, посилання на деталі | `calls-count`, `calls-table` або `calls-empty`, `call-N-state`, `call-N-link` |
| `/call?id=<id>` · деталі виклику | модель, стан, запит, жива відповідь, JSON і replay | `call-id`, `call-model`, `call-state`, `request-user`, `live-<role>-content`, `call-parsed`, `replay-panel`, `replay-last` |
| `/quality` · якість | пʼять рядків, кожен навмисний дефект, skip-пояснення й payload без хешів | `qrows-table`, `btn-quality-break-<code>`, `q-defect-N` або `q-break-skip`, `q-payload-hashes`, `q-payload` |
| `/start` · почати прогін | DEV, патч, режим, розмір, кількість пачок, dry-run і передбачуваний запис | `start-env`, `start-mode`, `start-patch`, `start-rows`, `start-batches`, `start-summary`, `start-preview`, `start-confirm`, `btn-run_start`, `btn-run_start_dry` |
| `/run` · прогін | сесія й пачка, живі виклики, стани рядків і зрозуміла причина відмови | `run-session`, `run-batch-id`, `run-role-cards`, `run-calls`, `live-<role>-thinking`, `live-<role>-content`, `run-failure`, `run-states`, `run-rows`, `run-empty` |
| `/sessions` · сесії роботи | статус сесії, пачки й причина завершення | `sessions-table`, `session-<id>`, `session-<N>-batch-<N>`, `sessions-empty` |
| `/queue` · карантин і запис | відкладені, карантин, модерація, записи та збіг ключа повтору | `queue-deferred`, `queue-quarantine`, `queue-moderation`, `queue-writes`, `write-key-check`, `write-N` |
| `/stats` · статистика | ролі, час пачки, паритет та A/B replay | `stats-roles`, `stats-role-<role>`, `stats-session-table`, `stats-parity`, `stats-ab-panel`, `stats-ab` |
| `/review` · черга до людини | загальна кількість, завантаження, список пропозицій, текст і рішення | `review-total`, `review-shown`, `review-loading`, `review-list`, `review-item-N`, `review-text-N`, `review-empty`, `review-bulk-approve`, `review-bulk-reject` |

## Після dry-run на DEV

1. `/run` · `run-session`, `run-batch-id`, `run-states`, `run-rows`: усі пачки
   переглянуті до кінця, а стани рядків і переходів відповідають завершенню.
2. `/calls` · `calls-count`, `calls-table`, `call-N-state`: кожен виклик має
   роль, стан і видиму причину відмови; за потреби відкрити `/call?id=<id>` та
   звірити `call-id`, `call-state`, `call-parsed`.
3. `/stats` · `stats-roles`, `stats-session-table`: час ролей і пачок пояснює
   хід прогону; підозрілу кількість повторів звірити з відповідним викликом.
4. `/queue` · `queue-writes`, `write-key-check`: для dry-run записів немає;
   перевірка ключів повтору узгоджується з `WriteRecord`.
5. `/sessions` · `sessions-table`, `session-<id>-batch-<N>`: підсумок і
   причини завершення сесії збігаються з `/run`.

Автотести не додаються й не запускаються (D-08). Gate перевіряє статику;
поведінкове приймання робиться у браузері через MCP Playwright.
