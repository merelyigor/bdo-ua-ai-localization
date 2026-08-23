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

Ти child `translation-smoke`. Поверни одним рядком рівно цей JSON без markdown:
`{"ok":true,"text":"готово"}`
