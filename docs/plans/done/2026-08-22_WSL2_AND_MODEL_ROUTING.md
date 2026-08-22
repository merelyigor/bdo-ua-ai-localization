# WSL2 і маршрутизація моделей

- **Статус:** done (закрито 2026-08-22)
- **Створено:** 2026-08-22
- **Реєстр:** [docs/plans/README.md](../README.md)

## Результат

- Windows використовує один Bash/PHP flow через WSL2; `./bdo platform` входить
  у preflight.
- `.opencode/translation-models.json` задає маршрути окремо за ролями, ordered
  fallback, paid classification і явний `allow_paid`.
- `./bdo profile` синхронізує policy, `opencode.json` і frontmatter та запускає
  validator.
- Plugin guard блокує чужий і неавторизований платний route; smoke має strict
  JSON schema. Child driver передає route явно й пише фактичну модель у receipt.
- API writer бере provider/model із receipt фактичного worker після fallback.
- `gate shell`, `gate agents`, `gate docs` і `gate full` завершилися з exit 0.

## Зовнішня acceptance

Для нового зовнішнього provider/model власник один раз запускає
`translation-smoke` у OpenCode. Це свідомо не автоматизовано прямим HTTP:
credentials належать OpenCode `/connect`, а перевірка має охопити саме його
provider routing і strict JSON schema.
