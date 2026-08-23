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
    routes: { "translation-smoke": ["free/model", "paid/model"], "translation-worker": ["free/model"], "translation-terminology": ["free/model"] },
  } },
}))

const hooks = await TranslationRoutingGuard({ directory })
const output = { options: {} }
await hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "free", id: "model" } }, output)
assert.equal(output.options.response_format.type, "json_schema")
assert.equal(output.options.response_format.json_schema.strict, true)

const terminologyOutput = { options: {} }
await hooks["chat.params"]({ agent: "translation-terminology", model: { providerID: "free", id: "model" } }, terminologyOutput)
assert.equal(terminologyOutput.options.response_format.json_schema.name, "terminology")
assert.equal(terminologyOutput.options.response_format.json_schema.schema.items.additionalProperties, false)

await assert.rejects(
  hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "other", id: "model" } }, { options: {} }),
  /requires one of/,
)
await assert.rejects(
  hooks["chat.params"]({ agent: "translation-smoke", model: { providerID: "paid", id: "model" } }, { options: {} }),
  /Paid translation route/,
)
console.log("routing guard: OK")
