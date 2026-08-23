import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
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

console.log("translation result writer: OK")
