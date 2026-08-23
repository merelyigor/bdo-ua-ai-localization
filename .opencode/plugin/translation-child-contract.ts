import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, isAbsolute, relative, resolve, sep } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"

const ROLES = new Set([
  "translation-terminology",
  "translation-worker",
  "translation-qa",
  "translation-repair",
  "translation-smoke",
])

type ChildEnvelope = { kind?: string; role?: string; payload_path?: string; response_path?: string }

// Обидва шляхи envelope зобовʼязані жити під state/: payload читається в prompt,
// response пишеться атомарно, і жоден із них не має права вийти за межі проєкту.
function stateFile(directory: string, path: string): string {
  const root = resolve(directory, "state")
  const absolute = isAbsolute(path) ? resolve(path) : resolve(root, path)
  const rel = relative(root, absolute)
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`)) throw new Error("Child contract path must be below project state/.")
  return absolute
}

function envelope(directory: string): ChildEnvelope | undefined {
  try {
    return JSON.parse(readFileSync(resolve(directory, "state/next-child.json"), "utf8")) as ChildEnvelope
  } catch {
    return undefined
  }
}

function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp.${crypto.randomUUID()}`
  writeFileSync(temporary, `${content.trim()}\n`)
  renameSync(temporary, path)
}

/**
 * Механічний child-контракт для native Task.
 *
 * Слабка модель-диригент не є надійним носієм байтів: копія payload з read-виводу
 * може принести префікси рядків або обрізання, а позиційна схема тоді ЗМУШУЄ
 * child галюцинувати переклади рядків, яких він не бачив. Тому:
 *  - before: prompt Task для translation-* ролі замінюється точним вмістом
 *    staged payload з envelope (state/next-child.json);
 *  - after: JSON-результат Task зберігається у response_path механічно, і
 *    translation_result підтверджує саме його, а не копію диригента.
 */
export const TranslationChildContract: Plugin = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool !== "task") return
    const role = typeof output.args?.subagent_type === "string" ? output.args.subagent_type : ""
    if (!ROLES.has(role)) return
    const next = envelope(directory)
    if (!next || next.kind !== "child" || !next.payload_path || !next.response_path) {
      // Ручний `@translation-smoke` без envelope легальний: його відповідь
      // однаково обмежена вбудованою smoke-схемою і нічого не пише.
      if (role === "translation-smoke") return
      throw new Error(`Немає staged child envelope для ${role}: спочатку ./bdo run drive або ./bdo smoke.`)
    }
    if (next.role !== role) {
      throw new Error(`Staged envelope чекає ${next.role}; Task викликає ${role}.`)
    }
    output.args.prompt = readFileSync(stateFile(directory, next.payload_path), "utf8").trim()
  },
  "tool.execute.after": async (input, output) => {
    if (input.tool !== "task" || !output) return
    const role = typeof input.args?.subagent_type === "string" ? input.args.subagent_type : ""
    if (!ROLES.has(role)) return
    const next = envelope(directory)
    if (!next || next.kind !== "child" || next.role !== role || !next.response_path) return
    const text = typeof output.output === "string" ? output.output : ""
    // TaskTool загортає відповідь child у <task_result>…</task_result>; зняття
    // обгортки детерміноване. Зберігається лише те, що є валідним JSON · прозу
    // або task_error лишаємо диригентові, який мусить зупинитись.
    const match = text.match(/<task_result>\n?([\s\S]*?)\n?<\/task_result>/)
    if (!match) return
    const content = match[1].trim()
    try {
      JSON.parse(content)
    } catch {
      return
    }
    atomicWrite(stateFile(directory, next.response_path), content)
  },
})
