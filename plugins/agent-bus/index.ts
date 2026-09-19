// agent-bus plugin for OpenCode — bus delivery via digest injection, idle
// wake (Stop-hook analog), and session-unique identity.
//
// Design rule: this plugin implements no bus logic. Every decision (what is
// unread, what wakes a seat, budget caps, staleness) is made by the agent-bus
// CLI; the plugin only moves bytes between the CLI and the host. All failures
// are swallowed — the plugin must never break or delay a host turn.
//
// One file serves OpenCode 1 and 2. OpenCode 2 reads the default export's `id`
// and `setup()`; OpenCode 1 calls `server()` and uses the hooks it returns.
// The two runtimes share `runner()` below, so the bus contract cannot drift
// between them — only the host bindings differ.
//
// The v2 bindings, and why each one:
//   digest at session start   event session.created -> session.synthetic(queue)
//   digest at prompt          session.hook("prompt") -> prepend to prompt text
//   idle wake                 event session.idle    -> session.synthetic(resume)
//   seat identity in shells   shell.hook("create.before") -> event.env
//
// v1's `client.session.promptAsync` has no v2 counterpart; `session.synthetic`
// with `resume: true` is the supported way to re-enter an idle session, and it
// marks the text as synthetic rather than forging a user turn.
//
// Imports are TYPE-ONLY on purpose. The installer copies this single file into
// ~/.config/opencode/plugins/agent-bus/, which has no node_modules, so any
// value import fails at load with "Cannot find package". `Plugin.define` is an
// identity function (it returns its argument unchanged), so the default export
// is written as the plain object it would have produced.

import type { Plugin } from "@opencode/plugin"

const BIN = process.env.AGENT_BUS_BIN || "agent-bus"

type Json = Record<string, unknown>

/**
 * Spawn the CLI. Never throws; a missing or failing binary degrades to "".
 * Bounded: `digest` runs inside prompt admission, so a wedged bus (a stuck
 * lock, an NFS-stalled ledger) would otherwise hold up the user's own turn.
 */
const RUN_TIMEOUT_MS = (() => {
  const n = Number(process.env.AGENT_BUS_OPENCODE_TIMEOUT_MS || 5000)
  return Number.isFinite(n) && n >= 500 ? n : 5000
})()

async function runIn(directory: string, args: string[], extraEnv: Record<string, string> = {}) {
  let proc: ReturnType<typeof Bun.spawn> | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    proc = Bun.spawn([BIN, ...args], {
      cwd: directory,
      stdin: "ignore",
      stdout: "pipe",
      stderr: "ignore",
      env: { ...process.env, ...extraEnv },
    })
    const p = proc
    let timedOut = false
    timer = setTimeout(() => {
      timedOut = true
      try {
        p.kill()
      } catch {
        // Already gone.
      }
    }, RUN_TIMEOUT_MS)
    const out = await new Response(p.stdout).text()
    await p.exited
    return !timedOut && p.exitCode === 0 ? out.trim() : ""
  } catch {
    return ""
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/**
 * Host-independent bus logic. `directory` pins identity to this session's
 * worktree rather than the server process's launch dir — without it a project
 * picker or $HOME launch lands every session of the host on one seat.
 */
function runner(directory: string) {
  // Primary sessions only. Subagent/child sessions must not rebind identity:
  // digest injection and idle wake belong to the session the human is in.
  const sessions = new Map<string, { idle: boolean; polling: boolean }>()
  // Which session's turn is currently running. v2's shell create.before event
  // carries no sessionID (v1's shell.env did), so this is how a Bash child
  // still gets stamped with the session that spawned it. Best-effort: with two
  // sessions executing at once the last starter wins, and the CLI then falls
  // back to its own detection rather than taking a wrong id.
  let executing: string | undefined

  // Env for CLI calls the PLUGIN makes. VIA=hook is what lets `agent-bus
  // doctor` prove lifecycle delivery is firing, so it belongs only here.
  const env = (sessionID?: string) => ({
    AGENT_BUS_VIA: "hook",
    AGENT_BUS_TOOL: "opencode",
    ...(sessionID ? { OPENCODE_SESSION_ID: sessionID } : {}),
  })

  const run = (args: string[], sessionID?: string) => runIn(directory, args, env(sessionID))

  return {
    sessions,
    track(sessionID: string, parentID?: string) {
      if (parentID) return false
      sessions.set(sessionID, { idle: false, polling: false })
      return true
    },
    forget(sessionID: string) {
      sessions.delete(sessionID)
      if (executing === sessionID) executing = undefined
    },
    startExecuting(sessionID: string) {
      if (sessions.has(sessionID)) executing = sessionID
    },
    stopExecuting(sessionID: string) {
      if (executing === sessionID) executing = undefined
    },
    /**
     * Env stamped onto shell children so a seat's shell and its hooks agree.
     *
     * Deliberately NOT env() above. A shell command the agent runs is a CLI
     * call, not a lifecycle hook fire: stamping VIA=hook on it made every such
     * command register as a hook touch, which is the one signal `doctor` uses
     * to prove hooks work. The tool pin is always sent — without it the shell
     * resolves to a markerless `shell/<worktree>` seat, splitting identity the
     * other way — and the session id only when the executing session is known.
     */
    shellEnv(sessionID = executing) {
      const sid = sessionID && sessions.has(sessionID) ? sessionID : undefined
      return {
        AGENT_BUS_TOOL: "opencode",
        ...(sid ? { OPENCODE_SESSION_ID: sid } : {}),
      }
    },
    digest: (sessionID: string) => run(["digest"], sessionID),
    /**
     * Ask the CLI whether this seat should be continued, and deliver the
     * continuation. stop-hook is the single source of truth for watch on/off,
     * unread selection, MAX_SHOWS, WAKE_BUDGET, and the PM stale-thread nag.
     *
     * The CLI spends a wake against WAKE_BUDGET inside stop-hook, before this
     * process knows whether the host accepted the text. So `deliver` is awaited
     * and retried once before the session is marked woken: an injection the
     * host dropped would otherwise burn a wake AND leave the packet unsurfaced
     * until the budget ran out. The packet itself is never lost either way —
     * stop-hook does not mark it read, so the next digest still carries it.
     */
    async wake(sessionID: string, deliver: (text: string) => Promise<boolean>) {
      const state = sessions.get(sessionID)
      if (!state?.idle || state.polling) return
      state.polling = true
      try {
        const verdict = await run(["stop-hook"], sessionID)
        if (!verdict) return
        let parsed: { decision?: string; reason?: string }
        try {
          parsed = JSON.parse(verdict)
        } catch {
          return
        }
        if (parsed.decision !== "block" || !parsed.reason) return
        const text = parsed.reason
        const sent = (await deliver(text)) || (await deliver(text))
        // Marked woken on success, and on a doubly-failed delivery too: the
        // budget is already spent, and retrying forever would spend the rest.
        state.idle = false
        return sent
      } catch {
        return
      } finally {
        state.polling = false
      }
    },
    markIdle(sessionID: string) {
      const state = sessions.get(sessionID)
      if (!state) return false
      state.idle = true
      return true
    },
    markBusy(sessionID: string) {
      const state = sessions.get(sessionID)
      if (state) state.idle = false
    },
  }
}

/**
 * session.idle fires only at a turn boundary, so a packet that lands while a
 * session sits idle would wait for the next human prompt. Polling closes that
 * gap from inside the host — no daemon, no external server.
 */
/** Trailing-slash-insensitive directory comparison for event ownership. */
function sameDir(a: string | undefined, b: string | undefined) {
  if (!a || !b) return false
  const trim = (d: string) => (d.length > 1 ? d.replace(/\/+$/, "") : d)
  return trim(a) === trim(b)
}

function pollEvery(tick: () => void) {
  const configured = Number(process.env.AGENT_BUS_OPENCODE_POLL_MS || 2000)
  const ms = Number.isFinite(configured) && configured >= 250 ? configured : 2000
  const timer = setInterval(tick, ms)
  ;(timer as { unref?: () => void }).unref?.()
  return () => clearInterval(timer)
}

// ------------------------------------------------------------------ v2

const v2: Plugin.Plugin = {
  id: "agent-bus",
  async setup(ctx: Plugin.Context) {
    const bus = runner(ctx.location.directory)

    // Injecting the digest as a synthetic message keeps it out of the user's
    // own text and marks its provenance in the transcript. "queue" delivers it
    // at the next turn; wake uses "steer" + resume to re-enter a stopped one.
    const inject = async (sessionID: string, text: string, wake: boolean) => {
      try {
        await ctx.session.synthetic({
          sessionID,
          text,
          description: wake ? "agent-bus wake" : "agent-bus digest",
          delivery: wake ? "steer" : "queue",
          resume: wake,
        })
        return true
      } catch {
        // Reported, not swallowed: a wake has already been spent against
        // WAKE_BUDGET by the time we get here, so the caller retries rather
        // than losing the continuation silently.
        return false
      }
    }

    // Registrations live for the plugin's lifetime, so they are disposed in
    // the cleanup below rather than left dangling on a reload — the installer
    // rewrites this file in place, and the host watches it.
    const registrations: Array<{ dispose: () => Promise<void> }> = []

    registrations.push(await ctx.shell.hook("create.before", (event) => {
      try {
        Object.assign(event.env, bus.shellEnv())
      } catch {
        // Never block a shell.
      }
    }))

    // UserPromptSubmit analog. The v2 prompt hook exposes the prompt itself
    // rather than a parts array, and it runs inside prompt admission — calling
    // back into the server from here would re-enter the path being admitted.
    // Prepending is therefore both the faithful equivalent of v1's synthetic
    // part and the only ordering-safe option: the digest is in front of the
    // user's words before the model sees either.
    registrations.push(await ctx.session.hook("prompt", async (event) => {
      try {
        const sessionID = String(event.sessionID)
        if (!bus.sessions.has(sessionID)) return
        bus.markBusy(sessionID)
        const digest = await bus.digest(sessionID)
        if (digest) event.prompt.text = `${digest}\n\n${event.prompt.text}`
      } catch {
        // Never break prompt submission.
      }
    }))

    // Ownership. ctx.event.subscribe is the SERVER's stream, not this
    // project's: with four projects open, four plugin instances each see every
    // session's events. Unfiltered, each one claimed the same chat under its
    // own directory and a single session registered as several seats — the
    // identity split this bus exists to prevent.
    //
    // Ownership is resolved by looking the session up once, not by reading
    // session.created: that event does not reach the stream for every entry
    // point (`opencode run` produced none), so a create-only filter tracked
    // nothing at all. The lookup also supplies parentID, which keeps subagent
    // sessions from rebinding identity.
    const verdict = new Map<string, boolean>()
    const owned = async (sessionID: string) => {
      const cached = verdict.get(sessionID)
      if (cached !== undefined) return cached
      let mine = false
      try {
        const info = await ctx.session.get({ sessionID })
        mine = !info.parentID && sameDir(info.location?.directory, ctx.location.directory)
      } catch {
        // A lookup that failed is unknown, not foreign. Caching false here
        // would disown the session for the rest of its life on one blip.
        return false
      }
      verdict.set(sessionID, mine)
      if (mine && bus.track(sessionID)) {
        // SessionStart analog, on first sight rather than on session.created.
        const digest = await bus.digest(sessionID)
        if (digest) await inject(sessionID, digest, false)
      }
      return mine
    }

    const controller = new AbortController()
    void (async () => {
      try {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          try {
            if (!String(event.type).startsWith("session.")) continue
            const data = (event as { data?: Json }).data ?? {}
            const sid = typeof data.sessionID === "string" ? data.sessionID : undefined
            if (!sid) continue
            if (event.type === "session.deleted") {
              verdict.delete(sid)
              bus.forget(sid)
              continue
            }
            if (!(await owned(sid))) continue
            switch (event.type) {
              case "session.execution.started":
                bus.startExecuting(sid)
                break
              case "session.execution.succeeded":
              case "session.execution.failed":
              case "session.execution.interrupted":
                bus.stopExecuting(sid)
                break
              case "session.idle": {
                if (!bus.markIdle(sid)) break
                await bus.wake(sid, (text) => inject(sid, text, true))
                break
              }
            }
          } catch {
            // One bad event must not end the subscription.
          }
        }
      } catch {
        // Subscription ended (abort on cleanup, or host shutdown).
      }
    })()

    const stopPolling = pollEvery(() => {
      for (const sessionID of bus.sessions.keys()) {
        void (async () => {
          await bus.wake(sessionID, (text) => inject(sessionID, text, true))
        })()
      }
    })

    return async () => {
      stopPolling()
      controller.abort()
      await Promise.all(
        registrations.map((r) =>
          r.dispose().catch(() => {
            // Host may already have torn the registration down.
          }),
        ),
      )
    }
  },
}

// ------------------------------------------------------------------ v1
//
// Kept verbatim in behavior so an OpenCode 1 host upgrading the plugin file
// sees no change. v1 pushes a synthetic part into the message and wakes an
// idle chat through promptAsync; neither API exists in v2.

async function server() {
  return async ({ client, directory }: any) => {
    const bus = runner(directory)

    const wake = (sessionID: string) =>
      bus.wake(sessionID, async (text) => {
        try {
          await client.session.promptAsync({
            path: { id: sessionID },
            query: { directory },
            body: { parts: [{ type: "text", synthetic: true, text }] },
          })
          return true
        } catch {
          // Already-idle wake is best-effort and must never break the host.
          return false
        }
      })

    pollEvery(() => {
      for (const sessionID of bus.sessions.keys()) void wake(sessionID)
    })

    return {
      "shell.env": async (input: any, output: any) => {
        Object.assign(output.env, bus.shellEnv(input?.sessionID))
      },

      event: async ({ event }: any) => {
        try {
          if (event.type === "session.created") {
            const info = event.properties.info
            if (!bus.track(info.id, info.parentID)) return
            const digest = await bus.digest(info.id)
            if (digest) {
              void client.session
                .prompt({
                  path: { id: info.id },
                  query: { directory },
                  body: { noReply: true, parts: [{ type: "text", synthetic: true, text: digest }] },
                })
                .catch(() => {})
            }
            return
          }
          if (event.type === "session.idle") {
            const sid = event.properties.sessionID
            if (bus.markIdle(sid)) await wake(sid)
            return
          }
          if (event.type === "session.deleted") bus.forget(event.properties.info.id)
        } catch {
          // Never break the host event loop.
        }
      },

      "chat.message": async (input: any, output: any) => {
        try {
          if (!bus.sessions.has(input.sessionID)) return
          bus.markBusy(input.sessionID)
          const digest = await bus.digest(input.sessionID)
          if (digest && output.parts) {
            // Parts here are already persisted-shaped (assign() ran before the
            // hook), so a pushed part must carry a valid prt_-prefixed id —
            // fabricated message-derived ids fail the server's part schema and
            // kill the whole prompt submission.
            output.parts.push({
              id: `prt_bus_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`,
              sessionID: output.message.sessionID,
              messageID: output.message.id,
              type: "text",
              synthetic: true,
              text: digest,
            })
          }
        } catch {
          // Never break prompt submission.
        }
      },
    }
  }
}

export default { ...v2, server }
