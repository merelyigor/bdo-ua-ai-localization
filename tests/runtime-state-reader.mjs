// Матеріалізатор (PHP) і читач (плагін) мусять зійтися на ОДНОМУ відбитку.
//
// Навіщо окремий тест. 2026-08-28 сьома роль `translation-glossary` була додана
// в `ModelPolicy::ROLES`, а список ролей у читачі лишився шестирічним. Обидві
// половини були «правильні» кожна сама по собі, тести читача будували state
// власноруч тим самим списком, і зелений gate співіснував із повністю
// заблокованим прогоном: КОЖЕН child падав із `OPENCODE_RUNTIME_INVALID`.
//
// Тому тут не будується жоден синтетичний state: його пише справжній
// `cli/runtime/model-profile.php`, а читає справжній `readRuntimeModelState`.
import { execFileSync } from "node:child_process"
import { cpSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import { readRuntimeModelState } from "../.opencode/lib/runtime-model-state.ts"

const root = process.cwd()
const home = mkdtempSync(join(tmpdir(), "bdo-runtime-state-"))
mkdirSync(join(home, ".opencode/templates"), { recursive: true })
mkdirSync(join(home, ".opencode/agent-templates"), { recursive: true })
mkdirSync(join(home, "templates"), { recursive: true })
cpSync(join(root, "templates/opencode.json"), join(home, "templates/opencode.json"))
cpSync(join(root, ".opencode/templates/translation-models.json"), join(home, ".opencode/templates/translation-models.json"))
cpSync(join(root, ".opencode/agent-templates"), join(home, ".opencode/agent-templates"), { recursive: true })

const materialize = (profile, model) =>
  execFileSync("php", [join(root, "cli/runtime/model-profile.php"), "env", profile, model, "free"], {
    env: { ...process.env, TRANSLATE_HOME: home },
    stdio: ["ignore", "pipe", "pipe"],
  })

materialize("session-free", "opencode/big-pickle")
const state = readRuntimeModelState(home)

// Ролі читаються з політики, тому їх перелік мусить збігтися з PHP-переліком
// один в один · саме розбіжність у ньому й блокувала прогін.
const phpRoles = JSON.parse(execFileSync("php", [
  "-r",
  `require '${resolve(root, "lib/autoload.php")}'; echo json_encode(\\Bdo\\Translate\\Runtime\\ModelPolicy::ROLES);`,
], { encoding: "utf8" }))
const stateRoles = Object.keys(state.routes).sort()
if (JSON.stringify(stateRoles) !== JSON.stringify([...phpRoles].sort())) {
  throw new Error(`ролі розійшлись: state ${stateRoles} vs ModelPolicy ${phpRoles}`)
}

// Порядок ключів у політиці не має впливати на відбиток: інакше будь-яке
// переставляння рядків у шаблоні знову заблокувало б усіх child.
const policyPath = join(home, ".opencode/translation-models.json")
const policy = JSON.parse(readFileSync(policyPath, "utf8"))
const profile = policy.profiles[policy.active_profile]
profile.routes = Object.fromEntries(Object.entries(profile.routes).reverse())
writeFileSync(policyPath, JSON.stringify(policy))
readRuntimeModelState(home)

// Справжня зміна маршруту мусить лишитись видимою для restart-gate.
profile.routes[stateRoles[0]] = ["opencode/other-model"]
writeFileSync(policyPath, JSON.stringify(policy))
let rejected = ""
try {
  readRuntimeModelState(home)
} catch (error) {
  rejected = String(error.message)
}
if (!rejected.includes("OPENCODE_RUNTIME_INVALID")) {
  throw new Error("змінений маршрут прийнято зі старим відбитком")
}

console.log("runtime state reader: OK")
