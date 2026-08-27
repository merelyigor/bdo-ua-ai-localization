import { readFileSync } from "node:fs"
import { basename, resolve } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"
import {
  atomicWrite,
  clearIncident,
  pendingIncident,
  recordIncident,
  recordNote,
  retryNote,
  splitAnswer,
  unwrapChildJson,
  stateFile,
} from "../lib/child-response.ts"

const ROLES = new Set([
  "translation-terminology",
  "translation-worker",
  "translation-qa",
  "translation-repair",
  "translation-judge",
  "translation-smoke",
])

type ChildEnvelope = { kind?: string; role?: string; payload_path?: string; response_path?: string }

/**
 * Чи є переданий `prompt` посиланням на ТОЙ САМИЙ staged payload.
 *
 * Навіщо. 2026-08-27 диригент замість посилання переписував увесь payload у
 * аргумент `task`. На пачці 50 рядків QA-payload має десятки тисяч символів, і
 * виклик розвалювався на розборі JSON. Правило було в промпті всіх чотирьох
 * режимів, і диригент сам визнав, що його порушує · отже правило потребує
 * перевірки, а не ще одного речення.
 *
 * Переписування не давало НІЧОГО: `tool.execute.before` однаково підставляє
 * вміст staged файла. Тобто це чиста втрата виклику.
 *
 * Приймаємо будь-яке написання шляху (абсолютний, відносний, лише імʼя файла) ·
 * значення має тільки те, що диригент вказав саме цей payload, а не приніс
 * власну копію байтів.
 */
export function referencesStagedPayload(prompt: unknown, payloadPath: string): boolean {
  if (typeof prompt !== "string") return false
  const match = /^payload:\s*(\S.*)$/.exec(prompt.trim())
  if (!match) return false
  const given = match[1].trim().replace(/^["']|["']$/g, "")
  return given === payloadPath || basename(given) === basename(payloadPath)
}

/**
 * Стиснути записаний `prompt` назад до посилання `payload:<path>`.
 *
 * Викликається ПІСЛЯ виконання Task, тому child уже отримав повний payload і
 * нічого не втрачає. Мутуються обидві копії аргументів (`input.args` і
 * `output.args`), бо різні версії OpenCode серіалізують у частину повідомлення
 * то одну, то іншу; зайва мутація нешкідлива.
 *
 * @param payloadPath шлях зі staged envelope · саме він і був у диригента
 */
export function restorePromptReference(
  input: { args?: Record<string, unknown> },
  output: { args?: Record<string, unknown> },
  payloadPath: string | undefined,
): void {
  if (payloadPath === undefined || payloadPath === "") return
  const reference = `payload:${payloadPath}`
  for (const args of [input.args, output.args]) {
    if (args && typeof args.prompt === "string" && args.prompt !== reference) {
      args.prompt = reference
    }
  }
}

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
    // Перевірка ПІСЛЯ перевірок payload: якщо зламаний наш власний staged файл,
    // диригент має побачити саме це, а не претензію до форми свого виклику.
    if (!referencesStagedPayload(output.args.prompt, next.payload_path)) {
      throw new Error(
        `Виклик ${role} відхилено: у prompt має бути РІВНО посилання `
        + `payload:${next.payload_path} і більше нічого. `
        + 'Не переписуй payload у виклик · його вміст підставляє цей плагін, '
        + 'а копія байтів лише ламає розбір JSON на великій пачці. '
        + 'Виправ аргументи й повтори Task один раз.',
      )
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
    // Payload не має лишатись у транскрипті диригента.
    //
    // Before-hook підставляє в `prompt` увесь staged payload · інакше child його
    // не отримає. Але OpenCode зберігає підставлене значення в частині
    // повідомлення, і воно ЗАЛИШАЄТЬСЯ у вхідному контексті платної моделі до
    // кінця сесії, хоча диригент не має права ні читати його, ні змінювати.
    //
    // Виміряно 2026-08-26 по базі OpenCode: у сесії ses_fc8fcd1e один
    // `tool:task` важив 52 647 символів, із них 49 639 · payload QA. На 32
    // виклики це 465 358 із 761 405 символів транскрипту, тобто 61% усього
    // контексту диригента. Витрата росте квадратично: кожен наступний запит
    // пересилає всі попередні payload знову.
    //
    // Child уже відпрацював, тому тут значення можна повернути до короткого
    // посилання · рівно того, яке писав сам диригент.
    restorePromptReference(input, output, next.payload_path)
    const text = typeof output.output === "string" ? output.output : ""
    // TaskTool загортає відповідь child у <task_result>…</task_result>; зняття
    // обгортки детерміноване. Далі відповідь ділиться на JSON і примітку.
    const match = text.match(/<task_result>\n?([\s\S]*?)\n?<\/task_result>/)
    const answer = match ? match[1].trim() : ""
    const split = answer === "" ? undefined : splitAnswer(answer)
    const at = new Date().toISOString()
    if (split === undefined) {
      // Прогін не зупиняється: файл відповіді не зʼявляється, тому наступний
      // `./bdo run drive` перезапустить того самого child, а він отримає
      // уточнення. Журнал лишається власнику для виправлення на рівні проєкту.
      const attempt = recordIncident(
        directory,
        next.response_path,
        role,
        answer === "" ? "порожня відповідь child" : "відповідь не є валідним JSON",
        answer,
        at,
      )
      // Диригент бачить короткий рядок замість усієї відповіді: далі йому
      // потрібна лише наступна дія, а не текст, який він не має права правити.
      output.output = `Відповідь ${role} відхилено (спроба ${attempt}): не JSON. Виконай ./bdo run drive · child повториться з уточненням.`

      return
    }
    // Обгортка strict-схеми знімається ТУТ: на диск лягає той самий масив,
    // який чекають усі скрипти нижче за течією.
    const payloadJson = unwrapChildJson(split.json)
    atomicWrite(stateFile(directory, next.response_path), payloadJson)
    clearIncident(directory, next.response_path)
    recordNote(directory, next.response_path, role, split.note, at)
    // Головна економія платного контексту: відповідь child уже збережена
    // механічно, тому диригенту вертається підтвердження, а не її текст.
    // Виміряно на живому прогоні: 9929 символів відповідей плюс 7395 символів
    // їх повторного переписування у translation_result · усе це було в
    // контексті основної моделі без жодної для неї потреби.
    const items = (() => {
      try {
        const parsed = JSON.parse(payloadJson)

        return Array.isArray(parsed) ? `${parsed.length}` : "1"
      } catch {
        return "?"
      }
    })()
    output.output = [
      `Збережено відповідь ${role}: ${items} елементів -> ${next.response_path}.`,
      split.note === "" ? "" : "Child додав примітку · збережено для власника (./bdo incidents).",
      "Далі: ./bdo run drive.",
    ].filter(Boolean).join(" ")
  },
})

// Keep helper exports available to tests, but make the runtime entry explicit
// so OpenCode does not invoke helpers as legacy plugins.
export default {
  id: "translation-child-contract",
  server: TranslationChildContract,
}
