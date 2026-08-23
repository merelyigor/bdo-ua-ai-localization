---
description: Мінімально перевіряє запуск субагента активного профілю
mode: subagent
model: opencode/mimo-v2.5-free
temperature: 0
steps: 1
permission:
  bash: deny
  edit: deny
  task: deny
tools:
  "*": false
---

Ти ізольований child `translation-smoke`. Формат звіту проєкту (`Звіт`,
`Зроблено`, `Зʼясовано`, `Що далі`) до тебе не застосовується. Не викликай tools,
не пояснюй відповідь і поверни одним рядком рівно цей JSON без markdown:
`{"ok":true,"text":"готово"}`
