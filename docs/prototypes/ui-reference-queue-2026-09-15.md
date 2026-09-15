# UI reference · черга до людини · 2026-09-15

**Статус:** поведінково відповідає, візуально частково. Основний queue flow
реально працює; reference додає композицію, фон і два різні content-density
states.

## Джерело

- Знімок: [ui-reference-queue-2026-09-15.png](ui-reference-queue-2026-09-15.png)
- Розмір: `1024 × 1536`
- Екран: queue із короткими й довгими рядками, desktop reference.
- Старий prototype: [`03-moderation.html`](03-moderation.html), історичний і
  може не містити нових API/state елементів.

## Що зображено

1. Навігація з active `черга до людини` та queue badge `347`.
2. Заголовок і пояснення, що рішення лишається за людиною.
3. Control bar: `PROD`, waiting count, visible count, pagination/select і
   `показувати`.
4. Search input та `Оновити`.
5. Row cards: checkbox, numeric id, source text, editable translation textarea,
   green `схвалити` і red `відхилити`.
6. Нижня частина показує довгі descriptions, щоб перевірити wrapping, textarea
   height і читабельність довгого контенту.
7. Reference візуально повторює header вдруге як окремий captured viewport;
   це не вимога дублювати navigation у runtime.

## Відповідність коду й design system

| Частина reference | Поточний код | Статус |
|---|---|---|
| Queue count, visible count, limit | `web/queue.html` | реалізовано |
| Search і refresh | `queueSearch`, `reload` | реалізовано |
| Checkbox, textarea, approve/reject | row renderer + actions | реалізовано |
| Long-text wrapping | `.grow` textarea behavior | реалізовано, потребує visual polish |
| Semantic button/status colors | `web/app.css` tokens and existing classes | реалізовано |
| Background, exact spacing, compact two-line row layout | current runtime | частково відповідає |
| Reference duplicate header/footer | capture artifact | не переноситься як runtime behavior |

## Live verification

На `/queue` після завантаження перевірено live API state: `чекають 347`,
`показано 20`, пошук, refresh, 20 checkboxes, editable textareas та approve /
reject actions присутні в DOM/AX. Console errors під час перевірки не
виявлені. Жодних approve/reject дій не виконувалось.

## Важлива межа

Довгі рядки в reference можуть містити game markup. Їх не можна виправляти
лише CSS-ом або переписувати дані під картинку: API response і escaping є
контрактом. Візуальне завдання тут — wrapping, hierarchy, hit areas і стани.
