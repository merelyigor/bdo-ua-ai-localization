import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"

/**
 * Диригент не має зупинятись посеред пачки.
 *
 * Симптом 2026-08-29: після `Збережено відповідь translation-qa: 50 елементів.
 * Далі: ./bdo run drive.` диригент написав акуратний звіт про стан і завершив
 * хід. Пачка лишилась у `awaiting_qa`, робота стала, і власник мусив написати
 * «продовжуй» · тобто рівно те, від чого його звільняє UX-контракт проєкту.
 *
 * Сигнал у виводі інструмента БУВ («Далі: ./bdo run drive»), і саме тому
 * підсилювати текст немає сенсу: слабка модель однаково інколи вирішує, що
 * доречніше відзвітувати. Межу тримає код: коли сесія затихла, а пачка НЕ в
 * термінальному стані, набір сам надсилає «продовжуй».
 *
 * Запобіжники, щоб це не стало вічним циклом:
 *  - штовхаємо лише PRIMARY-сесію; дитячі (`translation-*`) ігноруються;
 *  - лічильник на пару «пачка + стан»: якщо стан не зрушив після
 *    `BDO_AUTOPILOT_MAX_NUDGES` (типово 3) поштовхів, зупиняємось і лишаємо
 *    рішення власнику · саме так виглядає справжня зупинка, а не забудькуватість;
 *  - кожен поштовх іде в `state/autopilot.jsonl`, тому мовчазним він не буває;
 *  - `BDO_AUTOPILOT=off` вимикає повністю.
 */
const TERMINAL = new Set(["verified", "failed_terminal"])
const CHILD_AGENT = /^translation-/

type Ledger = { batch: string; state: string; nudges: number }

function envFlag(directory: string, key: string): string | undefined {
  const file = process.env.TRANSLATE_ENV_FILE || resolve(directory, ".env")
  try {
    let found: string | undefined
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const match = new RegExp(`^\\s*(?:export\\s+)?${key}\\s*=\\s*(.*)$`).exec(line)
      if (match) found = match[1]
    }

    return found?.split("#")[0].trim().replace(/^["']|["']$/g, "").toLowerCase()
  } catch {
    return undefined
  }
}

function stateDir(directory: string): string {
  return process.env.BDO_STATE_DIR || resolve(directory, "state")
}

/** Поточна пачка й її стан, або undefined, якщо пачки немає. */
function currentBatch(directory: string): { batch: string; state: string } | undefined {
  const dir = stateDir(directory)
  try {
    const batch = readFileSync(resolve(dir, "current-batch"), "utf8").trim()
    if (batch === "") return undefined
    const manifest = JSON.parse(readFileSync(resolve(dir, "batches", batch, "manifest.json"), "utf8")) as { state?: string }
    const state = typeof manifest.state === "string" ? manifest.state : ""
    if (state === "") return undefined

    return { batch, state }
  } catch {
    return undefined
  }
}

function readLedger(directory: string): Ledger | undefined {
  try {
    return JSON.parse(readFileSync(resolve(stateDir(directory), "autopilot.json"), "utf8")) as Ledger
  } catch {
    return undefined
  }
}

/**
 * Скільки поштовхів лишилось для цієї пари «пачка + стан».
 *
 * Стан зрушив · лічильник обнуляється: це і є доказ, що поштовх працює. Стан
 * той самий · лічильник росте, і після ліміту набір замовкає. Мовчазне
 * нескінченне «продовжуй» коштувало б токенів і ховало справжню поломку.
 */
export function nextNudge(previous: Ledger | undefined, batch: string, state: string, limit: number): Ledger | undefined {
  const same = previous !== undefined && previous.batch === batch && previous.state === state
  const nudges = same ? previous.nudges + 1 : 1
  if (nudges > limit) return undefined

  return { batch, state, nudges }
}

export const TranslationAutopilot: Plugin = async ({ directory, client }) => ({
  event: async ({ event }) => {
    if (event.type !== "session.idle") return
    if (envFlag(directory, "BDO_AUTOPILOT") === "off") return
    const sessionID = (event as { properties?: { sessionID?: string } }).properties?.sessionID
    if (typeof sessionID !== "string" || sessionID === "") return

    const batch = currentBatch(directory)
    if (batch === undefined || TERMINAL.has(batch.state)) return

    // Дитячі сесії теж «затихають», але штовхати їх безглуздо: вони живуть
    // рівно один виклик, і їх веде диригент.
    try {
      const session = await client.session.get({ path: { id: sessionID } })
      const agent = (session as { data?: { agent?: string } })?.data?.agent
      if (typeof agent === "string" && CHILD_AGENT.test(agent)) return
    } catch {
      // Не змогли дізнатись роль сесії · не штовхаємо. Хибний поштовх у дитячу
      // сесію дорожчий за пропущений у диригента: власник однаково напише сам.
      return
    }

    const limit = Number.parseInt(envFlag(directory, "BDO_AUTOPILOT_MAX_NUDGES") ?? "3", 10)
    const ledger = nextNudge(readLedger(directory), batch.batch, batch.state, Number.isNaN(limit) ? 3 : limit)
    const at = new Date().toISOString()
    const dir = stateDir(directory)
    mkdirSync(dir, { recursive: true })
    if (ledger === undefined) {
      appendFileSync(resolve(dir, "autopilot.jsonl"),
        `${JSON.stringify({ at, batch: batch.batch, state: batch.state, action: "give_up" })}\n`)
      // Здача набору мусить бути ВИДИМОЮ.
      //
      // 2026-08-29 диригент тричі відповів «продовжую негайно» і жодного разу
      // не викликав Task · сесія набрала 1,96 млн вхідних токенів і після
      // стискання перестала доводити крок до дії. Автопілот чесно вичерпав
      // поштовхи й замовк у журнал, а власник просто сидів і дивився, як
      // нічого не відбувається. Тому тут · сповіщення в інтерфейс, один раз на
      // пару «пачка+стан», із конкретною порадою.
      const told = resolve(dir, `autopilot-told-${batch.batch}-${batch.state}`)
      if (!existsSync(told)) {
        writeFileSync(told, at)
        await client.tui.showToast({
          body: {
            title: "Прогін став",
            message: `Диригент не рухає пачку ${batch.state} після ${limit} поштовхів. `
              + "Найімовірніше вичерпано контекст сесії: почни НОВУ сесію режиму й напиши «продовжуй». "
              + "Стан пачки на диску, нічого не втрачено.",
            variant: "warning",
            duration: 20000,
          },
        }).catch(() => undefined)
      }

      return
    }
    writeFileSync(resolve(dir, "autopilot.json"), JSON.stringify(ledger))
    appendFileSync(resolve(dir, "autopilot.jsonl"),
      `${JSON.stringify({ at, batch: batch.batch, state: batch.state, nudge: ledger.nudges })}\n`)

    await client.session.promptAsync({
      path: { id: sessionID },
      body: { parts: [{ type: "text", text: "продовжуй" }] },
    }).catch(() => undefined)
  },
})

export default {
  id: "translation-autopilot",
  server: TranslationAutopilot,
}
