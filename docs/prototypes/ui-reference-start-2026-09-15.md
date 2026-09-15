# UI reference · старт прогону · 2026-09-15

**Статус:** частково відповідає. Це новий visual target для `/start`; старий
`04-start.html` лишається історичним прототипом і не є повною специфікацією.

## Джерело

- Знімок: [ui-reference-start-2026-09-15.png](ui-reference-start-2026-09-15.png)
- Розмір: `1557 × 1010`
- Екран: `Почати прогін`, desktop, темна тема з фоновою ілюстрацією.
- Актуальність: новіший за `04-start.html`; це reference для наступної
  візуальної ітерації, а не доказ фактичних даних.

## Що зображено

1. Глобальна шапка: логотип BDO, назва й підзаголовок, навігація, active
   `почати прогін`, live-status і декоративний Black Desert background.
2. Заголовок сторінки та пояснення призначення екрана.
3. Один широкий control card із трьома зонами: `Куди пишемо` (`PROD`/`TEST`),
   `Модель` із повноекранним переходом і `Роздуми (thinking)` з toggle,
   лімітом байтів та info icon.
4. Чотири mode cards: `Патч`, `Покращення ШІ`, `Пропозиції`, `Ручний`; active
   `Патч` має gold/blue outline та власну іконку.
5. Таблиця патчів із radio-like selection, номером, датою, кількістю рядків,
   `Без ШІ-шару`, `Статус` і поясненням active row.
6. Нижні controls: категорія, кількість пачок, пояснення залишку, `Оновити`.
7. `Що запуститься` з command preview, PROD confirmation toggle, primary
   `Почати прогін` і secondary `Тестовий прогін — без запису`.
8. Footer із версією, описом продукту та мовним маркером.

## Відповідність коду й design system

| Частина reference | Поточний код | Статус |
|---|---|---|
| Навігація, заголовок, PROD marker | `web/start.html`, `web/app.css` | реалізовано поведінково; фон/декор частково |
| Модель і thinking | `web/start.html`, `/models` link | реалізовано; зараз композиція більш вертикальна |
| Чотири режими | `#modes` у `web/start.html` | реалізовано; нові картки з іконками ще не перенесені |
| Таблиця патчів і live counts | `#patchRows` у `web/start.html` | реалізовано; reference має додаткове явне `Статус` поле |
| Категорія, batches, preview, PROD guard | `web/start.html` + existing actions | реалізовано, логіку не змінюємо |
| Кнопки та стани | `web/app.css` design-system layer | реалізовано через semantic tokens і focus/disabled states |
| Background artwork, left ornament, exact three-column grid | немає в поточному runtime | не реалізовано |

## Live verification

На живому `/start` перевірено DOM/AX: є модель, thinking, чотири режими,
таблиця патчів, категорія, batches, PROD confirmation, start і dry-run.
Поточна сторінка відображає реальні counts із state/API; reference numbers не
переносяться в код. Console errors під час перевірки не виявлені.

## Наступний visual scope

Перенести спочатку hierarchy й grid із reference, потім icons/status column і
лише після цього background artwork. Command preview, confirmation і всі
існуючі action handlers мають лишитися без змін.
