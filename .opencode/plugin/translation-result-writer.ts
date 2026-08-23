import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, isAbsolute, relative, resolve, sep } from "node:path"
import { tool, type Plugin } from "@opencode-ai/plugin"

function stateFile(directory: string, path: string): string {
  const root = resolve(directory, "state")
  const absolute = isAbsolute(path) ? resolve(path) : resolve(root, path)
  const rel = relative(root, absolute)
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`)) throw new Error("Response path must be below project state/.")
  return absolute
}

function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp.${crypto.randomUUID()}`
  writeFileSync(temporary, `${content.trim()}\n`)
  renameSync(temporary, path)
}

/** Saves JSON returned by a native, visible OpenCode Task child. */
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
        JSON.parse(args.content)
        atomicWrite(target, args.content)
        return { title: "Збережено результат видимого субагента", output: JSON.stringify({ ok: true, response_path: args.response_path }) }
      },
    }),
  },
})
