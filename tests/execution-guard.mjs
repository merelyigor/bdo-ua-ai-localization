import { TranslationExecutionGuard, bridgedCommand, shellBridge } from "../.opencode/plugin/translation-execution-guard.ts"
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { createHash } from "node:crypto"
import { tmpdir } from "node:os"
import { join } from "node:path"

const roles = ["translation-terminology", "translation-worker", "translation-qa", "translation-repair", "translation-judge", "translation-smoke"]
const runtimeState = (active_profile = "session-free", model = "opencode/x-preview-f-free") => {
  const routes = Object.fromEntries(roles.map((role) => [role, [model]]))
  const canonical = JSON.stringify({ schema_version: 1, active_profile, routes })
  return {
    schema_version: 1,
    active_profile,
    routes,
    fingerprint: createHash("sha256").update(canonical).digest("hex"),
    generated_at: "2026-08-24T00:00:00Z",
  }
}
const writeRuntime = (directory, state) => {
  writeFileSync(join(directory, ".opencode/runtime-model-state.json"), JSON.stringify(state))
  writeFileSync(join(directory, ".opencode/translation-models.json"), JSON.stringify({
    active_profile: state.active_profile,
    profiles: { [state.active_profile]: { routes: state.routes } },
  }))
}
const makeGuard = async (directory = mkdtempSync(join(tmpdir(), "bdo-execution-guard-")), seed = true) => {
  mkdirSync(join(directory, ".opencode"), { recursive: true })
  if (seed) {
    // Fingerprint мусить відповідати канонічному effective policy.
    const state = runtimeState()
    writeRuntime(directory, state)
  }
  const aborted = []
  const hooks = await TranslationExecutionGuard({
    directory,
    client: { session: { abort: async ({ path }) => { aborted.push(path.id) } } },
  })
  return { before: hooks["tool.execute.before"], aborted, directory }
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
  const { before, aborted, directory } = await makeGuard()
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
    "./bdo gate full",
    "./bdo run end",
    "./bdo batch end",
    "./bdo schema clear",
    "./bdo clean",
    "./bdo clean --days 14",
    "./bdo clean --days 14 --apply",
    "./bdo incidents --clear",
    "./bdo judge --clear",
    // Довідкові, тільки читання: без них диригент не міг відповісти навіть на
    // «де є що перекладати», хоча жодного запису в цих командах немає.
    "./bdo patches",
    "./bdo patches 5",
    "./bdo patches all machine",
    "./bdo patches 5 manual --full",
    "./bdo patch 3",
    "./bdo profile status",
    "./bdo audit",
    "./bdo incidents --list",
    "./bdo judge",
    "./bdo moderation --limit 100",
    "./bdo moderation --approve 265,266,267",
    "./bdo env && ./bdo patches",
  ]) {
    const output = { args: { command, workdir: "/stale/renamed-project" } }
    await before({ tool: "bash", sessionID: "ok", callID: "c" }, output)
    if (output.args.workdir !== directory) throw new Error("guard did not canonicalize a stale workdir")
  }
  await before({ tool: "task", sessionID: "ok", callID: "c" }, { args: { subagent_type: "translation-worker" } })
  await before({ tool: "read", sessionID: "ok", callID: "c" }, { args: { filePath: "state/payload.json" } })
  await before({ tool: "translation_result", sessionID: "ok", callID: "c" }, { args: { response_path: "smoke/response.json", content: "[]" } })
  if (aborted.length !== 0) throw new Error("guard aborted a legal session")
}

// Model runtime restart-gate: Task дозволений лише з fingerprint, який OpenCode
// бачив під час старту plugin instance.
{
  const { before, directory } = await makeGuard()
  await before({ tool: "task", sessionID: "same", callID: "c" }, { args: { subagent_type: "translation-worker" } })
  const stateFile = join(directory, ".opencode/runtime-model-state.json")
  const same = JSON.parse(readFileSync(stateFile, "utf8"))
  writeRuntime(directory, { ...same, generated_at: "later" })
  await before({ tool: "task", sessionID: "same-metadata", callID: "c" }, { args: { subagent_type: "translation-qa" } })
  const changed = runtimeState("local-quality", "ollama-local/qwen3.6:35b-a3b-mtp-q4_K_M")
  writeRuntime(directory, changed)
  let restart = ""
  await before({ tool: "task", sessionID: "changed", callID: "c" }, { args: { subagent_type: "translation-worker" } })
    .catch((error) => { restart = String(error) })
  if (!restart.includes("OPENCODE_RESTART_REQUIRED") || !restart.includes("session-free -> local-quality")) {
    throw new Error(`changed model runtime was not blocked clearly: ${restart}`)
  }
  const restarted = await makeGuard(directory, false)
  await restarted.before({ tool: "task", sessionID: "restarted", callID: "c" }, { args: { subagent_type: "translation-worker" } })
}

// Prompt/CLI restart-gate: стара primary-сесія не має виконувати workflow після
// git pull або генерації нових інструкцій.
{
  const { before, directory } = await makeGuard()
  const output = { args: { command: "./bdo env" } }
  await before({ tool: "bash", sessionID: "workflow-same", callID: "c" }, output)
  mkdirSync(join(directory, ".opencode/agents"), { recursive: true })
  writeFileSync(join(directory, ".opencode/agents/патч.md"), "changed prompt")
  let restart = ""
  await before(
    { tool: "bash", sessionID: "workflow-changed", callID: "c" },
    { args: { command: "./bdo env" } },
  ).catch((error) => { restart = String(error) })
  if (!restart.includes("OPENCODE_RESTART_REQUIRED") || !restart.includes("workflow змінився")) {
    throw new Error(`changed primary workflow was not blocked clearly: ${restart}`)
  }
}

// Відсутній fingerprint при boot · fail closed до створення child.
{
  const { before } = await makeGuard(undefined, false)
  let invalid = ""
  await before({ tool: "task", sessionID: "missing", callID: "c" }, { args: { subagent_type: "translation-worker" } })
    .catch((error) => { invalid = String(error) })
  if (!invalid.includes("OPENCODE_RUNTIME_INVALID")) throw new Error(`missing runtime was accepted: ${invalid}`)
}

// State не може маскувати частково змінений policy або активну матеріалізацію.
{
  const { before, directory } = await makeGuard()
  const policyFile = join(directory, ".opencode/translation-models.json")
  const policy = JSON.parse(readFileSync(policyFile, "utf8"))
  policy.profiles[policy.active_profile].routes["translation-worker"] = ["other/model"]
  writeFileSync(policyFile, JSON.stringify(policy))
  let mismatch = ""
  await before({ tool: "task", sessionID: "mismatch", callID: "c" }, { args: { subagent_type: "translation-worker" } })
    .catch((error) => { mismatch = String(error) })
  if (!mismatch.includes("OPENCODE_RUNTIME_INVALID")) throw new Error(`policy mismatch was accepted: ${mismatch}`)

  writeRuntime(directory, runtimeState())
  writeFileSync(join(directory, ".opencode/runtime-model-state.busy"), "123")
  let busy = ""
  await before({ tool: "task", sessionID: "busy", callID: "c" }, { args: { subagent_type: "translation-worker" } })
    .catch((error) => { busy = String(error) })
  if (!busy.includes("OPENCODE_RUNTIME_INVALID")) throw new Error(`busy runtime was accepted: ${busy}`)
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
    "docker exec bdo-php php artisan tinker",
    "php artisan tinker",
    "cd ../server && php artisan test",
    "rg patch /external/server-project",
    "true",
    "./bdo run drive > /tmp/out.json",
    "./bdo env && $(echo ./bdo smoke)",
    // Мутуючі близнюки дозволених довідкових команд: читати можна, змінювати · ні.
    "./bdo profile use session-luna",
    "./bdo moderation --approve-batch 12",
    "./bdo moderation --approve 12,",
    "./bdo moderation --reject 12",
    "./bdo fetch 15",
    "./bdo patches 0",
    "./bdo patches 5 machine --apply",
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

// Windows-міст. Модель і далі пише `./bdo ...`; у WSL іде вже перевірений рядок.
{
  const directory = mkdtempSync(join(tmpdir(), "bdo-bridge-"))
  if (shellBridge(directory, "win32") !== "wsl") throw new Error("bridge is off on native Windows")
  // OpenCode, запущений УСЕРЕДИНІ WSL, бачить linux · подвійного `wsl` не буває.
  for (const platform of ["darwin", "linux"]) {
    if (shellBridge(directory, platform) !== "off") throw new Error(`bridge leaked onto ${platform}`)
  }
  writeFileSync(join(directory, ".env"), "BDO_ENV=DEV\nBDO_SHELL_BRIDGE=off  # аварійний вихід\n")
  if (shellBridge(directory, "win32") !== "off") throw new Error("BDO_SHELL_BRIDGE=off ignored")
  writeFileSync(join(directory, ".env"), "BDO_SHELL_BRIDGE=wsl\n")
  if (shellBridge(directory, "darwin") !== "wsl") throw new Error("explicit bridge ignored")
  writeFileSync(join(directory, ".env"), "BDO_SHELL_BRIDGE=powershell\n")
  let invalid = ""
  try { shellBridge(directory, "win32") } catch (error) { invalid = String(error) }
  if (!invalid.includes("auto|wsl|off")) throw new Error(`invalid bridge accepted: ${invalid}`)

  const windows = "C:\\Users\\owner\\GitHub\\bdo-ua-ai-localization"
  const bridged = bridgedCommand("./bdo env && ./bdo smoke", windows, "wsl")
  if (bridged !== `wsl.exe --cd "${windows}" bash -lc "./bdo env && ./bdo smoke"`) {
    throw new Error(`unexpected bridged command: ${bridged}`)
  }
  if (bridgedCommand("./bdo env", "/home/owner/GitHub/x", "off") !== "./bdo env") {
    throw new Error("bridge rewrote a command with bridging disabled")
  }
}

// Міст працює ПІСЛЯ whitelist: заборонена команда не отримує обгортки WSL.
{
  const directory = mkdtempSync(join(tmpdir(), "bdo-bridge-guard-"))
  writeFileSync(join(directory, ".env"), "BDO_SHELL_BRIDGE=wsl\n")
  const { before } = await makeGuard(directory)
  const output = { args: { command: "./bdo run drive" } }
  await before({ tool: "bash", sessionID: "bridge", callID: "c" }, output)
  if (!output.args.command.startsWith("wsl.exe --cd ")) throw new Error("guard did not bridge an allowed command")
  if (!output.args.command.endsWith('bash -lc "./bdo run drive"')) throw new Error("guard bridged the wrong payload")
  await refuse(before, { tool: "bash", sessionID: "bridge-bad", callID: "c" }, { command: "curl http://127.0.0.1:8010" }, "bridged bypass")
}

console.log("translation execution guard: OK")
