# P59 · Покращення ШІ: незмінений текст стає ревізією нашої моделі

| Поле | Значення |
|---|---|
| ID | P59 |
| Статус | in-progress |
| Створено | 2026-10-02 |
| Оновлено | 2026-10-02 |
| Автор | Claude (сесія планування) за запитом власника |
| Джерело | власник 2026-10-02: «якщо мій прогін не міняє і не покращує рядок, значить мій ШІ згоден… помітити як нову ревізію моєї моделі». Контракт сайту · повідомлення сесії сайту 2026-10-02. Рядок `чекає` у `BACKLOG.md`. |
| Реєстр | [README.md](README.md) |

## Що вже є

Режим `improve` (`config/modes.json`) вибирає ШІ-шар із
`machine_client_name_not=bdo-ua-translate-python` і пише каналом `machine`
(`layer=machine`, `mode=direct`). Якщо модель повернула той самий текст, сайт
віддає `skipped`/`unchanged` без ревізії: рядок лишається ревізією попереднього
автора й вибирається знову в кожному прогоні.

## Контракт сайту (2026-10-02)

- `reaffirm: true` на рівні ЗАПИТУ в `POST /translations` і `/translations/validate`;
  діє лише для `layer=machine`, `mode=direct` і з непорожнім `client_name`
  (ми його шлемо), інакше мовчки ігнорується.
- Текст збігся, поточна ревізія не наша · нова ревізія з атрибуцією запиту,
  статус елемента `reaffirmed`, `revision_id`, `layer: machine`; `meta.reaffirm: true`.
- «Вже наша» (той самий `client_name` І `client_version`) · `skipped/unchanged`.
- Перевірки ті самі; `auto_repair` змінив текст · звичайний `ok`/`repaired`.
- Квота: `reaffirmed` рахується в `meta.written` і денну квоту рядків.
- `validate`: `reaffirmed` без запису, у `meta.accepted`.
- PROD до деплою прапорець ігнорує (буде `unchanged`) · клієнта можна випускати.

## Goal

Прогін `improve` фіксує згоду нашої моделі з незміненим рядком новою ревізією;
такий рядок більше не вибирається режимом знову.

## Definition of Done

- [ ] `ModeSpec.reaffirm` (типово `false`), у `improve` · `true`.
- [ ] `validate`/`write` (`api/endpoints.py`) шлють `reaffirm: true`, коли їх
  так викликали; `step_commit` і `step_validate` передають `reaffirm` лише для
  каналу `machine` режиму з `reaffirm`. Рядки, що пішли в `proposal`, його не мають
  (вони в іншій групі запису).
- [ ] Статус `reaffirmed` · успіх скрізь, де успіхом є `ok`/`unchanged`
  (`commit.py`, `steps.py`, `heal.py`), і має людську мітку на `/run`.
- [ ] Звірка після деплою сайту: прогін власника `improve` · незмінений рядок у
  `/history` має нову ревізію нашої моделі; знімки `P59-*`; gate 0.
- [ ] План видалено на закритті, рядок беклогу геть, PROGRESS.

## Non-goals

- `reaffirm` для `refresh`, `patch`, `proposals` (окреме рішення власника).

## Step 1.1 — Клієнт `reaffirm`

- **Status:** in-progress
- **Files:** `config/modes.json`, `src/bdo_translate/modes.py`, `src/bdo_translate/api/endpoints.py`, `src/bdo_translate/pipeline/commit.py`, `src/bdo_translate/pipeline/steps.py`, `src/bdo_translate/pipeline/heal.py`, `src/bdo_translate/web/labels.py`.
- **Verify:** gate 0; dry-run `improve` після деплою сайту показує `reaffirmed`.
- **Notes:** 2026-10-02 · код є, gate 0. `reaffirm` передається в усі `validate`/`write` групи `machine` у `step_commit` і в `step_validate`; виклики `validate` у `heal.py`/`names.py` без прапорця (там лише перевірка ремонту, статус `unchanged` лишається успіхом). Перед записом незмінені рядки не відсікаються, тож прапорець доходить до всіх.
- **Notes:** 2026-10-02 · сайт: `reaffirm` на DEV (2a2d079), PROD чекає власника; `meta.reaffirm` лише коли прапорець подіяв; `reaffirmed` може нести `repaired_text`, якщо `auto_repair` виправив текст до збігу з поточним. Крок 1.1b: такий `repaired_text` застосовується так само, як для `repaired` (`step_validate`, `step_commit`).

## Step 1.2 — Звірка й закриття

- **Status:** todo
- **Do:** після повідомлення сайту про DEV/PROD · перевірка на прогоні власника (лише читання), `/history` рядка; закриття плану.
- **Notes:** 2026-10-02 · DEV, тестовий прогін improve без запису (покоління go/space-bunny-free 27.09, 5 рядків): переклад збігся з поточним текстом у всіх 5, `validate` з `reaffirm: true` пройшов без 400, 5 пройшло. Статус елемента validate (`reaffirmed`) екран `/run` не показує, тож сам статус не побачено; `reaffirmed`-ревізія в `/history` · лише після запису (DEV з дозволом власника або PROD).

## Progress log

- 2026-10-02 · план створено за контрактом сайту; DEV сайт ще готує.
- 2026-10-02 · крок 1.1 · код без звірки, чекає деплою сайту.
