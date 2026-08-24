import { TranslationExecutionGuard } from "../.opencode/plugin/translation-execution-guard.ts"

const makeGuard = async () => {
  const aborted = []
  const hooks = await TranslationExecutionGuard({
    directory: "/project",
    client: { session: { abort: async ({ path }) => { aborted.push(path.id) } } },
  })
  return { before: hooks["tool.execute.before"], aborted }
}
const refuse = async (before, input, args, what) => {
  await before(input, { args }).then(
    () => { throw new Error(`guard accepted ${what}`) },
    () => undefined,
  )
}

// Дозволені команди, зокрема послідовність через `&&`: диригент обʼєднує сусідні
// кроки промпта в один виклик, і за це прогін падав п'ять разів за день.
{
  const { before, aborted } = await makeGuard()
  for (const command of [
    "./bdo env",
    "./bdo mode start patch",
    "./bdo mode start manual 15",
    "./bdo run drive",
    "./bdo smoke",
    "./bdo env && ./bdo smoke",
    "./bdo env&&./bdo mode status patch",
    "./bdo mode start improve 20 && ./bdo run drive",
    "./bdo mode start patch 15 3",
    "./bdo mode status patch 3",
    // Довідкові, тільки читання: без них диригент не міг відповісти навіть на
    // «де є що перекладати», хоча жодного запису в цих командах немає.
    "./bdo patches",
    "./bdo patches 5",
    "./bdo patch 3",
    "./bdo profile status",
    "./bdo audit",
    "./bdo incidents --list",
    "./bdo judge",
    "./bdo moderation --limit 100",
    "./bdo env && ./bdo patches",
  ]) {
    await before({ tool: "bash", sessionID: "ok", callID: "c" }, { args: { command } })
  }
  await before({ tool: "task", sessionID: "ok", callID: "c" }, { args: { subagent_type: "translation-worker" } })
  await before({ tool: "read", sessionID: "ok", callID: "c" }, { args: { filePath: "state/payload.json" } })
  await before({ tool: "translation_result", sessionID: "ok", callID: "c" }, { args: { response_path: "smoke/response.json", content: "[]" } })
  if (aborted.length !== 0) throw new Error("guard aborted a legal session")
}

// Обхід лишається забороненим: розділювач `&&` не легалізує ані чужий бінарник,
// ані pipes, ані підстановки · сегмент просто не збігається з переліком.
{
  const { before } = await makeGuard()
  for (const command of [
    "opencode run --agent translation-worker",
    "curl http://127.0.0.1:8010",
    "./bdo run drive; opencode run",
    "./bdo run drive | sh",
    "./bdo run drive\nopencode run",
    "node spawn-agent.mjs",
    "./bdo env && curl http://127.0.0.1:8010",
    "./bdo env && rm -rf state",
    "true",
    "./bdo run drive > /tmp/out.json",
    "./bdo env && $(echo ./bdo smoke)",
    // Мутуючі близнюки дозволених довідкових команд: читати можна, змінювати · ні.
    "./bdo incidents --clear",
    "./bdo judge --clear",
    "./bdo clean --apply",
    "./bdo profile use session-luna",
    "./bdo moderation --approve 12",
    "./bdo run end",
    "./bdo fetch 15",
    "./bdo patches 0",
  ]) {
    // Кожне порушення в СВОЇЙ сесії: інакше спрацював би лічильник abort.
    await refuse(before, { tool: "bash", sessionID: `s-${command}`, callID: "c" }, { command }, `forbidden command: ${command}`)
  }
  for (const tool of ["list_mcp_resources", "list_mcp_resource_templates", "serena_execute_shell_command", "webfetch", "write", "edit"]) {
    await refuse(before, { tool, sessionID: `t-${tool}`, callID: "c" }, {}, `forbidden tool: ${tool}`)
  }
}

// Перше порушення НЕ вбиває сесію: виклик і так не виконується, а модель має
// шанс виправитись. Abort лишається для наполегливого обходу.
{
  const { before, aborted } = await makeGuard()
  await refuse(before, { tool: "bash", sessionID: "loop", callID: "c" }, { command: "true" }, "first violation")
  if (aborted.length !== 0) throw new Error("guard aborted on the first violation")
  await refuse(before, { tool: "bash", sessionID: "loop", callID: "c" }, { command: "true" }, "second violation")
  if (aborted.length !== 0) throw new Error("guard aborted on the second violation")
  await refuse(before, { tool: "bash", sessionID: "loop", callID: "c" }, { command: "opencode run" }, "third violation")
  if (aborted.length !== 1 || aborted[0] !== "loop") throw new Error("guard did not abort a persistent bypass")
  // Лічильник посесійний: чужа сесія не успадковує чужі порушення.
  await refuse(before, { tool: "bash", sessionID: "other", callID: "c" }, { command: "true" }, "violation in another session")
  if (aborted.length !== 1) throw new Error("violation counter leaked across sessions")
}

console.log("translation execution guard: OK")
