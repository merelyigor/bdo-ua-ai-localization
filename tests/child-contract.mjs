import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { TranslationChildContract, referencesStagedPayload } from "../.opencode/plugin/translation-child-contract.ts"

const directory = mkdtempSync(join(tmpdir(), "bdo-child-contract-"))
mkdirSync(join(directory, "state", "batch"), { recursive: true })
const payload = '[{"identity_hash":"aaaa","source_text":"Ancient Sword"}]'
writeFileSync(join(directory, "state/batch/payload.json"), `${payload}\n`)
const envelope = {
  kind: "child",
  role: "translation-worker",
  payload_path: join(directory, "state/batch/payload.json"),
  response_path: "batch/out.json",
}
writeFileSync(join(directory, "state/next-child.json"), JSON.stringify(envelope))

const hooks = await TranslationChildContract({ directory })
const before = hooks["tool.execute.before"]
const after = hooks["tool.execute.after"]

// Диригент передає лише посилання; точний payload підставляє плагін.
const args = { subagent_type: "translation-worker", description: "d", prompt: `payload:${envelope.payload_path}` }
await before({ tool: "task", sessionID: "s", callID: "c" }, { args })
if (args.prompt !== payload) throw new Error("prompt was not replaced with the staged payload")

// ...і ПІСЛЯ виклику payload прибирається з аргументів назад у посилання.
//
// Інакше він лишається у транскрипті платної моделі до кінця сесії. Виміряно
// 2026-08-26 по базі OpenCode: 465 358 із 761 405 символів контексту диригента
// (61%) були саме такими підставленими payload, а витрата росте квадратично ·
// кожен наступний запит пересилає всі попередні заново.
{
  const args2 = { subagent_type: "translation-worker", description: "d", prompt: `payload:${envelope.payload_path}` }
  await before({ tool: "task", sessionID: "s", callID: "c" }, { args: args2 })
  if (args2.prompt !== payload) throw new Error("before hook must still deliver the payload to the child")
  await after(
    { tool: "task", sessionID: "s", callID: "c", args: args2 },
    { output: "<task_result>\n[{\"identity_hash\":\"aaaa\",\"text\":\"Меч\"}]\n</task_result>", args: args2 },
  )
  if (args2.prompt !== `payload:${envelope.payload_path}`) {
    throw new Error(`staged payload stayed in the conductor transcript: ${args2.prompt.slice(0, 60)}`)
  }
}

// Переписаний payload у аргументі відхиляється. 2026-08-27 диригент носив
// payload сам, і на пачці 50 рядків виклик ламався на розборі JSON (позиція
// 76134). Правило було в промпті всіх чотирьох режимів і не втрималось.
{
  const huge = { subagent_type: "translation-worker", description: "d", prompt: payload }
  await before({ tool: "task", sessionID: "s", callID: "c" }, { args: huge }).then(
    () => { throw new Error("transcribed payload was accepted") },
    (error) => {
      if (!/РІВНО посилання/.test(error.message)) throw new Error(`wrong transcription error: ${error.message}`)
      if (!error.message.includes(envelope.payload_path)) throw new Error("error must name the exact reference to pass")
    },
  )
  // Порожній prompt і довільний текст · та сама відмова.
  for (const bad of ["", "QA batch 7", "payload", "Ось payload: [{...}]"]) {
    await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-worker", prompt: bad } }).then(
      () => { throw new Error(`prompt «${bad}» was accepted`) },
      (error) => { if (!/РІВНО посилання/.test(error.message)) throw new Error(`wrong error for «${bad}»: ${error.message}`) },
    )
  }
  // Написання шляху не має значення: важливо, що це ТОЙ САМИЙ payload.
  for (const good of [`payload:${envelope.payload_path}`, "payload:payload.json", "payload: state/batch/payload.json"]) {
    if (!referencesStagedPayload(good, envelope.payload_path)) throw new Error(`legal reference rejected: ${good}`)
  }
  if (referencesStagedPayload("payload:other.json", envelope.payload_path)) {
    throw new Error("reference to a foreign payload was accepted")
  }
}

// Порожній або відсутній payload зупиняє виклик зрозуміло, а не віддає child
// порожній prompt: диригент більше не носить payload сам, підмінити нікому.
writeFileSync(join(directory, "state/batch/payload.json"), "\n")
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-worker", prompt: "x" } }).then(
  () => { throw new Error("empty staged payload was accepted") },
  (error) => { if (!/порожній/.test(error.message)) throw new Error(`wrong empty-payload error: ${error.message}`) },
)
writeFileSync(join(directory, "state/next-child.json"), JSON.stringify({ ...envelope, payload_path: join(directory, "state/batch/gone.json") }))
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-worker", prompt: "x" } }).then(
  () => { throw new Error("missing staged payload was accepted") },
  (error) => { if (!/недоступний/.test(error.message)) throw new Error(`wrong missing-payload error: ${error.message}`) },
)
writeFileSync(join(directory, "state/batch/payload.json"), `${payload}\n`)
writeFileSync(join(directory, "state/next-child.json"), JSON.stringify(envelope))

// Невідповідна роль зупиняється до створення сесії.
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-qa", prompt: "x" } }).then(
  () => { throw new Error("role mismatch was accepted") },
  () => undefined,
)

// Не-translation агент і не-task інструменти проходять без змін.
const foreign = { subagent_type: "general", prompt: "untouched" }
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: foreign })
if (foreign.prompt !== "untouched") throw new Error("foreign agent prompt was modified")
await before({ tool: "bash", sessionID: "s", callID: "c" }, { args: { command: "ls" } })

// Результат Task зберігається механічно · лише валідний JSON з-під task_result.
const wrapped = (text) => `<task id="ses_x" state="completed">\n<task_result>\n${text}\n</task_result>\n</task>`
await after(
  { tool: "task", sessionID: "s", callID: "c", args: { subagent_type: "translation-worker" } },
  { title: "d", output: wrapped('[{"identity_hash":"aaaa","text":"Переклад"}]'), metadata: {} },
)
const saved = JSON.parse(readFileSync(join(directory, "state/batch/out.json"), "utf8"))
if (saved[0].text !== "Переклад") throw new Error("captured result differs from the child answer")

// Markdown-огорожа знімається детерміновано: Zen повертає коректний JSON у
// ```json, і пачка не має ставати через обгортку, якої ніхто не просив.
rmSync(join(directory, "state/batch/out.json"))
await after(
  { tool: "task", sessionID: "s", callID: "c", args: { subagent_type: "translation-worker" } },
  { title: "d", output: wrapped('```json\n[{"identity_hash":"aaaa","text":"Переклад"}]\n```'), metadata: {} },
)
const unfenced = JSON.parse(readFileSync(join(directory, "state/batch/out.json"), "utf8"))
if (unfenced[0].text !== "Переклад") throw new Error("fenced JSON was not unwrapped")

// Дитина · це модель, а не скрипт: JSON плюс змістовна примітка приймається,
// дані зберігаються, примітка лишається власнику. Саме через це відхилення
// пачка колись стала на рядку `AMD FidelityFX`, хоча child був правий.
rmSync(join(directory, "state/batch/out.json"))
const withNote = '```json\n[{"identity_hash":"aaaa","text":"AMD FidelityFX"}]\n```\n\nПримітка: це торгова марка, залишено без перекладу.'
const noteResult = { title: "d", output: wrapped(withNote), metadata: {} }
await after({ tool: "task", sessionID: "s", callID: "c", args: { subagent_type: "translation-worker" } }, noteResult)
if (JSON.parse(readFileSync(join(directory, "state/batch/out.json"), "utf8"))[0].text !== "AMD FidelityFX") {
  throw new Error("answer with a note was rejected")
}
const notes = readFileSync(join(directory, "state/child-notes.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line))
if (!/торгова марка/.test(notes.at(-1).note)) throw new Error("child note was thrown away")

// Диригент отримує підтвердження, а не текст відповіді: саме це знімає з
// платної моделі найбільший обсяг контексту.
if (/AMD FidelityFX/.test(noteResult.output)) throw new Error("child answer leaked into the conductor context")
if (!/Збережено відповідь translation-worker: 1 елементів/.test(noteResult.output)) {
  throw new Error(`conductor got no compact confirmation: ${noteResult.output}`)
}
if (!/примітку/.test(noteResult.output)) throw new Error("conductor was not told about the note")

// JSON без огорожі, але з текстом навколо · та сама історія.
rmSync(join(directory, "state/batch/out.json"))
await after(
  { tool: "task", sessionID: "s", callID: "c", args: { subagent_type: "translation-worker" } },
  { title: "d", output: wrapped('Ось результат: [{"identity_hash":"aaaa","text":"Готово"}]\nПояснення: нічого не змінював.'), metadata: {} },
)
if (JSON.parse(readFileSync(join(directory, "state/batch/out.json"), "utf8"))[0].text !== "Готово") {
  throw new Error("bare JSON surrounded by prose was rejected")
}

// Проза не зберігається, але й НЕ зупиняє прогін: інцидент фіксується, файл
// відповіді не зʼявляється, і наступний drive перезапустить того самого child.
rmSync(join(directory, "state/batch/out.json"))
await after(
  { tool: "task", sessionID: "s", callID: "c", args: { subagent_type: "translation-worker" } },
  { title: "d", output: wrapped("Вибачте, я не зміг перекласти"), metadata: {} },
)
if (existsSync(join(directory, "state/batch/out.json"))) throw new Error("prose answer was captured as a result")
const incidents = readFileSync(join(directory, "state/flow-incidents.jsonl"), "utf8").trim().split("\n")
const lastIncident = JSON.parse(incidents[incidents.length - 1])
if (lastIncident.role !== "translation-worker" || lastIncident.attempt !== 1) {
  throw new Error("incident was not recorded for the owner")
}

// Повторна спроба несе уточнення: не зупинка прогону, а перезапуск того самого
// child із контекстом про те, чим попередня відповідь була погана.
const retryArgs = { subagent_type: "translation-worker", description: "d", prompt: `payload:${envelope.payload_path}` }
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: retryArgs })
if (!retryArgs.prompt.startsWith(payload)) throw new Error("retry prompt lost the exact payload")
if (!/спроба 2/.test(retryArgs.prompt) || !/markdown-огорожі/.test(retryArgs.prompt)) {
  throw new Error("retry prompt carries no corrective context")
}

// Успішна відповідь знімає позначку: наступний виклик іде без уточнення.
await after(
  { tool: "task", sessionID: "s", callID: "c", args: { subagent_type: "translation-worker" } },
  { title: "d", output: wrapped('[{"identity_hash":"aaaa","text":"Готово"}]'), metadata: {} },
)
const cleanArgs = { subagent_type: "translation-worker", description: "d", prompt: `payload:${envelope.payload_path}` }
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: cleanArgs })
if (cleanArgs.prompt !== payload) throw new Error("incident note survived a successful answer")

// Без envelope: smoke легальний (ручний @translation-smoke), робочі ролі · ні.
rmSync(join(directory, "state/next-child.json"))
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-smoke", prompt: "ping" } })
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-worker", prompt: "x" } }).then(
  () => { throw new Error("worker task without a staged envelope was accepted") },
  () => undefined,
)

console.log("translation child contract: OK")
