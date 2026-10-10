// Формат звіту: звірка блоку правил (skill report-format).
// Агент кладе цей файл у <проєкт>/.opencode/plugins/report-format.js за розділом
// «Хуки проєкту» skill report-format; хук лише оновлює наявний блок.
import { existsSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const SCRIPT = join(homedir(), ".config/opencode/skills/report-format/scripts/report_format_hook.py")

export const ReportFormatHook = async ({ $, directory, worktree }) => {
  // null — скрипт у цій сесії ще не запускався; текст лишається до наступної сесії,
  // щоб повідомлення про оновлення блоку не зникло після першого запиту.
  let context = null
  const refresh = async () => {
    context = ""
    if (!existsSync(SCRIPT)) return
    const out = await $`python3 ${SCRIPT} --client opencode --cwd ${worktree || directory}`.nothrow().quiet()
    context = out.stdout.toString().trim()
  }
  return {
    event: async ({ event }) => {
      if (event.type === "session.created") await refresh()
    },
    "experimental.chat.system.transform": async (_input, output) => {
      if (context === null) await refresh()
      if (context) output.system.push(context)
    },
  }
}
