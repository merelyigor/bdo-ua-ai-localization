import { appendFileSync, readFileSync } from "node:fs"
import { basename, join, resolve } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"
import {
  atomicWrite,
  clearBlocked,
  clearIncident,
  pendingIncident,
  recordBlocked,
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
  "translation-glossary",
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
 * @param input hook-обʼєкт виклику; `args` у типі SDK не оголошені, але є
 * @param output hook-обʼєкт результату; та сама історія з `args`
 * @param payloadPath шлях зі staged envelope · саме він і був у диригента
 */
export function restorePromptReference(
  input: unknown,
  output: unknown,
  payloadPath: string | undefined,
): void {
  if (payloadPath === undefined || payloadPath === "") return
  const reference = `payload:${payloadPath}`
  // Тип hook-обʼєктів у SDK не оголошує `args`, хоча вони там є в обох. Саме
  // тому параметри тут `unknown`, а не структурний тип: інакше кожен виклик дає
  // TS2559 «no properties in common», і червоне в IDE привчає ігнорувати
  // справжні помилки типів.
  for (const carrier of [input, output]) {
    const args = (carrier as { args?: Record<string, unknown> } | null | undefined)?.args
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
export const TranslationChildContract: Plugin = async ({ directory }) => {
  // Диригент мусить ДІЗНАТИСЯ, що його аргумент проігноровано.
  //
  // Плагін тихо підставляв staged payload і писав порушення лише в журнал. Для
  // моделі це виглядало так, ніби її саморобний payload і є тим, що отримав
  // child · тому 2026-08-29 диригент почав «відновлювати» вміст payload по
  // памʼяті, сам це помітив і написав власнику, що «продовжувати з вигаданими
  // проміжними payload безвідповідально при живих записах у PROD». Дані при
  // цьому були цілі, бо їх підставляє плагін. Страждали лише токени й довіра.
  //
  // Тепер після виклику диригент бачить прямий рядок: аргумент проігноровано,
  // збирати payload не треба.
  const substituted = new Set<string>()

  return {
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
      // Спроба зупинена нами, а не моделлю · лічильник мовчання її не рахує.
      recordBlocked(directory, next.response_path, role, "payload_unreadable", new Date().toISOString())
      throw new Error(`Staged payload ${next.payload_path} недоступний; повтори ./bdo run drive.`, { cause })
    }
    if (payload === "") {
      recordBlocked(directory, next.response_path, role, "payload_empty", new Date().toISOString())
      throw new Error(`Staged payload ${next.payload_path} порожній; повтори ./bdo run drive.`)
    }
    // Перевірка ПІСЛЯ перевірок payload: якщо зламаний наш власний staged файл,
    // диригент має побачити саме це, а не претензію до форми свого виклику.
    if (!referencesStagedPayload(output.args.prompt, next.payload_path)) {
      // Спершу ЗАФІКСУВАТИ, що саме передали.
      //
      // Стискання нижче рятує контекст, але знищує доказ: у транскрипті лишається
      // акуратне посилання, і потім неможливо сказати, чи модель справді
      // переписала payload. 2026-08-28 я на цьому помилився публічно · заявив,
      // що відмова була хибною, хоча вона була справжньою. Тому довжина й початок
      // переданого рядка йдуть у журнал ДО стискання.
      try {
        const given = typeof output.args.prompt === "string" ? output.args.prompt : ""
        appendFileSync(
          join(directory, "state/prompt-violations.jsonl"),
          JSON.stringify({
            at: new Date().toISOString(),
            role,
            given_length: given.length,
            given_head: given.slice(0, 120),
            expected: `payload:${next.payload_path}`,
          }) + "\n",
        )
      } catch (cause) {
        // Журнал не є ворітьми: його збій не скасовує відмову. Але й мовчати не
        // можна · саме порожній `catch` ховав би помилку самого журналу.
        console.error("prompt-violations journal failed:", cause instanceof Error ? cause.message : cause)
      }
      // ВИПРАВЛЯЄМО, а не відмовляємо.
      //
      // Відмова тут була помилкою проєктування. 2026-08-28 диригент тричі
      // поспіль передав вміст payload замість посилання (журнал: 3284 символи
      // при файлі в 4650 · тобто ще й ОБРІЗАНУ копію після `read`), щоразу
      // отримував ту саму відмову й не виправлявся. Пачка стала намертво, а
      // власник мусив розбирати це вручну.
      //
      // Причина впертості системна: успішні виклики лишають у транскрипті
      // `prompt` = повний payload (його підставляє цей самий плагін, і
      // стиснути запис назад неможливо · доведено 2026-08-28). Модель бачить
      // власні приклади й точно їх повторює. Карати її за це безглуздо.
      //
      // Обовʼязок плагіна · доставити child ПРАВИЛЬНІ байти, а не виховати
      // диригента. Тому: порушення в журнал, аргумент стиснути, payload
      // підставити зі staged файла й іти далі. Обрізана копія так само не
      // потрапить до child · він отримає повний файл.
      restorePromptReference(input, output, next.payload_path)
      substituted.add(next.response_path)
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
    clearBlocked(directory, next.response_path)
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
    const ignored = substituted.delete(next.response_path)
    output.output = [
      `Збережено відповідь ${role}: ${items} елементів -> ${next.response_path}.`,
      ignored
        ? "УВАГА: твій аргумент prompt проігноровано · child отримав staged payload із state/next-child.json. Вміст payload не збирай і не відновлюй: передавай рівно рядок next.prompt."
        : "",
      split.note === "" ? "" : "Child додав примітку · збережено для власника (./bdo incidents).",
      "Далі: ./bdo run drive.",
    ].filter(Boolean).join(" ")
    },
  }
}

// Keep helper exports available to tests, but make the runtime entry explicit
// so OpenCode does not invoke helpers as legacy plugins.
export default {
  id: "translation-child-contract",
  server: TranslationChildContract,
}
