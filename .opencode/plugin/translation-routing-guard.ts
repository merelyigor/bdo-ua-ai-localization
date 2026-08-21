import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"

// Where the script toolkit lives, relative to the OpenCode project directory (or
// absolute). Set TRANSLATE_TOOLKIT_DIR when the toolkit is not the OpenCode project root
// itself - e.g. when it sits as a subdirectory of the project it serves.
const TOOLKIT_DIR = process.env.TRANSLATE_TOOLKIT_DIR ?? "."

// Allowed local free routes. quality = official Qwen3.6-35B-A3B GGUF, fast = Qwen3.5-9B.
// GGUF only: the Ollama MLX runner silently ignores constrained decoding (verified on
// qwen3.6:35b-mlx - it returned keys outside additionalProperties:false), so an -mlx
// model here would break the identity guarantee.
const ALLOWED_ROUTES = new Set(["ollama-local/qwen3.6:35b-a3b-mtp-q4_K_M", "ollama-local/qwen3.5:9b"])
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
      `Staged schema ${file} is not valid JSON; rebuild it with build-schema.sh.`,
      { cause },
    )
  }
}

export const TranslationRoutingGuard: Plugin = async ({ directory }) => ({
  "chat.params": async (input, output) => {
    if (!AGENTS.has(input.agent)) return

    const routeKey = `${input.model.providerID}/${input.model.id}`
    if (!ALLOWED_ROUTES.has(routeKey)) {
      throw new Error(
        `Translation agent ${input.agent} requires one of [${[...ALLOWED_ROUTES].join(", ")}]; resolved ${routeKey}.`,
      )
    }
    // Qwen thinking on the Ollama /v1 endpoint eats the whole output budget as
    // `reasoning` and leaves `content` empty, so the child dies with no answer.
    // `reasoning_effort: "none"` is the switch that /v1 actually honours
    // (top-level `think: false` and `chat_template_kwargs` are ignored there).
    output.options.reasoning_effort = "none"

    // Constrained decoding: the schema pins identity_hash to the staged batch via enum
    // and fixes the array length, so the model cannot drop, duplicate or invent an
    // identity. A missing schema fails HERE, before any tokens are spent - otherwise
    // the defect would only surface later in build-items.sh after a full batch run.
    const schemaFile = STRUCTURED_AGENTS.get(input.agent)
    if (schemaFile !== undefined) {
      const schema = stagedSchema(directory, schemaFile)
      if (schema === undefined) {
        throw new Error(
          `${input.agent} requires a staged schema; run ${TOOLKIT_DIR}/build-schema.sh first (${TOOLKIT_DIR}/${schemaFile} is missing).`,
        )
      }
      output.options.response_format = {
        type: "json_schema",
        json_schema: { name: "translations", strict: true, schema },
      }
    }
  },
})
