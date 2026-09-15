# UI reference · моделі · 2026-09-15

**Статус:** здебільшого відповідає. Це перевірений попередній design snapshot
для `/models`; його збережено як актуальний reference, але живі дані й текст
можуть відрізнятися.

## Джерело

- Знімок: [ui-reference-models-2026-09-15.png](ui-reference-models-2026-09-15.png)
- Розмір: `1122 × 1402`
- Екран: `Моделі`, desktop, темна BDO theme.
- Порівняння: перевірено на live `/models`; старих HTML-прототипів для цього
  екрана немає, тому знімок є головним visual reference.

## Що зображено

1. Шапка з навігацією та active `моделі`.
2. Заголовок `Моделі`, пояснення, timestamp каталогу й `Оновити перелік`.
3. Верхній split layout: `Активна модель (загальна)` з runtime/model/status,
   badge `GLOBAL` і `Змінити модель`; поруч `Каталог` зі статистикою Ollama/OMLX.
4. Thinking card з toggle, thinking ceiling, `Зберегти` та поясненням.
5. Таблиця каталогу: runtime, model, size, quantization, status, actions;
   active global model виділений окремо.
6. Таблиця моделей ролей із effective model, source, role override select і
   `Застосувати`.
7. Footer, gold accents, blue primary states, green availability statuses.

## Відповідність коду й design system

| Частина reference | Поточний код | Статус |
|---|---|---|
| Active global model | `web/models.html` selection block | реалізовано й перевірено |
| Runtime summary | `catalogSummary` у `web/models.html` | реалізовано |
| Thinking controls | `thinkToggle`, `thinkLimit`, `saveThinking` | реалізовано |
| Model catalog actions | `model-table` і `data-action` handlers | реалізовано |
| Role model overrides | `selection-roles` і role apply actions | реалізовано |
| Semantic colors, badges, buttons, focus states | `web/app.css` | реалізовано як спільний шар |
| Exact icons, artwork, spacing/widths | existing icons + current layout | частково відповідає |

## Live verification

На `/models` перевірено AX-структуру: global selection, catalog summary,
thinking controls, 9 model rows і role selectors/actions присутні. Видимий
екран зберігає той самий hierarchy та dark visual language. Console errors під
час перевірки не виявлені. Дії завантаження/вивантаження не натискались, щоб не
змінювати runtime state.

## Висновок

Цей знімок можна використовувати як поточний target для polish, але не як
заміщення live data. Нові елементи спершу мають отримати semantic token/class у
`web/app.css`, а потім бути підключені до `models.html` без зміни model actions.
