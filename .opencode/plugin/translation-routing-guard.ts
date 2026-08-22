import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"

// Where the script toolkit lives, relative to the OpenCode project directory (or
// absolute). Set TRANSLATE_TOOLKIT_DIR when the toolkit is not the OpenCode project root
// itself - e.g. when it sits as a subdirectory of the project it serves.
const TOOLKIT_DIR = process.env.TRANSLATE_TOOLKIT_DIR ?? "."

type ModelPolicy = { active_profile: string; profiles: Record<string, { allow_paid: boolean; paid_routes: string[]; routes: Record<string, string[]> }> }

function policy(directory: string): ModelPolicy {
  return JSON.parse(readFileSync(resolve(directory, TOOLKIT_DIR, ".opencode/translation-models.json"), "utf8")) as ModelPolicy
}
const AGENTS = new Set([
  "translation-terminology",
  "translation-worker",
  "translation-qa",
  "translation-repair",
  "translation-smoke",
])

// Agents whose answer is consumed by a script, mapped to the schema file that
// constrains them. A constrained answer cannot carry tool calls, so every agent
// listed here must be able to work from its prompt alone.
const STRUCTURED_AGENTS = new Map([
  ["translation-worker", "state/current-response-schema.json"],
  ["translation-repair", "state/current-response-schema.json"],
  ["translation-qa", "state/current-qa-schema.json"],
])
const SMOKE_SCHEMA = {
  type: "object",
  properties: { ok: { const: true }, text: { type: "string", minLength: 1 } },
  required: ["ok", "text"],
  additionalProperties: false,
}


// Returns the staged schema, or undefined when nothing is staged. Read per request
// so that staging a new batch takes effect without restarting OpenCode.
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
        `Translation agent ${input.agent} requires one of [${allowedRoutes.join(", ")}]; resolved ${routeKey}.`,
      )
    }
    if (profile.paid_routes.includes(routeKey) && !profile.allow_paid) {
      throw new Error(`Paid translation route ${routeKey} is disabled by profile ${current.active_profile}.`)
    }
    // Qwen thinking on the Ollama /v1 endpoint eats the whole output budget as
    // `reasoning` and leaves `content` empty, so the child dies with no answer.
    // `reasoning_effort: "none"` is the switch that /v1 actually honours
    // (top-level `think: false` and `chat_template_kwargs` are ignored there).
    output.options.reasoning_effort = "none"

    // Constrained decoding: the schema pins identity_hash to the staged batch via enum
    // and fixes the array length, so the model cannot drop, duplicate or invent an
    // identity. A missing schema fails HERE, before any tokens are spent - otherwise
    // the defect would only surface later in ./bdo items after a full batch run.
    if (input.agent === "translation-smoke") {
      output.options.response_format = {
        type: "json_schema",
        json_schema: { name: "translation_capability", strict: true, schema: SMOKE_SCHEMA },
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
