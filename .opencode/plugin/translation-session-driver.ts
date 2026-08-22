import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname, relative, resolve, sep } from "node:path"
import { tool, type Plugin } from "@opencode-ai/plugin"

const ROLES = new Set(["translation-terminology", "translation-worker", "translation-qa", "translation-repair", "translation-smoke"])
const TOOLKIT_DIR = process.env.TRANSLATE_TOOLKIT_DIR ?? "."

type ModelPolicy = { active_profile: string; profiles: Record<string, { routes: Record<string, string[]> }> }

function roleRoutes(directory: string, role: string): string[] {
  const policy = JSON.parse(readFileSync(resolve(directory, TOOLKIT_DIR, ".opencode/translation-models.json"), "utf8")) as ModelPolicy
  const routes = policy.profiles[policy.active_profile]?.routes[role] ?? []
  if (routes.length === 0) throw new Error(`No model route configured for ${role}.`)
  return routes
}

function splitRoute(route: string): { providerID: string; modelID: string } {
  const slash = route.indexOf("/")
  if (slash < 1 || slash === route.length - 1) throw new Error(`Invalid model route: ${route}.`)
  return { providerID: route.slice(0, slash), modelID: route.slice(slash + 1) }
}

function inside(root: string, path: string): string {
  const absolute = resolve(root, path)
  const rel = relative(root, absolute)
  if (rel === "" || rel.startsWith(`..${sep}`) || rel === "..") {
    throw new Error("Artifact path must name a file below the project state directory.")
  }
  return absolute
}

function atomicWrite(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  const temp = `${path}.tmp.${crypto.randomUUID()}`
  writeFileSync(temp, content)
  renameSync(temp, path)
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => {
        timer = setTimeout(() => reject(new Error(`OpenCode child timeout after ${timeoutMs}ms.`)), timeoutMs)
      }),
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/**
 * The only production entrypoint that creates translation child sessions.
 * Payload never enters the primary agent context: the plugin reads its staged
 * artifact and sends it directly to the constrained child prompt.
 */
export const TranslationSessionDriver: Plugin = async ({ client, directory }) => ({
  tool: {
    translation_child: tool({
      description: "Run one constrained OpenCode translation child from a staged artifact and save only its response artifact.",
      args: {
        role: tool.schema.enum(["translation-terminology", "translation-worker", "translation-qa", "translation-repair", "translation-smoke"]),
        payload_path: tool.schema.string().min(1),
        response_path: tool.schema.string().min(1),
      },
      async execute(args, context) {
        if (!ROLES.has(args.role)) throw new Error("Unsupported translation role.")

        const payloadPath = inside(resolve(directory, "state"), args.payload_path)
        const responsePath = inside(resolve(directory, "state"), args.response_path)
        const payload = readFileSync(payloadPath, "utf8")
        if (payload.trim() === "") throw new Error("The staged child payload is empty.")

        const routes = roleRoutes(directory, args.role)
        const attempts: Array<{ attempt: number; route: string; child_session_id?: string; error?: string }> = []
        const timeoutMs = 15 * 60 * 1000
        const maximumAttempts = Math.max(3, routes.length)
        for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
          const route = routes[Math.min(attempt - 1, routes.length - 1)]
          let childID: string | undefined
          try {
            const created = await client.session.create({
              query: { directory },
              body: { parentID: context.sessionID, title: `translation ${args.role} #${attempt}` },
            })
            if (!created.data) throw new Error("OpenCode did not create a child session.")
            childID = created.data.id
            const prompted = await withTimeout(client.session.prompt({
              path: { id: childID }, query: { directory },
              body: { agent: args.role, model: splitRoute(route), tools: { "*": false }, parts: [{ type: "text", text: payload }] },
            }), timeoutMs)
            if (!prompted.data) throw new Error("OpenCode child completed without an assistant message.")
            const content = prompted.data.parts.filter((part) => part.type === "text").map((part) => part.text).join("")
            if (content.trim() === "") throw new Error("OpenCode child returned an empty response.")
            attempts.push({ attempt, route, child_session_id: childID })
            atomicWrite(responsePath, content)
            atomicWrite(`${responsePath}.session.json`, JSON.stringify({
              role: args.role, route, parent_session_id: context.sessionID, child_session_id: childID,
              payload_bytes: Buffer.byteLength(payload), response_bytes: Buffer.byteLength(content),
              attempts, completed_at: new Date().toISOString(),
            }) + "\n")
            context.metadata({ title: `Завершено ${args.role}`, metadata: { child_session_id: childID, attempt } })
            return { title: `Завершено ${args.role}`, output: JSON.stringify({ ok: true, role: args.role, child_session_id: childID, attempt }) }
          } catch (error) {
            if (childID) await client.session.abort({ path: { id: childID }, query: { directory } }).catch(() => undefined)
            attempts.push({ attempt, route, child_session_id: childID, error: error instanceof Error ? error.message : String(error) })
            if (attempt === maximumAttempts) {
              atomicWrite(`${responsePath}.failure.json`, JSON.stringify({ role: args.role, attempts, failed_at: new Date().toISOString() }) + "\n")
              throw error
            }
          }
        }
        throw new Error("OpenCode child retry loop ended unexpectedly.")
      },
    }),
  },
})
