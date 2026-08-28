import { existsSync, readFileSync } from "node:fs"
import { createHash } from "node:crypto"
import { resolve } from "node:path"

export const RUNTIME_MODEL_SCHEMA = 1

export type RuntimeModelState = {
  schema_version: number
  fingerprint: string
  active_profile: string
  routes: Record<string, string[]>
  generated_at: string
}

const TOOLKIT_DIR = process.env.TRANSLATE_TOOLKIT_DIR ?? "."

/**
 * Ролі НЕ перелічені тут навмисно.
 *
 * 2026-08-28 сьома роль `translation-glossary` зʼявилась у `ModelPolicy::ROLES`
 * (PHP), а цей файл лишився з шістьма. Materializer рахував відбиток по семи
 * маршрутах, читач · по шести, і кожен child падав із
 * `OPENCODE_RUNTIME_INVALID: fingerprint does not match the effective model
 * policy`. Два списки того самого завжди розходяться, тому перелік ролей тут
 * береться з ЕФЕКТИВНОЇ політики, а відбиток рахується по відсортованих
 * ключах · так порядок ключів у JSON не впливає на результат.
 */
function policyRoutes(profile: unknown): Record<string, string[]> {
  const raw = (profile as { routes?: Record<string, unknown> } | null | undefined)?.routes
  if (typeof raw !== "object" || raw === null) {
    throw new Error("OPENCODE_RUNTIME_INVALID: effective profile has no routes.")
  }
  const routes: Record<string, string[]> = {}
  for (const role of Object.keys(raw).sort()) {
    const route = raw[role]
    if (!Array.isArray(route) || route.length === 0 || route.some((item: unknown) => typeof item !== "string")) {
      throw new Error(`OPENCODE_RUNTIME_INVALID: effective route ${role} is missing or malformed.`)
    }
    routes[role] = route as string[]
  }
  if (Object.keys(routes).length === 0) {
    throw new Error("OPENCODE_RUNTIME_INVALID: effective profile has no routes.")
  }
  return routes
}

/** Відсортовані ключі · відбиток не має залежати від порядку в файлі. */
function sortedRoutes(routes: Record<string, string[]>): Record<string, string[]> {
  const sorted: Record<string, string[]> = {}
  for (const role of Object.keys(routes).sort()) sorted[role] = routes[role]
  return sorted
}

export function runtimeModelStatePath(directory: string): string {
  return resolve(directory, TOOLKIT_DIR, ".opencode/runtime-model-state.json")
}

export function runtimeModelBusyPath(directory: string): string {
  return resolve(directory, TOOLKIT_DIR, ".opencode/runtime-model-state.busy")
}

/** Fail-closed reader: модельний Task не стартує з неповним runtime. */
export function readRuntimeModelState(directory: string): RuntimeModelState {
  if (existsSync(runtimeModelBusyPath(directory))) {
    throw new Error("OPENCODE_RUNTIME_INVALID: model runtime is being materialized; wait for ./bdo env to finish.")
  }
  let value: unknown
  try {
    value = JSON.parse(readFileSync(runtimeModelStatePath(directory), "utf8"))
  } catch {
    throw new Error("OPENCODE_RUNTIME_INVALID: model runtime fingerprint is missing or unreadable.")
  }
  const state = value as Partial<RuntimeModelState>
  if (
    state.schema_version !== RUNTIME_MODEL_SCHEMA
    || typeof state.fingerprint !== "string"
    || !/^[a-f0-9]{64}$/.test(state.fingerprint)
    || typeof state.active_profile !== "string"
    || state.active_profile === ""
    || typeof state.routes !== "object"
    || state.routes === null
  ) {
    throw new Error("OPENCODE_RUNTIME_INVALID: unsupported or malformed model runtime fingerprint.")
  }
  let policy: any
  try {
    policy = JSON.parse(readFileSync(resolve(directory, TOOLKIT_DIR, ".opencode/translation-models.json"), "utf8"))
  } catch {
    throw new Error("OPENCODE_RUNTIME_INVALID: effective model policy is missing or unreadable.")
  }
  const active = policy?.active_profile
  const profile = policy?.profiles?.[active]
  const routes = policyRoutes(profile)
  const canonical = JSON.stringify({ schema_version: RUNTIME_MODEL_SCHEMA, active_profile: active, routes })
  const actual = createHash("sha256").update(canonical).digest("hex")
  const stateRoutes = JSON.stringify(sortedRoutes(state.routes as Record<string, string[]>))
  if (actual !== state.fingerprint || active !== state.active_profile || JSON.stringify(routes) !== stateRoutes) {
    throw new Error("OPENCODE_RUNTIME_INVALID: fingerprint does not match the effective model policy.")
  }
  return state as RuntimeModelState
}
