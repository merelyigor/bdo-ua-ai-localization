import type { Plugin } from "@opencode-ai/plugin"
import { createHash } from "node:crypto"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { readRuntimeModelState } from "../lib/runtime-model-state.ts"

// OpenCode завантажує prompt і plugin один раз на старті. Після git pull стара
// сесія інакше продовжує виконувати вже видалені команди/прапорці: саме так
// primary просив `--end`, хоча run-start уже автоматично закривав terminal lock.
// Перелік навмисно ширший за «promptи диригента».
//
// 2026-08-27 сюди не входили ні `build-schema.sh`, ні плагіни, ні дитячі
// промпти · і власник півгодини ганяв пачку на ВИПРАВЛЕНОМУ коді, який стара
// сесія не бачила: OpenCode вантажить це один раз на старті. Пʼять порожніх
// child поспіль, і жодного натяку, що треба перезапустити OpenCode.
// Правило просте: якщо файл впливає на те, ЩО отримає child, він тут.
const WORKFLOW_FILES = [
  "bdo",
  "cli/run/run-start.sh",
  "cli/run/run-mode.sh",
  "cli/run/run-drive.sh",
  "cli/command-registry.json",
  "cli/prepare/build-schema.sh",
  "cli/prepare/worker-payload.sh",
  "cli/runtime/prepare-smoke.sh",
  ".opencode/plugin/translation-execution-guard.ts",
  ".opencode/plugin/translation-routing-guard.ts",
  ".opencode/plugin/translation-child-contract.ts",
  ".opencode/plugin/translation-result-writer.ts",
  ".opencode/lib/child-response.ts",
  ".opencode/agents/патч.md",
  ".opencode/agents/ручний.md",
  ".opencode/agents/пропозиції.md",
  ".opencode/agents/покращення-ші.md",
  ".opencode/agents/translation-worker.md",
  ".opencode/agents/translation-qa.md",
  ".opencode/agents/translation-repair.md",
  ".opencode/agents/translation-terminology.md",
  ".opencode/agents/translation-judge.md",
  ".opencode/agents/translation-smoke.md",
]

function workflowFingerprint(directory: string): string {
  const hash = createHash("sha256")
  for (const relative of WORKFLOW_FILES) {
    hash.update(relative).update("\0")
    try {
      hash.update(readFileSync(join(directory, relative)))
    } catch {
      hash.update("<missing>")
    }
    hash.update("\0")
  }
  return hash.digest("hex")
}

type CommandRegistry = { guard_patterns?: unknown }

// Реєстр є єдиним джерелом allowlist. Помилка/відсутність реєстру блокує shell
// повністю: краще зупинити прогін, ніж непомітно розширити доступ.
function registryPatterns(directory: string): RegExp[] {
  let registry: CommandRegistry
  try {
    registry = JSON.parse(
      readFileSync(join(directory, "cli/command-registry.json"), "utf8"),
    ) as CommandRegistry
  } catch (cause) {
    const detail = cause instanceof Error ? cause.message : String(cause)
    throw new Error(`OPENCODE_COMMAND_REGISTRY_INVALID: ${detail}`)
  }
  if (!Array.isArray(registry.guard_patterns) || !registry.guard_patterns.every((pattern) => typeof pattern === "string")) {
    throw new Error("OPENCODE_COMMAND_REGISTRY_INVALID: guard_patterns must be an array of strings")
  }
  return registry.guard_patterns.map((pattern) => new RegExp(pattern))
}
// `glob`, `grep` і `list` є ЧИТАННЯМ, і саме тому вони тут.
//
// Guard існує проти прихованих агентів і shell-обходів. Пошук файла ні того, ні
// іншого не дає: він нічого не запускає, нічого не пише і не створює сесій. Без
// них диригент не міг навіть подивитись, чи існує тека пачки, і на кожній
// дрібниці впирався у власника · при тому, що `read` йому вже дозволений, тобто
// заборона обмежувала не доступ, а здатність його СПРЯМУВАТИ. Небезпечні
// лишаються поза списком: `edit`, `write`, `patch`, `webfetch`, `websearch`,
// будь-який MCP і будь-який спосіб запустити процес поза `./bdo`.
const SAFE_TOOLS = new Set(["bash", "read", "glob", "grep", "list", "task", "translation_result"])

// Послідовність дозволених команд через `&&` приймається як одна.
//
// Причина не в зручності. Диригент природно обʼєднує два сусідні кроки промпта
// (`./bdo env` -> `./bdo smoke`) в один виклик, і за це прогін падав із
// «Tool execution aborted»: 5 аварій за день, усі на тому самому нешкідливому
// `./bdo env && ./bdo smoke`. Ізоляція від цього не слабшає · кожен сегмент
// звіряється з тим самим коротким переліком точних команд, а `&&` є єдиним
// дозволеним розділювачем: pipes, `;`, підстановки й перенаправлення лишаються
// поза законом, бо після розділення такий сегмент просто не збігається.
function allowedShell(command: string, patterns: RegExp[]): boolean {
  const parts = command.split("&&").map((part) => part.trim())
  return parts.length > 0 && parts.every((part) => patterns.some((pattern) => pattern.test(part)))
}

// Порушення більше не вбиває сесію з першого разу.
//
// Раніше guard одразу робив `session.abort()`, і будь-яка помилка формулювання
// перетворювалась на мертву сесію. Але сам виклик і так НЕ виконується: guard
// кидає помилку до виконання. Тому перші спроби отримують зрозумілу відмову, з
// якої модель може виправитись, а abort лишається для наполегливого обходу.
// Windows-міст: native OpenCode поза WSL не має bash, і `./bdo` там не
// запускається. Дозволена команда виконується всередині WSL2.
//
// Перепис відбувається ПІСЛЯ whitelist і НЕ розширює доступ: у WSL іде рівно той
// рядок, який щойно збігся з переліком точних `./bdo` команд. Модель цього кроку
// не бачить і не може ним керувати · вона й далі пише `./bdo env`, тому промпти,
// документація й сам перелік лишаються однакові на всіх платформах. Саме тому
// міст живе тут, а не в промпті: промпт можна вмовити, перевірку в коді · ні.
//
// `wsl --cd` приймає Windows-шлях і сам транслює його в `/mnt/...`, тож ні
// `wslpath`, ні вкладені підстановки не потрібні. Подвійні лапки безпечні: усі
// дозволені команди складаються лише з літер, цифр, пробілу та `/ . - , &`,
// тому власних лапок у рядку не буває.
export function bridgedCommand(command: string, directory: string, bridge: string): string {
  if (bridge !== "wsl") return command
  return `wsl.exe --cd "${directory}" bash -lc "${command}"`
}

/**
 * Який міст застосувати до shell-команд цієї сесії.
 *
 * За замовчуванням `auto`: на Windows · WSL, будь-де інакше · без моста. Коли
 * OpenCode запущений УСЕРЕДИНІ WSL, платформа вже `linux`, тож міст сам не
 * вмикається й подвійного `wsl` не буває. `BDO_SHELL_BRIDGE=off` у `.env`
 * лишає аварійний вихід на випадок іншого Windows-runtime.
 */
export function shellBridge(directory: string, platform: string): string {
  const file = process.env.TRANSLATE_ENV_FILE || join(directory, ".env")
  let raw: string | undefined
  try {
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const match = /^\s*(?:export\s+)?BDO_SHELL_BRIDGE\s*=\s*(.*)$/.exec(line)
      if (match) raw = match[1]
    }
  } catch {
    raw = undefined
  }
  const value = (raw ?? process.env.BDO_SHELL_BRIDGE ?? "auto")
    .trim()
    .replace(/^["']|["']$/g, "")
    .split("#")[0]
    .trim()
    .toLowerCase()
  if (value === "" || value === "auto") return platform === "win32" ? "wsl" : "off"
  if (value !== "off" && value !== "wsl") {
    throw new Error(`BDO_SHELL_BRIDGE="${value}" is not one of auto|wsl|off.`)
  }
  return value
}

const ABORT_AFTER_VIOLATIONS = 3
const ALLOWED_HINT = [
  "середовище: ./bdo platform [--fix] | ./bdo env | ./bdo gate preflight",
  "прогін: ./bdo smoke | ./bdo mode status <mode> [patch]",
  "./bdo mode start <mode> [N] [patch] | ./bdo run drive | ./bdo run show",
  "перевірка: ./bdo gate preflight|docs|shell|agents|runtime|api|full && ./bdo api",
  "довідка (тільки читання): ./bdo patches [N|all] [machine|manual|both] [--full]",
  "./bdo patch [N] | ./bdo profile status",
  "./bdo incidents [--list] | ./bdo judge [--list] | ./bdo quarantine [--list] | ./bdo moderation [--limit N]",
  "./bdo paths | ./bdo platform | ./bdo models | ./bdo api | ./bdo runtime | ./bdo help",
  "кілька команд можна поєднати через &&",
].join(" · ")

/**
 * Підказка для випадку, коли виклик `task` навіть не розібрався як JSON.
 *
 * 2026-08-27, сесія власника: диригент утретє вклав увесь worker-payload у
 * аргумент `prompt`, рядок не закрився, і OpenCode подав це синтетичним
 * інструментом `invalid` з текстом «JSON parsing failed». Guard відповідав
 * загальним «Tool invalid is unavailable», тобто диригент чув «не той
 * інструмент», хоча інструмент був той · зламані були аргументи. Він повторював
 * ту саму помилку, доки прогін не став.
 *
 * Перевірка форми `prompt` у `translation-child-contract` цього не ловить: до
 * hook справа не доходить, бо аргументи не розібрались. Єдине місце, де випадок
 * ще видно, · саме тут, тому тут і має бути точна причина з готовим рядком.
 */
export function unparsableTaskHint(directory: string): string {
  let reference = "payload:<шлях із state/next-child.json>"
  try {
    const next = JSON.parse(readFileSync(join(directory, "state/next-child.json"), "utf8")) as { payload_path?: string }
    if (typeof next.payload_path === "string" && next.payload_path !== "") {
      reference = `payload:${next.payload_path}`
    }
  } catch {
    // Немає envelope · лишається загальна форма: вона однаково правильна.
  }

  return (
    "Виклик task не розібрався як JSON: у `prompt` потрапив увесь payload. "
    + `Передай РІВНО \`${reference}\` і більше нічого · вміст підставить плагін. `
    + "Повтори Task один раз із цим рядком."
  )
}

/** Закриває всі shell/API/CLI шляхи, якими можна створити невидимого агента. */
export const TranslationExecutionGuard: Plugin = async ({ client, directory }) => {
  const safeBdoCommands = registryPatterns(directory)
  const bootWorkflowFingerprint = workflowFingerprint(directory)
  // Один раз на старті: помилкове значення має впасти зараз, а не посеред пачки.
  const bridge = shellBridge(directory, process.platform)
  let bootState: ReturnType<typeof readRuntimeModelState> | undefined
  let bootError: string | undefined
  try {
    bootState = readRuntimeModelState(directory)
  } catch (error) {
    bootError = error instanceof Error ? error.message : String(error)
  }
  const violations = new Map<string, number>()
  const refuse = async (sessionID: string, message: string): Promise<never> => {
    const count = (violations.get(sessionID) ?? 0) + 1
    violations.set(sessionID, count)
    if (count >= ABORT_AFTER_VIOLATIONS) {
      await client.session.abort({ path: { id: sessionID }, query: { directory } }).catch(() => undefined)
      throw new Error(`${message} Сесію зупинено після ${count} порушень поспіль.`)
    }
    throw new Error(message)
  }

  return {
    "tool.execute.before": async (input, output) => {
      if (!SAFE_TOOLS.has(input.tool)) {
        // `invalid` не є спробою взяти чужий інструмент: так OpenCode подає
        // виклик, аргументи якого не розібрались. Загальна відмова тут читалась
        // як «не той інструмент» і заганяла диригента в цикл.
        const attempted = String((output.args as Record<string, unknown> | undefined)?.tool ?? "")
        const detail = String((output.args as Record<string, unknown> | undefined)?.error ?? "")
        if (input.tool === "invalid" && (attempted === "task" || /tool task/.test(detail))) {
          await refuse(input.sessionID, unparsableTaskHint(directory))
        }
        await refuse(
          input.sessionID,
          `Tool ${input.tool} is unavailable in translation primary. Use native OpenCode task for subagents.`,
        )
      }
      if (input.tool === "task" && /^translation-/.test(String(output.args?.subagent_type ?? ""))) {
        if (!bootState) {
          throw new Error(bootError ?? "OPENCODE_RUNTIME_INVALID: OpenCode started without a valid model runtime.")
        }
        const current = readRuntimeModelState(directory)
        if (current.fingerprint !== bootState.fingerprint) {
          throw new Error(
            `OPENCODE_RESTART_REQUIRED: child profile changed ${bootState.active_profile} -> ${current.active_profile}. `
            + "Перезапустіть OpenCode і напишіть «продовжуй»; незавершену пачку збережено.",
          )
        }
      }
      if (input.tool !== "bash") return
      if (workflowFingerprint(directory) !== bootWorkflowFingerprint) {
        throw new Error(
          "OPENCODE_RESTART_REQUIRED: primary prompt або ./bdo workflow змінився після старту сесії. "
          + "Перезапустіть OpenCode і повторіть запит; незавершену пачку збережено.",
        )
      }
      const command = typeof output.args?.command === "string" ? output.args.command.trim() : ""
      if (!allowedShell(command, safeBdoCommands)) {
        await refuse(
          input.sessionID,
          `Translation primary shell is restricted to the fixed ./bdo workflow. Дозволено: ${ALLOWED_HINT}.`,
        )
      }
      // OpenCode уже знає фактичний корінь проєкту, а модель інколи повторює
      // старий абсолютний workdir після перейменування теки. Дозволені тут лише
      // точні ./bdo-команди, тому канонічний cwd не розширює доступ, зате не дає
      // успішній пачці впасти на фінальному кроці через вигаданий шлях.
      output.args.workdir = directory
      output.args.command = bridgedCommand(command, directory, bridge)
    },
  }
}

// OpenCode 1.18.x: path plugins must use the V1 module shape. Without this
// default export every named function is treated as a legacy plugin entry.
export default {
  id: "translation-execution-guard",
  server: TranslationExecutionGuard,
}
