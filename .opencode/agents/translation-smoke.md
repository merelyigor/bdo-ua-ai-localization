---
description: Мінімально перевіряє запуск субагента активного профілю
mode: subagent
model: opencode/x-preview-f-free
temperature: 0
# Alpha can spend its first step on internal reasoning even for this one-line
# contract; two bounded steps keep the smoke cheap while leaving one for JSON.
steps: 2
permission:
  bash: deny
  edit: deny
  task: deny
tools:
  "*": false
---

Ти child `translation-smoke`. Поверни одним рядком рівно цей JSON без markdown:
`{"ok":true,"text":"готово"}`
