// agent-bus plugin for OpenCode — bus delivery via digest injection, idle
// wake (Stop-hook analog), session-unique identity, and HTTP push delivery.
//
// Design rule: this plugin implements no bus logic. Every decision (what is
// unread, what wakes a seat, budget caps, staleness) is made by the agent-bus
// CLI; the plugin only moves bytes between the CLI and the host. All failures
// are swallowed — the plugin must never break or delay a host turn.

import type { Plugin } from "@opencode-ai/plugin"
import type { TextPartInput } from "@opencode-ai/sdk"

const BIN = process.env.AGENT_BUS_BIN || "agent-bus"

export default (async ({ serverUrl, directory }) => {
  // The host exposes its own HTTP server address to the plugin — no probing.
  const base = (process.env.OPENCODE_SERVER_URL || serverUrl.toString()).replace(/\/$/, "")

  // Bus commands must resolve identity from THIS session's worktree, not the
  // server process's launch dir (project picker / $HOME launches otherwise
  // land every session of this host on one seat).
  async function run(args: string[], extraEnv: Record<string, string> = {}) {
    try {
      const proc = Bun.spawn([BIN, ...args], {
        cwd: directory,
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

  let sessionId = ""

  const env = () => ({
    AGENT_BUS_VIA: "hook",
    AGENT_BUS_TOOL: "opencode",
    ...(sessionId ? { AGENT_BUS_ENDPOINT: `${base} ${sessionId}` } : {}),
  })

  return {
    // Stamp every Bash-tool child with identity + push endpoint so `agent-bus`
    // run inside the session resolves to this seat and can be poked back.
    "shell.env": async (_input, output) => {
      output.env.AGENT_BUS_TOOL = "opencode"
      if (sessionId) output.env.OPENCODE_SESSION_ID = sessionId
      if (sessionId) output.env.AGENT_BUS_ENDPOINT = `${base} ${sessionId}`
    },

    event: async ({ event }) => {
      try {
        if (event.type === "session.created") {
          const info = event.properties.info
          // Subagent/child sessions must not rebind the plugin's identity:
          // digest injection and idle wake belong to the primary session.
          if (info.parentID) return
          sessionId = info.id
          // SessionStart analog: surface unread packets as silent context.
          // noReply posts go through createUserMessage, which assigns part ids.
          const digest = await run(["digest"], env())
          if (digest) {
            void fetch(`${base}/session/${sessionId}/message`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ noReply: true, parts: [{ type: "text", synthetic: true, text: digest }] }),
            }).catch(() => {})
          }
          return
        }

        if (event.type === "session.idle") {
          const sid = event.properties.sessionID
          // Only wake the session this plugin instance belongs to.
          if (!sessionId || sid !== sessionId) return
          // Stop-hook analog: delegate the entire continue/block decision to
          // the CLI (inherits watch on/off, WAKE_BUDGET, MAX_SHOWS, PM nag).
          const verdict = await run(["stop-hook"], env())
          if (!verdict) return
          let parsed: { decision?: string; reason?: string }
          try {
            parsed = JSON.parse(verdict)
          } catch {
            return
          }
          if (parsed.decision !== "block" || !parsed.reason) return
          const parts: TextPartInput[] = [{ type: "text", synthetic: true, text: parsed.reason }]
          await fetch(`${base}/session/${sid}/prompt_async`, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ parts }),
          }).catch(() => {})
        }
      } catch {
        // Never break the host event loop.
      }
    },

    // UserPromptSubmit analog: prepend unread mail to each prompt turn,
    // verbatim from `agent-bus digest` (sanitized, capped, silent when empty).
    "chat.message": async (_input, output) => {
      try {
        const digest = await run(["digest"], env())
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
