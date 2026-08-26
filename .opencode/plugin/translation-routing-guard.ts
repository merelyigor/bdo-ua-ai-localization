import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join, resolve } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"

// Де лежить набір скриптів · відносно теки проєкту OpenCode або абсолютно.
// TRANSLATE_TOOLKIT_DIR потрібен, коли набір не є коренем проєкту OpenCode,
// наприклад коли він лежить підкаталогом проєкту, який обслуговує.
const TOOLKIT_DIR = process.env.TRANSLATE_TOOLKIT_DIR ?? "."

type ModelPolicy = { active_profile: string; profiles: Record<string, { allow_paid: boolean; paid_routes: string[]; routes: Record<string, string[]> }> }

function policy(directory: string): ModelPolicy {
  return JSON.parse(readFileSync(resolve(directory, TOOLKIT_DIR, ".opencode/translation-models.json"), "utf8")) as ModelPolicy
}

// Значення reasoning бере одна константа локального `.env`, поруч із рештою
// налаштувань набору (`TRANSLATE_ENV_FILE` працює так само, як у select-env.sh):
//
//   BDO_REASONING_EFFORT=none    типово: без роздумів
//   BDO_REASONING_EFFORT=off     нічого не надсилати (поведінка провайдера)
//   minimal|low|medium|high      якщо конкретній моделі роздуми потрібні
//
// Читається ЛИШЕ цей ключ: `.env` тримає ключі API, і решта його рядків тут не
// торкається, не логується й нікуди не передається. Читання на кожен запит,
// як і політика маршрутів, щоб зміна діяла без перезапуску OpenCode.
const EFFORT_VALUES = new Set(["none", "minimal", "low", "medium", "high"])
const DEFAULT_EFFORT = "none"

function reasoningEffort(directory: string): string | undefined {
  // `||`, а не `??`: порожній TRANSLATE_ENV_FILE означає «не задано», інакше
  // читання пішло б у порожній шлях і константа мовчки зникла б.
  const file = process.env.TRANSLATE_ENV_FILE || resolve(directory, TOOLKIT_DIR, ".env")
  let raw: string | undefined
  try {
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const match = /^\s*(?:export\s+)?BDO_REASONING_EFFORT\s*=\s*(.*)$/.exec(line)
      if (match) raw = match[1]
    }
  } catch {
    raw = undefined
  }
  const value = (raw ?? process.env.BDO_REASONING_EFFORT ?? DEFAULT_EFFORT)
    .trim()
    .replace(/^["']|["']$/g, "")
    .split("#")[0]
    .trim()
    .toLowerCase()
  if (value === "" || value === "off") return undefined
  if (!EFFORT_VALUES.has(value)) {
    throw new Error(
      `BDO_REASONING_EFFORT="${value}" is not one of off|${[...EFFORT_VALUES].join("|")}.`,
    )
  }
  return value
}

// Не кожна модель уміє те, що ми просимо. `x-preview-f-free` оголошує
// `reasoning_options: [{type:"effort", values:["low","high","max"]}]` · `none`
// там немає взагалі, а серед платних є моделі лише з `["high","max"]`. Слати
// значення поза переліком означає покластися на поблажливість гейтвею: хтось
// його проігнорує, хтось відповість 400 посеред пачки.
//
// Джерело переліку · той самий локальний каталог models.dev, з якого OpenCode
// сам будує список моделей. У рантаймі плагіну він недоступний: `model`
// віддає лише булеве `capabilities.reasoning`, без значень effort. Каталог
// читається best-effort: немає файлу, інший формат, кастомний провайдер
// (`ollama-local` там відсутній) · поводимось як раніше й шлемо бажане.
type EffortSupport = { reasoning?: boolean; values?: string[] }

function catalogPath(): string {
  if (process.env.OPENCODE_MODELS_CACHE) return process.env.OPENCODE_MODELS_CACHE
  return join(process.env.XDG_CACHE_HOME || join(homedir(), ".cache"), "opencode", "models.json")
}

function effortSupport(providerID: string, modelID: string): EffortSupport {
  try {
    const catalog = JSON.parse(readFileSync(catalogPath(), "utf8")) as Record<string, { models?: Record<string, { reasoning?: boolean; reasoning_options?: { type?: string; values?: string[] }[] }> }>
    const model = catalog[providerID]?.models?.[modelID]
    if (!model) return {}
    const effort = (model.reasoning_options ?? []).find((option) => option?.type === "effort")
    return { reasoning: model.reasoning === true, values: Array.isArray(effort?.values) ? effort.values : undefined }
  } catch {
    return {}
  }
}

/** Бажане значення, звужене до того, що модель справді оголошує. */
function supportedEffort(desired: string, providerID: string, modelID: string): string | undefined {
  const support = effortSupport(providerID, modelID)
  if (support.reasoning === false) return undefined
  const values = support.values
  if (!values || values.length === 0 || values.includes(desired)) return desired
  // Перелік у каталозі йде від найдешевшого до найдорожчого, тож мінімальний
  // підтримуваний · перший. Це найближче до «не думай», що модель уміє.
  return values[0]
}
const AGENTS = new Set([
  "translation-terminology",
  "translation-worker",
  "translation-qa",
  "translation-repair",
  "translation-judge",
  "translation-smoke",
])

// Агенти, чию відповідь читає скрипт, і файл схеми, що їх обмежує. Обмежена
// відповідь не може нести викликів інструментів, тому кожен агент із цього
// переліку мусить уміти працювати з самого лише свого промпта.
const STRUCTURED_AGENTS = new Map([
  ["translation-worker", "state/current-response-schema.json"],
  ["translation-repair", "state/current-response-schema.json"],
  ["translation-qa", "state/current-qa-schema.json"],
])
const SMOKE_SCHEMA = {
  type: "object",
  properties: { ok: { const: true }, text: { const: "готово" } },
  required: ["ok", "text"],
  additionalProperties: false,
}
const JUDGE_SCHEMA = {
  type: "array",
  items: {
    type: "object",
    properties: {
      identity_hash: { type: "string" },
      destination: { type: "string", enum: ["ai_layer", "moderation"] },
      confidence: { type: "integer", minimum: 0, maximum: 100 },
      reason: { type: "string" },
    },
    required: ["identity_hash", "destination", "confidence", "reason"],
    additionalProperties: false,
  },
}
const TERMINOLOGY_SCHEMA = {
  type: "array",
  items: {
    type: "object",
    properties: {
      canonical_source: { type: "string" },
      status: { type: "string", enum: ["ready", "blocked_identity", "no_answer"] },
      term_id: { type: "string" },
      entity_type: { type: "string" },
      source_identity: { type: "string" },
      ukrainian_proposal: { type: "string" },
      next_action: { type: "string" },
    },
    required: ["canonical_source", "status", "term_id", "entity_type", "source_identity", "ukrainian_proposal", "next_action"],
    additionalProperties: false,
  },
}


// Повертає staged-схему або undefined, коли не поставлено нічого. Читається на
// кожен запит, щоб схема нової пачки діяла без перезапуску OpenCode.
function stagedSchema(directory: string, file: string): unknown | undefined {
  let raw: string
  try {
    raw = readFileSync(resolve(directory, TOOLKIT_DIR, file), "utf8")
  } catch {
    return undefined
  }
  try {
    return JSON.parse(raw)
  } catch (cause) {
    throw new Error(
      `Staged schema ${file} is not valid JSON; rebuild it with ./bdo schema build.`,
      { cause },
    )
  }
}

export const TranslationRoutingGuard: Plugin = async ({ directory }) => ({
  "chat.params": async (input, output) => {
    if (!AGENTS.has(input.agent)) return

    const current = policy(directory)
    const profile = current.profiles[current.active_profile]
    if (!profile) throw new Error(`Unknown active translation model profile: ${current.active_profile}.`)
    const allowedRoutes = profile.routes[input.agent] ?? []
    const routeKey = `${input.model.providerID}/${input.model.id}`
    if (!allowedRoutes.includes(routeKey)) {
      throw new Error(
        `Translation agent ${input.agent} stopped: required route [${allowedRoutes.join(", ")}]; resolved ${routeKey}.`,
      )
    }
    if (profile.paid_routes.includes(routeKey) && !profile.allow_paid) {
      throw new Error(`Paid translation route ${routeKey} is disabled by profile ${current.active_profile}.`)
    }
    // Thinking коштує весь бюджет виходу: Qwen на Ollama `/v1` віддавав його в
    // `reasoning` і лишав `content` порожнім, а Zen-моделі витрачають токени на
    // роздуми там, де відповідь · один рядок JSON зі staged payload.
    //
    // Ключ КАМЕЛЬКЕЙСОМ, і це не стиль. `@ai-sdk/openai-compatible` (і Zen, і
    // ollama-local) збирає тіло так:
    //   { …passthrough(providerOptions[provider]), reasoning_effort: opts.reasoningEffort, … }
    // Невідомі ключі спреду доходять до тіла (саме так працює наш
    // `response_format`, який стоїть ДО спреду), але `reasoning_effort` стоїть
    // ПІСЛЯ нього й перетирає passthrough значенням зі СХЕМИ, де поле зветься
    // `reasoningEffort`. Тому попередній snake_case перетирався на `undefined`
    // і в запит не потрапляв узагалі: аудит показував THINK на кожній сесії,
    // хоча плагін «надсилав» none.
    // `think: false` сюди НЕ додається: виміряно 2026-08-23 на локальній
    // qwen3.5:9b · Ollama `/v1` його ігнорує (284 символи міркувань і порожній
    // `content`), а `reasoning_effort` шанує. Один робочий важіль, не два.
    const desired = reasoningEffort(directory)
    if (desired !== undefined) {
      const effort = supportedEffort(desired, input.model.providerID, input.model.id)
      if (effort !== undefined) output.options.reasoningEffort = effort
    }

    // Constrained decoding: схема прибиває identity_hash до staged-пачки через
    // enum і фіксує довжину масиву, тож модель не може пропустити, продублювати
    // чи вигадати identity. Відсутня схема падає САМЕ ТУТ, до витрати токенів ·
    // інакше дефект спливе аж у ./bdo items після повного прогону пачки.
    if (input.agent === "translation-smoke") {
      output.options.response_format = {
        type: "json_schema",
        json_schema: { name: "translation_capability", strict: true, schema: SMOKE_SCHEMA },
      }
      return
    }
    if (input.agent === "translation-judge") {
      output.options.response_format = {
        type: "json_schema",
        json_schema: { name: "judge", strict: true, schema: JUDGE_SCHEMA },
      }
      return
    }
    if (input.agent === "translation-terminology") {
      output.options.response_format = {
        type: "json_schema",
        json_schema: { name: "terminology", strict: true, schema: TERMINOLOGY_SCHEMA },
      }
      return
    }
    const schemaFile = STRUCTURED_AGENTS.get(input.agent)
    if (schemaFile !== undefined) {
      const schema = stagedSchema(directory, schemaFile)
      if (schema === undefined) {
        throw new Error(
          `${input.agent} requires a staged schema; run ${TOOLKIT_DIR}/bdo schema build first (${TOOLKIT_DIR}/${schemaFile} is missing).`,
        )
      }
      output.options.response_format = {
        type: "json_schema",
        json_schema: { name: "translations", strict: true, schema },
      }
    }
  },
})

// OpenCode 1.18.x treats every named export as a legacy plugin when the module
// has no V1 default entry. Keep the runtime entry explicit and unambiguous.
export default {
  id: "translation-routing-guard",
  server: TranslationRoutingGuard,
}
