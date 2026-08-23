import { existsSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { TranslationResultWriter } from "../.opencode/plugin/translation-result-writer.ts"

const directory = mkdtempSync(join(tmpdir(), "bdo-result-writer-"))
mkdirSync(join(directory, "state", "batch"), { recursive: true })
const hooks = await TranslationResultWriter({ directory })
const result = await hooks.tool.translation_result.execute({ response_path: "batch/candidate.json", content: '[{"text":"Готово"}]' })
if (JSON.parse(result.output).ok !== true) throw new Error("writer did not confirm success")
if (JSON.parse(readFileSync(join(directory, "state/batch/candidate.json"), "utf8"))[0].text !== "Готово") throw new Error("writer changed JSON")
await hooks.tool.translation_result.execute({ response_path: "../outside.json", content: "[]" }).then(
  () => { throw new Error("writer accepted a path outside state") },
  () => undefined,
)

// Механічно захоплений результат канонічний: копія диригента його не перезаписує.
writeFileSync(join(directory, "state/batch/verdicts.json"), '[{"status":"PASS"}]\n')
const captured = await hooks.tool.translation_result.execute({ response_path: "batch/verdicts.json", content: '[{"status":"ЗІПСОВАНА КОПІЯ"}]' })
if (JSON.parse(captured.output).source !== "task-capture") throw new Error("writer did not report the captured source")
if (JSON.parse(readFileSync(join(directory, "state/batch/verdicts.json"), "utf8"))[0].status !== "PASS") throw new Error("model copy overwrote the captured result")

// Битий існуючий файл не є капчером: валідна копія диригента його замінює.
writeFileSync(join(directory, "state/batch/fixes.json"), "{broken\n")
await hooks.tool.translation_result.execute({ response_path: "batch/fixes.json", content: '[{"text":"Полагоджено"}]' })
if (JSON.parse(readFileSync(join(directory, "state/batch/fixes.json"), "utf8"))[0].text !== "Полагоджено") throw new Error("writer kept a broken stale file")

// Markdown-огорожа приймається: символи всередині не змінюються.
await hooks.tool.translation_result.execute({ response_path: "batch/fenced.json", content: '```json\n[{"text":"Огорожа"}]\n```' })
if (JSON.parse(readFileSync(join(directory, "state/batch/fenced.json"), "utf8"))[0].text !== "Огорожа") throw new Error("fenced JSON was rejected")

// Проза не зберігається, але помилка веде диригента назад у цикл, а не в
// зупинку, і сам факт лишається в журналі для виправлення на рівні проєкту.
await hooks.tool.translation_result.execute({ response_path: "batch/prose.json", content: "вибач, не вийшло" }).then(
  () => { throw new Error("writer accepted prose") },
  (error) => { if (!/run drive/.test(error.message)) throw new Error(`writer did not route the primary back to the flow: ${error.message}`) },
)
if (existsSync(join(directory, "state/batch/prose.json"))) throw new Error("prose was written to the response path")
const logged = readFileSync(join(directory, "state/flow-incidents.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line))
if (logged.at(-1).response_path !== "batch/prose.json") throw new Error("incident was not logged for the owner")

console.log("translation result writer: OK")
