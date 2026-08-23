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
// вибирається на смак. Виміряно 2026-08-23: Zen `x-preview-f-free` повернув
// коректний JSON термінів у ```json-огорожі, і пачка стала на рівному місці,
// хоча відповідь була правильною. Провайдер json_schema не примусує · на
// відміну від Ollama, де constrained decoding діє.
const FENCE = /^```[A-Za-z]*[ \t]*\r?\n([\s\S]*?)\r?\n?```$/

export function unwrapJson(raw: string): string | undefined {
  const text = raw.trim()
  const candidates = [text]
  const fenced = FENCE.exec(text)
  if (fenced) candidates.push(fenced[1].trim())
  for (const candidate of candidates) {
    if (candidate === "") continue
    try {
      JSON.parse(candidate)

      return candidate
    } catch {
      // Спроба з необгорнутим/обгорнутим JSON може бути невдалою; цикл
      // природно переходить до наступного кандидата.
    }
  }

  return undefined
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

/** Уточнення, яке отримує child на повторній спробі. */
export function retryNote(previous: { count: number; reason: string }): string {
  return [
    "",
    `УВАГА, спроба ${previous.count + 1}. Попередню відповідь відхилено: ${previous.reason}.`,
    "Поверни ЛИШЕ JSON: без markdown-огорожі ```, без пояснень, без тексту до або після.",
  ].join("\n")
}
