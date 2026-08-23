import { TranslationExecutionGuard } from "../.opencode/plugin/translation-execution-guard.ts"

const aborted = []
const hooks = await TranslationExecutionGuard({
  directory: "/project",
  client: { session: { abort: async ({ path }) => { aborted.push(path.id) } } },
})
const before = hooks["tool.execute.before"]
for (const command of ["./bdo env", "./bdo mode start patch", "./bdo mode start manual 15", "./bdo run drive", "./bdo smoke"]) {
  await before({ tool: "bash", sessionID: "test", callID: "test" }, { args: { command } })
}
for (const command of [
  "opencode run --agent translation-worker",
  "curl http://127.0.0.1:8010",
  "./bdo run drive; opencode run",
  "./bdo run drive | sh",
  "./bdo run drive\nopencode run",
  "node spawn-agent.mjs",
]) {
  await before({ tool: "bash", sessionID: "test", callID: "test" }, { args: { command } }).then(
    () => { throw new Error(`guard accepted forbidden command: ${command}`) },
    () => undefined,
  )
}
await before({ tool: "task", sessionID: "test", callID: "test" }, { args: { subagent_type: "translation-worker" } })
await before({ tool: "read", sessionID: "test", callID: "test" }, { args: { filePath: "state/payload.json" } })
await before({ tool: "translation_result", sessionID: "test", callID: "test" }, { args: { response_path: "smoke/response.json", content: "[]" } })
for (const tool of ["list_mcp_resources", "list_mcp_resource_templates", "serena_execute_shell_command", "webfetch", "write", "edit"]) {
  await before({ tool, sessionID: "test", callID: "test" }, { args: {} }).then(
    () => { throw new Error(`guard accepted forbidden tool: ${tool}`) },
    () => undefined,
  )
}
if (aborted.length !== 12) throw new Error(`expected 12 aborted violations, got ${aborted.length}`)
console.log("translation execution guard: OK")
