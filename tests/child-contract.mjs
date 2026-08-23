import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { TranslationChildContract } from "../.opencode/plugin/translation-child-contract.ts"

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

// Промпт диригента замінюється точним вмістом staged payload.
const args = { subagent_type: "translation-worker", description: "d", prompt: "СПОТВОРЕНА КОПІЯ" }
await before({ tool: "task", sessionID: "s", callID: "c" }, { args })
if (args.prompt !== payload) throw new Error("prompt was not replaced with the staged payload")

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

// Проза не зберігається: диригент мусить зупинитись, а не «полагодити» відповідь.
rmSync(join(directory, "state/batch/out.json"))
await after(
  { tool: "task", sessionID: "s", callID: "c", args: { subagent_type: "translation-worker" } },
  { title: "d", output: wrapped("Вибачте, я не зміг перекласти"), metadata: {} },
)
if (existsSync(join(directory, "state/batch/out.json"))) throw new Error("prose answer was captured as a result")

// Без envelope: smoke легальний (ручний @translation-smoke), робочі ролі · ні.
rmSync(join(directory, "state/next-child.json"))
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-smoke", prompt: "ping" } })
await before({ tool: "task", sessionID: "s", callID: "c" }, { args: { subagent_type: "translation-worker", prompt: "x" } }).then(
  () => { throw new Error("worker task without a staged envelope was accepted") },
  () => undefined,
)

console.log("translation child contract: OK")
