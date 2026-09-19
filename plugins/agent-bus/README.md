# agent-bus plugin for OpenCode

OpenCode has no shell-command lifecycle hooks; its extension point is a
TypeScript plugin. This one wires an OpenCode session into the bus with the
same behavior the Claude/Codex/Cursor hook installers provide:

- **Digest injection** — unread packets surfaced at session start and before
  each prompt turn, by shelling out to `agent-bus digest` (silent when empty)
  and injecting its stdout verbatim. Never marks read.
- **Watch wake** — tracks primary sessions after `session.idle` and polls from
  inside the OpenCode process (default 2s). Each poll delegates the entire
  stop/continue decision to `agent-bus stop-hook`; on `decision:block`, it
  re-enters the loop through the injected SDK client's `promptAsync` with the
  hook's `reason`. Wake budgets, MAX_SHOWS, watch on/off, and the PM
  stale-thread nag are inherited from the CLI — the plugin contains none of
  that logic and needs no externally reachable HTTP server.
- **Identity** — exports `OPENCODE_SESSION_ID` into every Bash-tool child so
  `agent-bus` derives a session-unique instance seat (and `AGENT_BUS_TOOL`
  pinned, in case detection markers change).
- **Already-idle delivery** — the in-process poll closes the gap after the
  one-shot `session.idle` event, so a watch-enabled chat wakes without a manual
  prompt. Override the 2s interval with `AGENT_BUS_OPENCODE_POLL_MS`.

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
