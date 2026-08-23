# Маршрутизація правил агентів

Це довідник для основного агента та власника. Він не є глобальною інструкцією
OpenCode і не підключається через `opencode.json`.

## Рівні правил

| Роль | Канонічне джерело | Що передається моделі |
|---|---|---|
| OpenCode primary | `.opencode/agents/патч.md`, `ручний.md`, `пропозиції.md`, `покращення.md` | поточний режим, порядок `./bdo`, рішення диригента |
| `translation-worker` | `.opencode/agents/translation-worker.md` + staged worker schema | переклад і правила identity/quality для worker |
| `translation-qa` | `.opencode/agents/translation-qa.md` + staged QA schema | перевірка рядків і QA verdict |
| `translation-repair` | `.opencode/agents/translation-repair.md` + staged response schema | точкове виправлення дефектів |
| `translation-terminology` | `.opencode/agents/translation-terminology.md` + terminology schema | термінологічні пропозиції |
| `translation-smoke` | `.opencode/agents/translation-smoke.md` + strict smoke schema | capability JSON |

## Документи за потребою

Primary-режим звертається до документа лише коли його робочий крок цього
потребує:

- API-контракт: `API.md`, `API_WRITE_CONTRACT.md`;
- flow і state: `FLOW_STATE.md`;
- безпека та публічність: `SECURITY.md`;
- моделі й OpenCode: `.opencode/translation-models.json`,
  `UI_SUBAGENT_WORKFLOW.md`;
- плани: `plans/README.md`, `plans/BACKLOG.md`.

Child-контракт повністю визначений власним prompt, staged payload і schema.
Технічне обмеження tools забезпечують `opencode.json`,
`translation-execution-guard` і `translation-routing-guard`; доставку payload у
Task prompt і збереження результату Task робить механічно
`translation-child-contract` (envelope у `state/next-child.json`).

## Правило зміни

Зміна формату відповіді, звіту або документації primary не вимагає змін у
child-prompts, якщо JSON-контракт ролі не змінився. Зміна child-контракту
оновлює тільки відповідний agent prompt, schema та його вузьку перевірку.
