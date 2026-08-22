import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { TranslationSessionDriver } from "../.opencode/plugin/translation-session-driver.ts"

const directory = mkdtempSync(join(tmpdir(), "bdo-session-driver-"))
mkdirSync(join(directory, "state", "batch"), { recursive: true })
mkdirSync(join(directory, ".opencode"), { recursive: true })
writeFileSync(join(directory, "state", "batch", "payload.json"), '[{"identity_hash":"h","source_text":"Text"}]\n')
writeFileSync(join(directory, ".opencode", "translation-models.json"), JSON.stringify({
  active_profile: "test",
  profiles: { test: { routes: { "translation-worker": ["local/first", "remote/fallback"] } } },
}))

const parents = []
const aborted = []
let prompts = 0
const models = []
const client = {
  session: {
    async create(input) {
      parents.push(input.body.parentID)
      return { data: { id: `child-${parents.length}` } }
    },
    async prompt(input) {
      prompts += 1
      models.push(input.body.model)
      if (prompts === 1) return { data: { parts: [] } }
      return { data: { parts: [{ type: "text", text: '[{"identity_hash":"h","text":"Текст"}]' }] } }
    },
    async abort(input) {
      aborted.push(input.path.id)
      return { data: true }
    },
  },
}

const hooks = await TranslationSessionDriver({ client, directory })
const result = await hooks.tool.translation_child.execute({
  role: "translation-worker",
  payload_path: "batch/payload.json",
  response_path: "batch/response.json",
}, {
  sessionID: "parent-session",
  metadata() {},
})

assert.equal(JSON.parse(result.output).attempt, 2)
assert.deepEqual(parents, ["parent-session", "parent-session"])
assert.deepEqual(aborted, ["child-1"])
assert.deepEqual(models, [{ providerID: "local", modelID: "first" }, { providerID: "remote", modelID: "fallback" }])
assert.match(readFileSync(join(directory, "state", "batch", "response.json"), "utf8"), /Текст/)
const sidecar = JSON.parse(readFileSync(join(directory, "state", "batch", "response.json.session.json"), "utf8"))
assert.equal(sidecar.attempts.length, 2)
assert.equal(sidecar.child_session_id, "child-2")
assert.equal(sidecar.route, "remote/fallback")

console.log("session driver: OK")
