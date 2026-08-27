// agent-bus plugin for OpenCode — bus delivery via digest injection, idle
// wake (Stop-hook analog), and session-unique identity.
//
// Design rule: this plugin implements no bus logic. Every decision (what is
// unread, what wakes a seat, budget caps, staleness) is made by the agent-bus
// CLI; the plugin only moves bytes between the CLI and the host. All failures
// are swallowed — the plugin must never break or delay a host turn.

import type { Plugin } from "@opencode-ai/plugin"
import type { TextPartInput } from "@opencode-ai/sdk"

const BIN = process.env.AGENT_BUS_BIN || "agent-bus"

export default (async ({ client, directory }) => {
  // Bus commands must resolve identity from THIS session's worktree, not the
  // server process's launch dir (project picker / $HOME launches otherwise
  // land every session of this host on one seat).
  async function run(args: string[], extraEnv: Record<string, string> = {}) {
    try {
      const proc = Bun.spawn([BIN, ...args], {
        cwd: directory,
        stdin: "ignore",
        stdout: "pipe",
        stderr: "ignore",
        env: { ...process.env, ...extraEnv },
      })
      const out = await new Response(proc.stdout).text()
      await proc.exited
      // Nonzero exit (no agent-bus on PATH, bus misconfigured) degrades to empty.
      return proc.exitCode === 0 ? out.trim() : ""
    } catch {
      return ""
    }
  }

  const sessions = new Map<string, { idle: boolean; polling: boolean }>()

  const env = (sessionID: string) => ({
    AGENT_BUS_VIA: "hook",
    AGENT_BUS_TOOL: "opencode",
    OPENCODE_SESSION_ID: sessionID,
  })

  async function wake(sessionID: string) {
    const state = sessions.get(sessionID)
    if (!state?.idle || state.polling) return
    state.polling = true
    try {
      // Stop-hook is the single source of truth for watch on/off, unread
      // selection, MAX_SHOWS, WAKE_BUDGET, and the PM stale-thread nag.
      const verdict = await run(["stop-hook"], env(sessionID))
      if (!verdict) return
      let parsed: { decision?: string; reason?: string }
      try {
        parsed = JSON.parse(verdict)
      } catch {
        return
      }
      if (parsed.decision !== "block" || !parsed.reason) return
      state.idle = false
      const parts: TextPartInput[] = [{ type: "text", synthetic: true, text: parsed.reason }]
      await client.session.promptAsync({
        path: { id: sessionID },
        query: { directory },
        body: { parts },
      })
    } catch {
      // Already-idle wake is best-effort and must never break the host.
    } finally {
      state.polling = false
    }
  }

  // session.idle only fires at a turn boundary. Polling while a primary
  // session remains idle closes the gap where a packet arrives afterward.
  // The timer lives inside OpenCode — no daemon or external server required.
  const configuredInterval = Number(process.env.AGENT_BUS_OPENCODE_POLL_MS || 2000)
  const pollInterval = Number.isFinite(configuredInterval) && configuredInterval >= 250 ? configuredInterval : 2000
  const timer = setInterval(() => {
    for (const sessionID of sessions.keys()) void wake(sessionID)
  }, pollInterval)
  timer.unref?.()

  return {
    // Stamp every primary-session Bash child with its exact session identity,
    // so shell commands and plugin-run digest/stop-hook share one seat.
    "shell.env": async (input, output) => {
      output.env.AGENT_BUS_TOOL = "opencode"
      if (input.sessionID && sessions.has(input.sessionID)) {
        output.env.OPENCODE_SESSION_ID = input.sessionID
      }
    },

    event: async ({ event }) => {
      try {
        if (event.type === "session.created") {
          const info = event.properties.info
          // Subagent/child sessions must not rebind the plugin's identity:
          // digest injection and idle wake belong to the primary session.
          if (info.parentID) return
          sessions.set(info.id, { idle: false, polling: false })
          // SessionStart analog: surface unread packets as silent context.
          const digest = await run(["digest"], env(info.id))
          if (digest) {
            const parts: TextPartInput[] = [{ type: "text", synthetic: true, text: digest }]
            void client.session
              .prompt({
                path: { id: info.id },
                query: { directory },
                body: { noReply: true, parts },
              })
              .catch(() => {})
          }
          return
        }

        if (event.type === "session.idle") {
          const sid = event.properties.sessionID
          const state = sessions.get(sid)
          if (!state) return
          state.idle = true
          await wake(sid)
          return
        }

        if (event.type === "session.deleted") {
          sessions.delete(event.properties.info.id)
        }
      } catch {
        // Never break the host event loop.
      }
    },

    // UserPromptSubmit analog: prepend unread mail to each prompt turn,
    // verbatim from `agent-bus digest` (sanitized, capped, silent when empty).
    "chat.message": async (input, output) => {
      try {
        const state = sessions.get(input.sessionID)
        // Ignore child/subagent sessions skipped by session.created above.
        if (!state) return
        state.idle = false
        const digest = await run(["digest"], env(input.sessionID))
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
}) satisfies Plugin
