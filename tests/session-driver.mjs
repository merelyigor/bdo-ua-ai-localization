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
    async promptAsync(input) {
      prompts += 1
      models.push(input.body.model)
      if (prompts === 1) throw new TypeError("fetch failed")
      return { data: undefined }
    },
    async messages() {
      return { data: [{
        info: { role: "assistant", time: { completed: Date.now() } },
        parts: [{ type: "text", text: '[{"identity_hash":"h","text":"Текст"}]' }],
      }] }
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

const failedDirectory = mkdtempSync(join(tmpdir(), "bdo-session-circuit-"))
mkdirSync(join(failedDirectory, "state", "batch"), { recursive: true })
mkdirSync(join(failedDirectory, ".opencode"), { recursive: true })
writeFileSync(join(failedDirectory, "state", "batch", "payload.json"), '{"request":"test"}\n')
writeFileSync(join(failedDirectory, ".opencode", "translation-models.json"), JSON.stringify({
  active_profile: "test",
  profiles: { test: { routes: { "translation-worker": ["local/only"] } } },
}))
let failedCreates = 0
const failingHooks = await TranslationSessionDriver({
  directory: failedDirectory,
  client: { session: {
    async create() { failedCreates += 1; return { data: { id: `failed-${failedCreates}` } } },
    async promptAsync() { throw new TypeError("fetch failed", { cause: new Error("connection refused") }) },
    async messages() { return { data: [] } },
    async abort() { return { data: true } },
  } },
})
const failedArgs = { role: "translation-worker", payload_path: "batch/payload.json", response_path: "batch/response.json" }
const failedContext = { sessionID: "parent", metadata() {} }
const failedResult = await failingHooks.tool.translation_child.execute(failedArgs, failedContext)
assert.equal(JSON.parse(failedResult.output).circuit_open, true)
assert.equal(failedCreates, 3)
const failure = JSON.parse(readFileSync(join(failedDirectory, "state", "batch", "response.json.failure.json"), "utf8"))
assert.equal(failure.attempts[0].cause, "Error: connection refused")
const repeatedResult = await failingHooks.tool.translation_child.execute(failedArgs, failedContext)
assert.deepEqual(JSON.parse(repeatedResult.output), { ok: false, circuit_open: true, action: "stop", attempts: 3, command: "./bdo retry status" })
assert.equal(failedCreates, 3, "open circuit created more child sessions")

console.log("session driver: OK")
