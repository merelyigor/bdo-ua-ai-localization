import { mkdtempSync, mkdirSync, readFileSync } from "node:fs"
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
console.log("translation result writer: OK")
