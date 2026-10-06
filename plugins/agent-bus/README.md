# agent-bus plugin for OpenCode

OpenCode has no shell-command lifecycle hooks; its extension point is a
TypeScript plugin. This one gives an OpenCode session what the Claude hooks
give Claude:

- **Digest** — at session start and before each prompt it runs
  `agent-bus digest` (silent when empty) and injects the output. The digest
  marks those packets read.
- **Wake** — while a primary session is idle it polls `agent-bus stop-hook`
  (default every 2s, `AGENT_BUS_OPENCODE_POLL_MS`). When the seat owns unread
  work items the CLI answers `decision:block`, and the plugin resumes the
  session with the `reason` via `session.synthetic({resume: true})`. Which
  items wake the seat, and the wake budget, are decided by the CLI; the plugin
  has no bus logic.
- **Identity** — stamps `OPENCODE_SESSION_ID` and `AGENT_BUS_TOOL=opencode` on
  every shell child, so the agent's `agent-bus` calls and the plugin's resolve
  to one seat.
- **Offboard** — runs `agent-bus offboard` when a session is deleted.

Failure contract: identical to the `|| true` hook wrappers — any bus error is
swallowed and never breaks or delays the host turn.

## Install

```sh
./install-hooks.sh --opencode     # registers this plugin in ~/.config/opencode/opencode.json
```

Requires `agent-bus` on PATH. Restart OpenCode after installing (config is
read once at startup).

## Manual install

Copy or reference this directory from global config:

```json
{ "plugin": ["<abs-path>/plugins/agent-bus"] }
```

Auto-discovery also works if the file lives at `<project>/.opencode/plugins/`.
