# Маршрутизація правил агентів

Це довідник для основного агента та власника. Він не є глобальною інструкцією
OpenCode і не підключається через `opencode.json`.

## Головний UX-контракт власника

Власник не запускає bash/CLI-команди проєкту вручну й змінює лише локальний
`.env`, після чого повідомляє primary людською мовою, що продовжити. Уся робота
виконується через primary-режими `патч`, `ручний`, `пропозиції`, `покращення-ші`.
Primary сам виконує `./bdo env`, preflight/smoke, `mode status/start`,
`./bdo run drive`, аудит, gates і перед завершенням `./bdo gate full && ./bdo api`.
Команди в цьому довіднику · внутрішні кроки flow або developer/diagnostics
довідка, не завдання власнику.

## Рівні правил

| Роль | Канонічне джерело | Що передається моделі |
|---|---|---|
| OpenCode primary | `.opencode/agents/патч.md`, `ручний.md`, `пропозиції.md`, `покращення-ші.md` | поточний режим, порядок `./bdo`, рішення диригента |
| `translation-*` child | tracked `.opencode/agent-templates/translation-*.md` + generated/ignored `.opencode/agents/translation-*.md` + staged schema | вузька роль і її JSON-відповідь |

## Документи за потребою

Primary-режим звертається до документа лише коли його робочий крок цього
потребує:

- API-контракт: `API.md`, `API_WRITE_CONTRACT.md`;
- flow і state: `FLOW_STATE.md`;
- безпека та публічність: `SECURITY.md`;
- моделі й OpenCode: tracked `.opencode/templates/translation-models.json`,
  generated/ignored `.opencode/translation-models.json`,
  `UI_SUBAGENT_WORKFLOW.md`;
- плани: `plans/README.md`, `plans/BACKLOG.md`.

Child-контракт повністю визначений власним prompt, staged payload і schema.
Технічне обмеження tools забезпечують generated/ignored `opencode.json`
(джерело · tracked `templates/opencode.json`),
`translation-execution-guard` і `translation-routing-guard`; доставку payload у
Task prompt і збереження результату Task робить механічно
`translation-child-contract` (envelope у `state/next-child.json`).

## Правило зміни

Зміна формату відповіді, звіту або документації primary не вимагає змін у
child-prompts, якщо JSON-контракт ролі не змінився. Зміна child-контракту
оновлює тільки відповідний agent prompt, schema та його вузьку перевірку.
