import type { Plugin } from "@opencode-ai/plugin"

const SAFE_BDO_COMMANDS = [
  /^\.\/bdo env$/,
  /^\.\/bdo smoke$/,
  /^\.\/bdo mode status (patch|manual|proposal|improve)$/,
  /^\.\/bdo mode start (patch|manual|proposal|improve)( [1-9][0-9]*)?$/,
  /^\.\/bdo run drive$/,
]
const SAFE_TOOLS = new Set(["bash", "read", "task", "translation_result"])

/** Prevents every shell/API/CLI route that could create an invisible agent. */
export const TranslationExecutionGuard: Plugin = async ({ client, directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (!SAFE_TOOLS.has(input.tool)) {
      await client.session.abort({ path: { id: input.sessionID }, query: { directory } }).catch(() => undefined)
      throw new Error(`Tool ${input.tool} is unavailable in translation primary. Use native OpenCode task for subagents.`)
    }
    if (input.tool !== "bash") return
    const command = typeof output.args?.command === "string" ? output.args.command.trim() : ""
    if (!SAFE_BDO_COMMANDS.some((pattern) => pattern.test(command))) {
      await client.session.abort({ path: { id: input.sessionID }, query: { directory } }).catch(() => undefined)
      throw new Error("Translation primary shell is restricted to the fixed ./bdo workflow. Use native OpenCode task for every subagent.")
    }
  },
})
