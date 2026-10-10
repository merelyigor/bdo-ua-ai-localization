// >>> skill report-format: SessionStart-хук OpenCode (формат звіту зі skill); ставить і оновлює агент за references/hooks.md
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const SCRIPT = join(homedir(), ".config/opencode/skills/report-format/scripts/report_format_hook.py")

export const ReportFormatHook = async ({ $, directory, worktree }) => {
  // Текст для кожної головної сесії окремо: дочірні сесії (субагенти) його не отримують,
  // а повідомлення хука не зникає, коли скрипт запускається для іншої сесії.
  const contexts = new Map()
  const children = new Set()
  const run = async () => {
    if (!existsSync(SCRIPT)) return ""
    const out = await $`python3 ${SCRIPT} --client opencode --cwd ${worktree || directory}`.nothrow().quiet()
    return out.stdout.toString().trim()
  }
  return {
    event: async ({ event }) => {
      if (event.type !== "session.created") return
      const info = event.properties.info
      if (info.parentID) children.add(info.id)
      else contexts.set(info.id, await run())
    },
    "experimental.chat.system.transform": async (input, output) => {
      const id = input.sessionID
      if (!id || children.has(id)) return
      if (!contexts.has(id)) contexts.set(id, await run())
      const text = contexts.get(id)
      if (text) output.system.push(text)
    },
  }
}
// <<< skill report-format
