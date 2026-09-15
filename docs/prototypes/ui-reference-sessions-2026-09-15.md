# UI reference · сесії роботи · 2026-09-15

**Статус:** частково відповідає. Reference містить одразу два стани одного
екрана; поточний `/sessions` має робочий список і expanded state, але не весь
visual composition знімка.

## Джерело

- Знімок: [ui-reference-sessions-2026-09-15.png](ui-reference-sessions-2026-09-15.png)
- Розмір: `1536 × 1024`
- Екран: sessions collapsed + expanded, desktop, dark artwork.
- Старий prototype: [`02-sessions.html`](02-sessions.html), історичний і не
  повністю актуальний.

## Що зображено

1. Загальна шапка, active `сесії роботи`, background illustration і footer.
2. Варіант collapsed: заголовок відкритої сесії, `нова сесія`, compact session
   row з expand button, status, пачкою та quarantine count.
3. Варіант expanded: та сама session row, таблиця пачки, counts `рядків / у
   шар / до людини / карантин`, timestamp і `закрити сесію`.
4. Ліва vertical action `РОЗГОРНУТИ СТАН`, яка показує, що стан можна швидко
   розкрити з navigation rail.
5. Усі важливі стани читаються текстом, а не лише кольором.

## Відповідність коду й design system

| Частина reference | Поточний код | Статус |
|---|---|---|
| Session list і live counts | `web/sessions.html` | реалізовано |
| Expand/collapse session | session row button + JS | реалізовано |
| Batch table і summary cards | `sessionBar()` / session body | реалізовано |
| Close session action | `closeS` action | реалізовано |
| New session action | `sessNew` action | реалізовано |
| Collapsed + expanded composition в одному visual flow | current page | частково відповідає |
| Artwork, left rail action, exact card hierarchy | немає повної реалізації | не реалізовано |

## Live verification

На `/sessions` перевірено expanded live state: session id, пачка, status,
табличні counts, summary counts, timestamp і `закрити сесію` присутні в
DOM/AX та видимі в браузері. Console errors під час перевірки не виявлені.
Destructive close action не натискалась.

## Наступний visual scope

Підтягнути collapsed/expanded hierarchy та rail лише після уточнення, чи rail є
постійною навігацією чи декоративним елементом. Session lifecycle та назавжди
збережені підсумки не змінювати.
