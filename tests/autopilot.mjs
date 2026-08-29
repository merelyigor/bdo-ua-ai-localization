// Автопілот: набір сам каже «продовжуй», але не нескінченно.
//
// 2026-08-29 диригент після успішного QA написав звіт і завершив хід · пачка
// лишилась у `awaiting_qa`. Сигнал у виводі інструмента був, і саме тому межу
// тримає код, а не ще одне речення в промпті.
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import plugin, { nextNudge } from "../.opencode/plugin/translation-autopilot.ts"

const fail = (m) => { console.error("FAIL:", m); process.exit(1) }

// 1. Лічильник: стан не рухається · після ліміту здаємось.
let ledger = nextNudge(undefined, "b1", "awaiting_qa", 3)
if (ledger?.nudges !== 1) fail("перший поштовх не порахований")
ledger = nextNudge(ledger, "b1", "awaiting_qa", 3)
ledger = nextNudge(ledger, "b1", "awaiting_qa", 3)
if (ledger?.nudges !== 3) fail("лічильник не росте на тому самому стані")
if (nextNudge(ledger, "b1", "awaiting_qa", 3) !== undefined) fail("після ліміту набір мусить замовкнути")
// 2. Стан зрушив · лічильник обнуляється, бо поштовх спрацював.
if (nextNudge(ledger, "b1", "healing", 3)?.nudges !== 1) fail("рух стану не обнулив лічильник")
if (nextNudge(ledger, "b2", "awaiting_qa", 3)?.nudges !== 1) fail("нова пачка не обнулила лічильник")

// 3. Живий хід: пачка в роботі · поштовх іде; verified · не йде.
const dir = mkdtempSync(join(tmpdir(), "bdo-autopilot-"))
mkdirSync(join(dir, "state/batches/b1"), { recursive: true })
writeFileSync(join(dir, ".env"), "BDO_AUTOPILOT=on\n")
writeFileSync(join(dir, "state/current-batch"), "b1\n")
const manifest = (state) => writeFileSync(join(dir, "state/batches/b1/manifest.json"), JSON.stringify({ state }))
process.env.BDO_STATE_DIR = join(dir, "state")

const sent = []
const toasts = []
const client = {
  session: {
    get: async () => ({ data: { agent: "патч" } }),
    promptAsync: async (args) => { sent.push(args.body.parts[0].text); return {} },
  },
  tui: { showToast: async (args) => { toasts.push(args.body); return {} } },
}
const hooks = await plugin.server({ directory: dir, client })

manifest("awaiting_qa")
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_1" } } })
if (sent.length !== 1 || sent[0] !== "продовжуй") fail(`поштовх не надіслано: ${JSON.stringify(sent)}`)

manifest("verified")
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_1" } } })
if (sent.length !== 1) fail("завершену пачку штовхати не можна")

// 4. Дитячу сесію не штовхаємо: вона живе рівно один виклик.
manifest("awaiting_qa")
const childClient = {
  session: {
    get: async () => ({ data: { agent: "translation-qa" } }),
    promptAsync: async () => { fail("штовхнули дитячу сесію") },
  },
}
const childHooks = await plugin.server({ directory: dir, client: childClient })
await childHooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_child" } } })

// 5. Вимикач власника працює.
writeFileSync(join(dir, ".env"), "BDO_AUTOPILOT=off\n")
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_1" } } })
if (sent.length !== 1) fail("BDO_AUTOPILOT=off не вимкнув автопілот")

// 6. Кожен поштовх видно в журналі · мовчазним він не буває.
if (!existsSync(join(dir, "state/autopilot.jsonl"))) fail("журнал поштовхів не створено")
const log = readFileSync(join(dir, "state/autopilot.jsonl"), "utf8").trim().split("\n")
if (!JSON.parse(log[0]).nudge) fail("у журналі немає номера поштовху")

// 7. Здача автопілота мусить бути ВИДИМОЮ власнику.
//
// 2026-08-29 диригент тричі відповів «продовжую негайно» без жодного виклику,
// автопілот вичерпав поштовхи й замовк у журнал · власник сидів і дивився, як
// нічого не відбувається.
writeFileSync(join(dir, ".env"), "BDO_AUTOPILOT=on\nBDO_AUTOPILOT_MAX_NUDGES=1\n")
manifest("awaiting_qa")
writeFileSync(join(dir, "state/autopilot.json"), JSON.stringify({ batch: "b1", state: "awaiting_qa", nudges: 1 }))
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_1" } } })
if (toasts.length !== 1) fail(`здача не показана власнику: ${JSON.stringify(toasts)}`)
if (!String(toasts[0].message).includes("НОВУ сесію")) fail("порада без конкретної дії")
// Повторно не спамимо.
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "ses_1" } } })
if (toasts.length !== 1) fail("сповіщення повторюється на кожній події")

console.log("autopilot: OK")
