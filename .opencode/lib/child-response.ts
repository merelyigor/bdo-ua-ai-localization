import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, isAbsolute, relative, resolve, sep } from "node:path"

// Спільне для translation-child-contract і translation-result-writer.
//
// Лежить поза `.opencode/plugin/`, бо OpenCode вантажить кожен файл тієї теки як
// плагін, а це модуль-помічник, а не плагін.

/** Будь-який шлях відповіді мусить лишатися під `state/` проєкту. */
export function stateFile(directory: string, path: string): string {
  const root = resolve(directory, "state")
  const absolute = isAbsolute(path) ? resolve(path) : resolve(root, path)
  const rel = relative(root, absolute)
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`)) throw new Error("Child contract path must be below project state/.")
  return absolute
}

export function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp.${crypto.randomUUID()}`
  writeFileSync(temporary, `${content.trim()}\n`)
  renameSync(temporary, path)
}

// Єдина дозволена «реанімація» відповіді · зняти markdown-огорожу.
//
// Це детермінована операція над ЦІЛИМ текстом: або він увесь є одним fenced
// блоком, або ми його не чіпаємо. Це не «витягування JSON із прози», яке
// проєкт забороняє: жоден символ усередині не змінюється, нічого не
// вибирається на смак. Zen-модель може повернути коректний JSON у ```json-огорожі,
// і тоді пачка має продовжити роботу без ручного втручання,
// хоча відповідь була правильною. Провайдер json_schema не примусує · на
// відміну від Ollama, де constrained decoding діє.
const FENCE = /```[A-Za-z]*[ \t]*\r?\n([\s\S]*?)\r?\n?```/g

/**
 * Знаходить ПЕРШЕ повне значення JSON і межу, де воно закінчується.
 *
 * Сканер знає рядки та екранування, тому межа обчислюється, а не вгадується.
 * Це принципова відмінність від забороненого «витягування JSON із прози»: тут
 * немає вибору на смак · є детермінований розбір дужок.
 */
function firstJsonValue(text: string): { json: string; note: string } | undefined {
  const start = text.search(/[[{]/)
  if (start < 0) return undefined
  const open = text[start]
  const close = open === "[" ? "]" : "}"
  let depth = 0
  let inString = false
  let escaped = false
  for (let i = start; i < text.length; i++) {
    const symbol = text[i]
    if (inString) {
      if (escaped) escaped = false
      else if (symbol === "\\") escaped = true
      else if (symbol === '"') inString = false
      continue
    }
    if (symbol === '"') { inString = true; continue }
    if (symbol === open) depth++
    else if (symbol === close) {
      depth--
      if (depth > 0) continue
      const candidate = text.slice(start, i + 1)
      try {
        JSON.parse(candidate)
      } catch {
        return undefined
      }

      return { json: candidate, note: `${text.slice(0, start)}\n${text.slice(i + 1)}`.trim() }
    }
  }

  return undefined
}

/**
 * Розгорнути strict-обгортку назад у масив, який чекає решта флоу.
 *
 * Structured outputs в OpenAI-сумісних провайдерів вимагають корінь `object`.
 * Через це схеми віддають або `{ items: [...] }` (суддя, термінологія), або
 * `{ row_1: {...}, row_2: {...} }` (worker/repair/qa, де кожен ключ прибитий до
 * свого `identity_hash`). Розгортання робиться ТУТ, одразу після відповіді, щоб
 * жоден скрипт нижче не знав про обгортку й нічого не переписувати.
 *
 * Толерантність навмисна: чистий масив приймається як є. Ollama-runner до схеми
 * поблажливий і за старим промптом може віддати саме масив, а `smoke` взагалі
 * повертає `{ok,text}` · його чіпати не можна.
 *
 * Ключі `row_N` впорядковуються ЧИСЛОМ, а не рядком: інакше `row_10` стало б
 * перед `row_2`, і позиційна гарантія перетворилась би на свою протилежність.
 */
export function unwrapChildJson(json: string): string {
  let parsed: unknown
  try {
    parsed = JSON.parse(json)
  } catch {
    return json
  }
  if (Array.isArray(parsed)) return json
  if (parsed === null || typeof parsed !== "object") return json
  const record = parsed as Record<string, unknown>
  if (Array.isArray(record.items)) return JSON.stringify(record.items)
  const keys = Object.keys(record)
  if (keys.length > 0 && keys.every((key) => /^row_[0-9]+$/.test(key))) {
    const ordered = keys
      .slice()
      .sort((a, b) => Number(a.slice(4)) - Number(b.slice(4)))
      .map((key) => record[key])

    return JSON.stringify(ordered)
  }

  return json
}

/**
 * Розділяє відповідь child на JSON і примітку.
 *
 * Дитина · це модель, а не скрипт: разом із коректним JSON вона законно
 * пояснює рішення («AMD FidelityFX · зареєстрована торгова марка, залишено без
 * перекладу»). Виміряно 2026-08-23: така відповідь відхилялась цілком, і
 * корисне спостереження зникало разом із нею, хоча JSON у ній був правильний.
 *
 * Тому JSON береться детерміновано (увесь текст / єдиний fenced блок / перше
 * повне значення), а решта тексту зберігається як примітка для власника.
 * Неоднозначність (два fenced блоки, зламаний JSON) відхиляється як раніше.
 */
export function splitAnswer(raw: string): { json: string; note: string } | undefined {
  const text = raw.trim()
  if (text === "") return undefined
  try {
    JSON.parse(text)

    return { json: text, note: "" }
  } catch {
    // Не чистий JSON · далі перевіряємо огорожу й перше значення.
  }
  const fences = [...text.matchAll(FENCE)]
  if (fences.length === 1 && fences[0].index !== undefined) {
    const body = fences[0][1].trim()
    try {
      JSON.parse(body)
      const before = text.slice(0, fences[0].index)
      const after = text.slice(fences[0].index + fences[0][0].length)

      return { json: body, note: `${before}\n${after}`.trim() }
    } catch {
      // Огорожа є, але всередині не JSON · лишається останній варіант.
    }
  }

  return firstJsonValue(text)
}

type Incidents = Record<string, { count: number; reason: string }>

function incidentsFile(directory: string): string {
  return resolve(directory, "state", "child-incidents.json")
}

function readIncidents(directory: string): Incidents {
  try {
    return JSON.parse(readFileSync(incidentsFile(directory), "utf8")) as Incidents
  } catch {
    return {}
  }
}

/**
 * Фіксує дефект відповіді child і повертає номер спроби.
 *
 * Два файли з різним призначенням: `child-incidents.json` · робочий стан для
 * наступної спроби, а `flow-incidents.jsonl` · журнал для розбору ПІСЛЯ
 * прогону. Мета власника · безперервний ланцюжок: помилка формату лікується в
 * прогоні автоматично, а виправляється на рівні проєкту потім, за журналом.
 */
export function recordIncident(directory: string, responsePath: string, role: string, reason: string, sample: string, at: string): number {
  const incidents = readIncidents(directory)
  const count = (incidents[responsePath]?.count ?? 0) + 1
  incidents[responsePath] = { count, reason }
  mkdirSync(resolve(directory, "state"), { recursive: true })
  atomicWrite(incidentsFile(directory), JSON.stringify(incidents))
  appendFileSync(
    resolve(directory, "state", "flow-incidents.jsonl"),
    `${JSON.stringify({ at, role, response_path: responsePath, attempt: count, reason, sample: sample.slice(0, 300) })}\n`,
  )

  return count
}

export function pendingIncident(directory: string, responsePath: string): { count: number; reason: string } | undefined {
  return readIncidents(directory)[responsePath]
}

export function clearIncident(directory: string, responsePath: string): void {
  const incidents = readIncidents(directory)
  if (incidents[responsePath] === undefined) return
  delete incidents[responsePath]
  atomicWrite(incidentsFile(directory), JSON.stringify(incidents))
}

type Blocked = Record<string, { count: number; reason: string }>

function blockedFile(directory: string): string {
  return resolve(directory, "state", "child-blocked.json")
}

export function readBlocked(directory: string): Blocked {
  try {
    return JSON.parse(readFileSync(blockedFile(directory), "utf8")) as Blocked
  } catch {
    return {}
  }
}

/**
 * Фіксує спробу, яку зупинили МИ САМІ, ще до моделі.
 *
 * Навіщо окремий облік. `run drive` рахує мовчазні спроби, щоб не чекати добу на
 * модель, яка нічого не повертає. Але для лічильника відмова плагіна виглядала
 * так само, як мовчання провайдера: файла відповіді немає, інциденту формату
 * немає. 2026-08-28 три дispatch-и, заблокованих нашим же
 * `OPENCODE_RUNTIME_INVALID`, вичерпали ліміт, і після справжнього виправлення
 * власник отримав діагноз «провайдер відмовив, перевір модель у .env» ·
 * помилковий і рівно в бік, протилежний причині.
 *
 * Тому кожна відмова до старту child лягає сюди, і drive віднімає її з
 * лічильника мовчання. Життєвий цикл той самий, що в `child-incidents.json`:
 * успішна відповідь очищає запис.
 */
export function recordBlocked(directory: string, responsePath: string, role: string, reason: string, at: string): void {
  const blocked = readBlocked(directory)
  const count = (blocked[responsePath]?.count ?? 0) + 1
  blocked[responsePath] = { count, reason }
  mkdirSync(resolve(directory, "state"), { recursive: true })
  atomicWrite(blockedFile(directory), JSON.stringify(blocked))
  appendFileSync(
    resolve(directory, "state", "flow-incidents.jsonl"),
    `${JSON.stringify({ at, role, response_path: responsePath, attempt: count, reason: `blocked: ${reason}` })}\n`,
  )
}

export function clearBlocked(directory: string, responsePath: string): void {
  const blocked = readBlocked(directory)
  if (blocked[responsePath] === undefined) return
  delete blocked[responsePath]
  atomicWrite(blockedFile(directory), JSON.stringify(blocked))
}

/**
 * Зберігає примітку child окремо від даних.
 *
 * Примітка · не дефект: це спостереження моделі, яке власник читає після
 * прогону (`./bdo incidents`). Саме заради таких спостережень у флоу стоїть ШІ,
 * а не скрипт, тому вони не мають зникати разом із форматом.
 */
export function recordNote(directory: string, responsePath: string, role: string, note: string, at: string): void {
  if (note === "") return
  mkdirSync(resolve(directory, "state"), { recursive: true })
  appendFileSync(
    resolve(directory, "state", "child-notes.jsonl"),
    `${JSON.stringify({ at, role, response_path: responsePath, note: note.slice(0, 600) })}\n`,
  )
}

/** Уточнення, яке отримує child на повторній спробі. */
export function retryNote(previous: { count: number; reason: string }): string {
  return [
    "",
    `УВАГА, спроба ${previous.count + 1}. Попередню відповідь відхилено: ${previous.reason}.`,
    "Поверни ЛИШЕ JSON: без markdown-огорожі ```, без пояснень, без тексту до або після.",
  ].join("\n")
}
