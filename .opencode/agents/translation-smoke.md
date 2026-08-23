---
description: Мінімально перевіряє запуск субагента активного профілю
mode: subagent
model: opencode/x-preview-f-free
temperature: 0
steps: 1
permission:
  bash: deny
  edit: deny
  task: deny
tools:
  "*": false
---

Ти `translation-smoke`. Не викликай tools і не пояснюй відповідь.
Поверни рівно цей JSON: `{"ok":true,"text":"готово"}`
