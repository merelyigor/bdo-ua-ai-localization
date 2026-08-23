import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"
import {
  atomicWrite,
  clearIncident,
  pendingIncident,
  recordIncident,
  retryNote,
  stateFile,
  unwrapJson,
} from "../lib/child-response.ts"

const ROLES = new Set([
  "translation-terminology",
  "translation-worker",
  "translation-qa",
  "translation-repair",
  "translation-smoke",
])

type ChildEnvelope = { kind?: string; role?: string; payload_path?: string; response_path?: string }

function envelope(directory: string): ChildEnvelope | undefined {
  try {
    return JSON.parse(readFileSync(resolve(directory, "state/next-child.json"), "utf8")) as ChildEnvelope
  } catch {
    return undefined
  }
}

/**
 * Механічний child-контракт для native Task.
 *
 * Слабка модель-диригент не є надійним носієм байтів: копія payload у
 * аргументах виклику вже коштувала пачки. Тому диригент передає лише посилання,
 * а цей плагін:
 *  - before: підставляє в prompt точний вміст staged payload зі
 *    `state/next-child.json`, а на повторній спробі додає уточнення про те, чим
 *    попередня відповідь була погана;
 *  - after: зберігає JSON-відповідь Task у `response_path`, знявши обгортку
 *    `<task_result>` і, за потреби, markdown-огорожу.
 *
 * Дефект формату не зупиняє прогін: він фіксується в журналі, файл відповіді не
 * зʼявляється, і наступний `./bdo run drive` перезапускає того самого child.
 */
export const TranslationChildContract: Plugin = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (input.tool !== "task") return
    const role = typeof output.args?.subagent_type === "string" ? output.args.subagent_type : ""
    if (!ROLES.has(role)) return
    const next = envelope(directory)
    if (!next || next.kind !== "child" || !next.payload_path || !next.response_path) {
      // Ручний `@translation-smoke` без envelope легальний: його відповідь
      // однаково обмежена вбудованою smoke-схемою і нічого не пише.
      if (role === "translation-smoke") return
      throw new Error(`Немає staged child envelope для ${role}: спочатку ./bdo run drive або ./bdo smoke.`)
    }
    if (next.role !== role) {
      throw new Error(`Staged envelope чекає ${next.role}; Task викликає ${role}.`)
    }
    // Диригент передає лише посилання на payload, тому цей плагін є ЄДИНИМ його
    // носієм: порожній або відсутній файл мусить зупинити виклик зрозуміло, а не
    // віддати child порожній prompt і отримати `[]` як «відповідь моделі».
    let payload: string
    try {
      payload = readFileSync(stateFile(directory, next.payload_path), "utf8").trim()
    } catch (cause) {
      throw new Error(`Staged payload ${next.payload_path} недоступний; повтори ./bdo run drive.`, { cause })
    }
    if (payload === "") {
      throw new Error(`Staged payload ${next.payload_path} порожній; повтори ./bdo run drive.`)
    }
    const previous = pendingIncident(directory, next.response_path)
    output.args.prompt = previous === undefined ? payload : `${payload}${retryNote(previous)}`
  },
  "tool.execute.after": async (input, output) => {
    if (input.tool !== "task" || !output) return
    const role = typeof input.args?.subagent_type === "string" ? input.args.subagent_type : ""
    if (!ROLES.has(role)) return
    const next = envelope(directory)
    if (!next || next.kind !== "child" || next.role !== role || !next.response_path) return
    const text = typeof output.output === "string" ? output.output : ""
    // TaskTool загортає відповідь child у <task_result>…</task_result>; зняття
    // обгортки детерміноване. Далі лишається або чистий JSON, або той самий
    // JSON у markdown-огорожі · обидва приймаються без зміни жодного символа.
    const match = text.match(/<task_result>\n?([\s\S]*?)\n?<\/task_result>/)
    const answer = match ? match[1].trim() : ""
    const json = answer === "" ? undefined : unwrapJson(answer)
    if (json === undefined) {
      // Прогін не зупиняється: файл відповіді не зʼявляється, тому наступний
      // `./bdo run drive` перезапустить того самого child, а він отримає
      // уточнення. Журнал лишається власнику для виправлення на рівні проєкту.
      recordIncident(
        directory,
        next.response_path,
        role,
        answer === "" ? "порожня відповідь child" : "відповідь не є валідним JSON",
        answer,
        new Date().toISOString(),
      )

      return
    }
    atomicWrite(stateFile(directory, next.response_path), json)
    clearIncident(directory, next.response_path)
  },
})
