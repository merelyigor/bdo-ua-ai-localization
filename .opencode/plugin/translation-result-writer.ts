import { readFileSync } from "node:fs"
import { tool, type Plugin } from "@opencode-ai/plugin"
import { atomicWrite, clearIncident, recordIncident, stateFile, unwrapJson } from "../lib/child-response.ts"

/** Зберігає JSON, повернутий видимим native Task-дитям OpenCode. */
export const TranslationResultWriter: Plugin = async ({ directory }) => ({
  tool: {
    translation_result: tool({
      description: "Atomically save JSON returned by a visible native OpenCode Task child.",
      args: { response_path: tool.schema.string().min(1), content: tool.schema.string().min(2) },
      async execute(args) {
        const target = stateFile(directory, args.response_path)
        // Якщо translation-child-contract уже зберіг результат Task механічно,
        // канонічним є ВІН: копія диригента слугує лише підтвердженням і не має
        // права перезаписати захоплені байти своєю (можливо спотвореною) версією.
        let captured: string | undefined
        try {
          captured = readFileSync(target, "utf8")
          JSON.parse(captured)
        } catch {
          captured = undefined
        }
        if (captured !== undefined) {
          return {
            title: "Результат субагента вже збережено механічно",
            output: JSON.stringify({ ok: true, response_path: args.response_path, source: "task-capture" }),
          }
        }
        const json = unwrapJson(args.content)
        if (json === undefined) {
          // Дефект формату не є приводом зупинити прогін і не є приводом
          // «полагодити» відповідь у чаті: обидва шляхи вже коштували пачок.
          // Фіксуємо в журналі й повертаємо диригента до штатного циклу · саме
          // `./bdo run drive` перезапустить того самого child з уточненням.
          const attempt = recordIncident(
            directory,
            args.response_path,
            "primary-copy",
            "відповідь не є валідним JSON",
            args.content,
            new Date().toISOString(),
          )
          throw new Error(
            `Відповідь не є JSON (спроба ${attempt}). Не виправляй її сам: виконай ./bdo run drive · він перезапустить того самого child з уточненням.`,
          )
        }
        atomicWrite(target, json)
        clearIncident(directory, args.response_path)

        return { title: "Збережено результат видимого субагента", output: JSON.stringify({ ok: true, response_path: args.response_path }) }
      },
    }),
  },
})
