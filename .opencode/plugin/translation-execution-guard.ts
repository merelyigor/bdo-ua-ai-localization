import type { Plugin } from "@opencode-ai/plugin"

// Команди прогону: єдиний шлях, яким створюється робота й записуються дані.
const SAFE_BDO_COMMANDS = [
  /^\.\/bdo env$/,
  /^\.\/bdo smoke$/,
  // Третій аргумент · патч (`active` або числовий snapshot_id): робота живе не
  // лише в активному патчі, і без цього набір її просто не бачив.
  /^\.\/bdo mode status (patch|manual|proposal|improve)( (active|[0-9]{1,6}))?$/,
  /^\.\/bdo mode start (patch|manual|proposal|improve)( [1-9][0-9]*( (active|[0-9]{1,6}))?)?$/,
  /^\.\/bdo run drive$/,
  // ДОВІДКОВІ, ТІЛЬКИ ЧИТАННЯ.
  //
  // Раніше їх не було, і диригент не міг відповісти навіть на «де є що
  // перекладати»: питання впиралось у guard, хоча жодного запису в них немає.
  // Обмеження існує проти прихованих агентів і shell-обходів, а не проти
  // читання. Мутуючі варіанти тих самих команд сюди НЕ входять: `--clear`,
  // `--apply`, `--approve`, `--reject`, `profile use|set|paid`, `fetch`,
  // `write`, `commit`, `clean`, `run start|end`, `schema` лишаються поза
  // переліком, тож випадкова зміна стану неможлива.
  /^\.\/bdo$/,
  /^\.\/bdo help( [a-z]+)?$/,
  /^\.\/bdo (paths|platform|models|api|runtime)$/,
  /^\.\/bdo patch( (active|[0-9]{1,6}))?$/,
  /^\.\/bdo patches( (all|[1-9][0-9]*))?( (machine|manual|both))?( --full)?$/,
  /^\.\/bdo profile status$/,
  /^\.\/bdo (audit|audit-dump)$/,
  /^\.\/bdo (incidents|judge)( --list)?$/,
  /^\.\/bdo moderation( --limit [1-9][0-9]*)?$/,
  /^\.\/bdo moderation --row [0-9a-f]{64}$/,
  /^\.\/bdo moderation --approve [1-9][0-9]*(,[1-9][0-9]*)*$/,
]
const SAFE_TOOLS = new Set(["bash", "read", "task", "translation_result"])

// Послідовність дозволених команд через `&&` приймається як одна.
//
// Причина не в зручності. Диригент природно обʼєднує два сусідні кроки промпта
// (`./bdo env` -> `./bdo smoke`) в один виклик, і за це прогін падав із
// «Tool execution aborted»: 5 аварій за день, усі на тому самому нешкідливому
// `./bdo env && ./bdo smoke`. Ізоляція від цього не слабшає · кожен сегмент
// звіряється з тим самим коротким переліком точних команд, а `&&` є єдиним
// дозволеним розділювачем: pipes, `;`, підстановки й перенаправлення лишаються
// поза законом, бо після розділення такий сегмент просто не збігається.
function allowedShell(command: string): boolean {
  const parts = command.split("&&").map((part) => part.trim())
  return parts.length > 0 && parts.every((part) => SAFE_BDO_COMMANDS.some((pattern) => pattern.test(part)))
}

// Порушення більше не вбиває сесію з першого разу.
//
// Раніше guard одразу робив `session.abort()`, і будь-яка помилка формулювання
// перетворювалась на мертву сесію. Але сам виклик і так НЕ виконується: guard
// кидає помилку до виконання. Тому перші спроби отримують зрозумілу відмову, з
// якої модель може виправитись, а abort лишається для наполегливого обходу.
const ABORT_AFTER_VIOLATIONS = 3
const ALLOWED_HINT = [
  "прогін: ./bdo env | ./bdo smoke | ./bdo mode status <mode> [patch]",
  "./bdo mode start <mode> [N] [patch] | ./bdo run drive",
  "довідка (тільки читання): ./bdo patches [N|all] [machine|manual|both] [--full]",
  "./bdo patch [N] | ./bdo profile status",
  "./bdo audit | ./bdo incidents [--list] | ./bdo judge [--list] | ./bdo moderation [--limit N]",
  "./bdo paths | ./bdo platform | ./bdo models | ./bdo api | ./bdo runtime | ./bdo help",
  "кілька команд можна поєднати через &&",
].join(" · ")

/** Закриває всі shell/API/CLI шляхи, якими можна створити невидимого агента. */
export const TranslationExecutionGuard: Plugin = async ({ client, directory }) => {
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
        await refuse(
          input.sessionID,
          `Tool ${input.tool} is unavailable in translation primary. Use native OpenCode task for subagents.`,
        )
      }
      if (input.tool !== "bash") return
      const command = typeof output.args?.command === "string" ? output.args.command.trim() : ""
      if (!allowedShell(command)) {
        await refuse(
          input.sessionID,
          `Translation primary shell is restricted to the fixed ./bdo workflow. Дозволено: ${ALLOWED_HINT}.`,
        )
      }
    },
  }
}
