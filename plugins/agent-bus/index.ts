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

async function run(args: string[], extraEnv: Record<string, string> = {}) {
  const proc = Bun.spawn([BIN, ...args], {
    stdout: "pipe",
    stderr: "ignore",
    env: { ...process.env, ...extraEnv },
  })
  const out = await new Response(proc.stdout).text()
  await proc.exited
  // Nonzero exit (no agent-bus on PATH, bus misconfigured) degrades to empty.
  return proc.exitCode === 0 ? out.trim() : ""
}

export default (async ({ project }) => {
  // The host's own HTTP server address. OpenCode pins it from config
  // (server.port) when set; otherwise discover the listening port by probing
  // the process table once. Empty endpoint simply disables push wake.
  let serverUrl = ""

  async function discoverServerUrl(): Promise<string> {
    if (process.env.OPENCODE_SERVER_URL) return process.env.OPENCODE_SERVER_URL
    try {
      const proc = Bun.spawn(["lsof", "-anP", "-p", String(process.ppid || process.pid), "-iTCP", "-sTCP:LISTEN"], {
        stdout: "pipe",
        stderr: "ignore",
      })
      const out = await new Response(proc.stdout).text()
      await proc.exited
      // e.g. "TCP *:4096 (LISTEN)" — take the first listening port.
      const m = out.match(/:(\d+)\s+\(LISTEN\)/)
      return m ? `http://127.0.0.1:${m[1]}` : ""
    } catch {
      return ""
    }
  }

  const env = () => ({
    AGENT_BUS_VIA: "hook" as const,
    AGENT_BUS_TOOL: "opencode",
    ...(serverUrl && sessionId ? { AGENT_BUS_ENDPOINT: `${serverUrl} ${sessionId}` } : {}),
  })

  let sessionId = ""
  let initialized = false

  async function init() {
    if (initialized) return
    initialized = true
    serverUrl = await discoverServerUrl()
  }

  return {
    // Stamp every Bash-tool child with identity + push endpoint so `agent-bus`
    // run inside the session resolves to this seat and can be poked back.
    "shell.env": async (_input, output) => {
      output.env.AGENT_BUS_TOOL = "opencode"
      if (sessionId) output.env.OPENCODE_SESSION_ID = sessionId
      if (serverUrl && sessionId) output.env.AGENT_BUS_ENDPOINT = `${serverUrl} ${sessionId}`
    },

    event: async ({ event }) => {
      try {
        if (event.type === "session.created") {
          await init()
          sessionId = event.properties.info.id
          // SessionStart analog: surface unread packets as silent context.
          const digest = await run(["digest"], env())
          if (digest && serverUrl) {
            void fetch(`${serverUrl.replace(/\/$/, "")}/session/${sessionId}/message`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ noReply: true, parts: [{ type: "text", synthetic: true, text: digest }] }),
            }).catch(() => {})
          }
          return
        }

        if (event.type === "session.idle") {
          await init()
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
          const base = serverUrl.replace(/\/$/, "")
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
        await init()
        const digest = await run(["digest"], env())
        if (digest && output.parts) {
          // Full part shape: the hook's Part[] carries persisted parts, so
          // borrow the message's ids rather than pushing an input-shaped part.
          output.parts.push({
            id: `${output.message.id}-bus`,
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
