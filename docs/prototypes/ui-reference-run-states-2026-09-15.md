# UI reference · прогін у чотирьох станах · 2026-09-15

**Статус:** базова структура відповідає, стани треба перевіряти окремо. Це
composite reference з чотирьох кадрів, а не один runtime snapshot.

## Джерело

- Знімок: [ui-reference-run-states-2026-09-15.png](ui-reference-run-states-2026-09-15.png)
- Розмір: `1536 × 1024`
- Екран: `/` · прогін у станах awaiting terminology, active role, completed
  role та кілька завершених ролей.
- Старий prototype: [`01-run-live.html`](01-run-live.html), історичний; current
  runtime має додаткові state/recovery elements.

## Що зображено

1. Спільна шапка: target, batch id, patch/row counts, current step, timer,
   stop/new-run controls і breadcrumb кроків.
2. Кадр 1: `awaiting_terminology`, warning/info message, role section і empty
   counters.
3. Кадр 2: active role card із streaming indicator, elapsed time, request
   payload preview і live response/thinking pane.
4. Кадр 3: завершена роль плюс наступна активна роль; statuses `готово` /
   `працює`, counters і journal.
5. Кадр 4: кілька завершених ролей, один active row і compact progress bar.
6. У кожному кадрі є `журнал кроків`, follow-tail control і summary cards.

## Відповідність коду й design system

| Частина reference | Поточний код | Статус |
|---|---|---|
| Header, step breadcrumb, stop/continue | `web/index.html` | реалізовано |
| Role/call cards | `#calls` renderer у `web/index.html` | реалізовано |
| Live journal and follow-tail | stream/journal UI | реалізовано |
| Verdicts and filters | `#verdictPanel`, chips, rows | реалізовано |
| Thinking pane and streaming tempo | `web/index.html` + `web/app.js` | реалізовано поведінково |
| Four exact reference states | current state depends on live run | потребує окремої live verification |
| Background artwork and exact composite spacing | current runtime | частково відповідає |

## Live verification

На `/` перевірено live waiting state: batch header, current step, stop/continue
state, role section, counters і journal присутні в DOM/AX та видимі. Активний
model streaming не запускався під час цієї перевірки, тому кадри 2–4 не
позначаються як повністю підтверджені одним знімком. Console errors не
виявлені.

## Наступний visual scope

Підтвердити чотири стани на безпечній synthetic/dev пачці та окремо порівняти
spacing, progress, live typing і thinking pane. Не підміняти живий flow статичною
картинкою і не змінювати envelope/state-machine логіку заради pixel match.
