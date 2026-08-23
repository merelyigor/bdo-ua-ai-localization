import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { TranslationRoutingGuard } from "../.opencode/plugin/translation-routing-guard.ts"

const directory = mkdtempSync(join(tmpdir(), "bdo-routing-guard-"))
mkdirSync(join(directory, ".opencode"), { recursive: true })
writeFileSync(join(directory, ".opencode", "translation-models.json"), JSON.stringify({
  active_profile: "test",
  profiles: { test: {
    allow_paid: false,
    paid_routes: ["paid/model"],
    routes: {
      "translation-smoke": ["free/model", "paid/model", "ollama-local/model", "free/knows-none", "free/plain"],
      "translation-worker": ["free/model"],
      "translation-terminology": ["free/model"],
    },
  } },
}))

const hooks = await TranslationRoutingGuard({ directory })
const output = { options: {} }
await hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "model" } }, output)
assert.equal(output.options.response_format.type, "json_schema")
assert.equal(output.options.response_format.json_schema.strict, true)
assert.deepEqual(output.options.response_format.json_schema.schema.properties.text, { const: "готово" })

// Reasoning вимикається САМЕ камелькейсом. `@ai-sdk/openai-compatible` бере
// значення зі схеми опцій (`reasoningEffort`) і ним ЖЕ перетирає будь-який
// passthrough `reasoning_effort` у тілі запиту, тому snake_case не доходить до
// провайдера взагалі · виміряно по THINK у кожній smoke-сесії.
assert.equal(output.options.reasoningEffort, "none")
assert.equal(output.options.reasoning_effort, undefined)
// `think` не надсилається нікому: Ollama `/v1` його ігнорує (виміряно).
assert.equal(output.options.think, undefined)

// Той самий важіль для локального маршруту, без провайдер-специфічних додатків.
const ollamaOutput = { options: {} }
await hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "ollama-local", id: "model" } }, ollamaOutput)
assert.equal(ollamaOutput.options.reasoningEffort, "none")
assert.equal(ollamaOutput.options.think, undefined)

// Константа `.env` керує значенням; `off` не надсилає нічого.
writeFileSync(join(directory, ".env"), "BDO_API_KEY_PROD=secret\nBDO_REASONING_EFFORT=low\n")
const lowOutput = { options: {} }
await hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "ollama-local", id: "model" } }, lowOutput)
assert.equal(lowOutput.options.reasoningEffort, "low")

writeFileSync(join(directory, ".env"), "BDO_REASONING_EFFORT=off\n")
const offOutput = { options: {} }
await hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "model" } }, offOutput)
assert.equal(offOutput.options.reasoningEffort, undefined)
assert.equal(offOutput.options.response_format.type, "json_schema", "off вимикає лише reasoning, не схему")

writeFileSync(join(directory, ".env"), "BDO_REASONING_EFFORT=maximum\n")
await assert.rejects(
  hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "model" } }, { options: {} }),
  /BDO_REASONING_EFFORT/,
)
writeFileSync(join(directory, ".env"), "BDO_API_KEY_PROD=secret\n")
const defaultOutput = { options: {} }
await hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "model" } }, defaultOutput)
assert.equal(defaultOutput.options.reasoningEffort, "none", "без константи діє none")

// Модель, яка не вміє `none`, отримує МІНІМАЛЬНИЙ зі своїх значень, а не
// значення поза переліком: гейтвей на нього або мовчить, або відповідає 400
// посеред пачки. Перелік беремо з локального каталогу models.dev.
writeFileSync(join(directory, "models.json"), JSON.stringify({
  free: {
    models: {
      model: { reasoning: true, reasoning_options: [{ type: "effort", values: ["low", "high", "max"] }] },
      "only-big": { reasoning: true, reasoning_options: [{ type: "effort", values: ["high", "max"] }] },
      "knows-none": { reasoning: true, reasoning_options: [{ type: "effort", values: ["none", "low"] }] },
      plain: { reasoning: false },
    },
  },
}))
process.env.OPENCODE_MODELS_CACHE = join(directory, "models.json")
const catalogHooks = await TranslationRoutingGuard({ directory })
const clamped = { options: {} }
await catalogHooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "model" } }, clamped)
assert.equal(clamped.options.reasoningEffort, "low", "none недоступний · беремо мінімальний підтримуваний")

const honoured = { options: {} }
await catalogHooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "knows-none" } }, honoured)
assert.equal(honoured.options.reasoningEffort, "none", "модель уміє none · шлемо саме none")

// Модель без роздумів не отримує параметра взагалі.
const plain = { options: {} }
await catalogHooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "plain" } }, plain)
assert.equal(plain.options.reasoningEffort, undefined, "модель без reasoning не отримує effort")

// Каталог недоступний · поводимось як раніше, без падіння.
process.env.OPENCODE_MODELS_CACHE = join(directory, "missing-catalog.json")
const noCatalog = { options: {} }
await catalogHooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "plain" } }, noCatalog)
assert.equal(noCatalog.options.reasoningEffort, "none", "без каталогу шлемо бажане значення")
delete process.env.OPENCODE_MODELS_CACHE

const terminologyOutput = { options: {} }
await hooks["chat.params"]({ agent: "translation-terminology", model: { providerID: "free", id: "model" } }, terminologyOutput)
assert.equal(terminologyOutput.options.response_format.json_schema.name, "terminology")
assert.equal(terminologyOutput.options.response_format.json_schema.schema.items.additionalProperties, false)

await assert.rejects(
  hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "other", id: "model" } }, { options: {} }),
  /stopped: required route/,
)
await assert.rejects(
  hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "paid", id: "model" } }, { options: {} }),
  /Paid translation route/,
)
console.log("routing guard: OK")
