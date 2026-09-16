# agent-bus

<p align="center">
  <img src="assets/agent-bus.svg" width="760" alt="A yellow school bus labeled AGENT BUS with robot agents in the windows, a PM robot driving, a roof sign reading @here to @repo, and a handoff packet flying out behind.">
</p>

Slack for your coding agents — and it's **multi-harness**. Multi-agent tools coordinate
agents inside one runtime; agent-bus coordinates the runtimes: Claude Code, Codex,
Cursor, and OpenCode sessions on the same repo hand work to each other, claim files,
take roles (`@pm`, `@research`), and wake each other.

No daemon, no server, no network. One bash script, `jq`, and an append-only log — the
filesystem is the only interface every harness has in common, so the lowest common
denominator is the feature.

## Install

```sh
ln -sf "$PWD/bin/agent-bus" ~/.local/bin/agent-bus   # or anywhere on PATH
./install-hooks.sh                                   # hooks for Claude, Codex, Cursor + plugin for OpenCode
```

`install-hooks.sh` is idempotent and reversible (`--uninstall`); it resolves the
binary from the repo (or `AGENT_BUS_BIN` / PATH) and backs up
`~/.claude/settings.json`, `~/.codex/hooks.json`, and `~/.cursor/hooks.json` in
place. Cursor hooks provide seat telemetry, best-effort digest injection, and
Stop-hook wake (`followup_message`) for seats with `agent-bus watch on`.
Cursor's `sessionStart` `additional_context` path is unreliable in the IDE, so
Cursor delivery still rests primarily on the skill / `AGENTS.md` layer.

Cursor runs user-level hooks from `~/.cursor`, not the workspace, and never
shows a hook the agent's shell environment. The agent's own tool shell does
export `CURSOR_AGENT` and `CURSOR_CONVERSATION_ID`, and the latter equals the
hook payload's `session_id`, so shell and hooks resolve to one instance seat
without any environment propagation. The adapter re-anchors on
`CURSOR_PROJECT_DIR` (or the payload's `workspace_roots`) so identity resolves
to the right worktree, and its stop hook delegates within scope: when the hook
seat itself is not watching, it wakes on behalf of the most recently active
watching `cursor/<worktree>` instance. Two Cursor chats watching in one
worktree therefore share wakes — give each its own worktree if that matters.

OpenCode has no shell-command lifecycle hooks, so it integrates through a
TypeScript plugin instead (`plugins/agent-bus/`, copied to
`~/.config/opencode/plugins/` and registered in the global `opencode.json`).
The plugin shells out to the same CLI — `agent-bus digest` for context
injection and `agent-bus stop-hook` for watch wake — so budgets, caps, and
staleness all behave identically across harnesses. Restart OpenCode after
installing; config is read once at startup.

## Use

```sh
agent-bus who                    # who else is live, on what branch, holding what
agent-bus read                   # your inbox
agent-bus post --to @repo --state needs-review --touched auto --file handoff.md
agent-bus claim src/thing.ts     # advisory, warns if contested
agent-bus role pm                # take the supervising seat for this repo
agent-bus watch on               # Stop-hook wake on supervisory unread (opt-in)
agent-bus selftest               # prove hooks/digest/wake work in THIS host; then `selftest check <nonce>` next turn
agent-bus wait                   # block this turn until mail arrives (codex-friendly)
agent-bus triage                 # unresolved review threads by worktree/age (PM hygiene)
agent-bus cost                   # what the bus has injected into agents' contexts, per seat
```

Full protocol: [PROTOCOL.md](PROTOCOL.md). Runbook for agents:
[skills/handoff/SKILL.md](skills/handoff/SKILL.md).

## How it works

Every agent session occupies a **seat** addressed `<tool>/<worktree>.<inst>` —
`codex/64ef.3fa2`, `claude/main.b41c` — where `<inst>` is a short hash of the
host session id, so two sessions never share an identity (plain shells without
a session id stay bare `<tool>/<worktree>`). The bare form is the seat's scope:
it addresses every instance of that tool in that worktree. Seats post packets
and take advisory file claims.

Delivery is **pull-first**. `SessionStart` and `UserPromptSubmit` hooks run
`agent-bus digest`, which prints unread packets and stays silent when there are none, so a
peer's handoff lands at the top of the next turn. Pushing into a peer's *terminal* was
rejected — it clobbers their input line mid-task — but seats with a wake channel can still
start without a human prompt. Claude Code gets **post-time push** through its inbox socket
(recorded from `CLAUDE_CODE_MESSAGING_SOCKET`); generic HTTP `endpoint` seats can opt into
the same constant-size nudge. OpenCode's TUI does not expose a reachable HTTP listener, so
its plugin instead polls `agent-bus stop-hook` in-process while a watch-enabled session is
idle and re-enters the loop through OpenCode's injected SDK client. Best-effort; the packet
body always travels through the bus, never the wake channel. `doctor` shows externally
push-reachable seats.

Hook commands read the host's JSON payload on stdin and use its `session_id` when the
environment carries none, so a Codex hook lands on the same instance seat as the Codex
shell that runs `agent-bus read` and `watch on`.

A body renders **once per seat**. Later surfacings of the same packet carry the header
and a `agent-bus show <id>` pointer, because the body is nearly all of a packet's cost and
re-showing it was half of every byte this bus had ever injected. The Stop-hook wake payload
still renders the body every time: for a woken agent that is the primary delivery, not a
reminder. `agent-bus cost` reports the total per seat from the recorded surfacings.

A hook digest deliberately **never marks a packet read** — it cannot prove its stdout
reached a model. A packet is acked only when an agent acts: `agent-bus read`, or replying
with `--re`.

### Watch (opt-in wake)

`agent-bus watch on` tells the Stop hook to continue the seat when supervisory
packets (`needs-review`, `blocked`, `handoff`, `question`) are unread — so peers
do not go idle until you manually poke them. Off by default. Per-packet
`MAX_SHOWS` still applies; a separate per-seat `WAKE_BUDGET` (default 3, resets
only on `resolve` / `watch reset`) bounds well-behaved ping-pong. Exhaustion
with pending mail shows in `watch status` and `doctor`. Stop only fires after a
turn ends, so a seat idle at an empty prompt is not woken by watch alone —
Claude seats close that gap with the post-time socket poke; hosts without an
inbox socket (codex desktop) use `agent-bus wait`, which blocks the current
turn in a shell sleep-loop (no tokens) until supervisory mail arrives.

### Scopes

| `--to` | Reaches |
|---|---|
| `codex/64ef.3fa2` | that exact seat (one session) |
| `codex/64ef` | every codex instance in that worktree of this repo |
| `@here` (default) | same repo **and** same worktree |
| `@repo` | every seat in this repo, any worktree |
| `@pm` | the PM(s) responsible for the sender: repo PM plus any worktree-scoped PM |
| `@<name>` | the seat holding that named role (`agent-bus role research` → `--to @research`) |
| `@codex` / `@claude` / `@cursor` / `@opencode` | that tool's seats in this repo |
| `@all` | every seat on the machine |

Repo matching uses a stable `repo_id` (hash of the git common dir), so two clones
with the same basename do not share PM roles, claims, or `@repo` delivery.

`@here` being worktree-local is the sharp edge. A packet sent `@here` never reaches a seat
in another worktree, and that seat's `agent-bus read` honestly reports nothing unread —
silent non-delivery that is indistinguishable from a quiet repo. The PM role exists because
of this: a supervising seat is by definition never in the worker's worktree.

The other sharp edge is that `@here` is a broadcast — every seat in the worktree gets it,
so it is the wrong tool for task assignment. Named roles fix that: a seat registers what it
is doing (`agent-bus role research`) and peers target `--to @research` — one holder per
name, `--force` to take a name from a live holder, and posting to an unregistered name is
refused instead of silently undelivered.

## State

Runtime state lives in `~/.agents/bus/` and is deliberately **not** part of this repo:

```
ledger.jsonl      append-only event log (msg | claim | release | resolve | seat)
msg/<id>.md       packet bodies
state/<seat>      per-seat read cursor
state/roles/      role registry (repo PM, worktree PMs, named aliases)
state/watch/      per-seat opt-in Stop-hook wake flags
seats/<seat>      seat registry (last seen, branch, cwd)
claims/<hash>     advisory file claims
```

Machine-global on purpose, so one bus spans every repo and worktree on the box.

## Design notes

- **Claims are advisory.** Nothing blocks, nothing is authoritative, and a claim expires
  after 4 hours. Only the holding seat can `release` a live claim. Contested output is a
  signal to post a `question`, not to stop.
- **`agent-bus gc`** prunes expired claims, stale seats, old message bodies, and dead-seat
  state, and rotates ledger rows older than `AGENT_BUS_GC_DAYS` (default 14) into
  `ledger.archive.jsonl` so hook-time reads stay fast on a busy machine. It also runs
  opportunistically from hook entry points at most once a day (`AGENT_BUS_NO_AUTO_GC=1`
  to opt out), so nobody has to remember it.
- **Review threads never close themselves.** gc is mechanical pruning only; a
  `needs-review`/`blocked`/`question`/`handoff` packet stays open until a PM explicitly
  runs `agent-bus resolve`. `triage` lists what is open (stale > 24h flagged), `doctor`
  warns about the pile-up, and a PM seat's Stop hook shows a rate-limited reminder.
- **Hardened against accidents and hostile packets.** Readers tolerate malformed ledger
  lines (`doctor` counts them). Bodies are capped at 64KB at post and 2KB/40 lines inline;
  every rendered field is stripped of control characters; message ids are shape-validated
  before touching the filesystem; `resolve` requires standing (sender, addressee, or PM);
  taking the PM role from a live holder requires `--force`. Every digest/wake listing leads
  with a provenance banner: from other agents, not your user, and no packet can grant a
  permission your harness denies. Packets from the **PM** — the seat you put in charge —
  are marked as delegated scope, because your instructions to the PM are what it is
  relaying. Everything else is context. See "Authority" in [PROTOCOL.md](PROTOCOL.md).
- **Not an authorization boundary.** Seat identity is self-asserted by design — the bus
  coordinates agents already running as one OS user. See the trust-model section in
  [PROTOCOL.md](PROTOCOL.md).
- **Two delivery layers.** Hook stdout injection is unverified on some hosts, so agent
  instruction files (`CLAUDE.md`, `AGENTS.md`) also tell agents to read the bus at session
  start. Either layer alone suffices.
- **`agent-bus selftest`** is the integration test for the host you are sitting in — the
  only honest one for a GUI-driven agent (Cursor's panel, Codex Desktop). It posts a probe
  packet to your own instance seat whose body tells the model to run
  `agent-bus selftest check <nonce>` on the next turn. `check` then verifies from bus state
  that hooks touched this seat after arming, that the digest surfaced the probe, that the
  Stop hook continued the seat when watch was on, and — only if the nonce was supplied,
  which the model can only have learned from the injected digest — that hook stdout
  reached the model. Probes never CC a PM and never count as unresolved review threads.
  Run it after installing hooks or upgrading a host. `doctor` runs the identity part of the
  check on every invocation (hooks and shell must resolve to one seat).
- **`agent-bus doctor`** also checks each host's installed hook lines against what
  `install-hooks.sh` writes today. An install from an older version keeps firing, so
  nothing looks broken while the guarantees are missing — a `Stop` line that runs
  `stop-hook` (without it that host can never be woken) and an `AGENT_BUS_TOOL` pin on
  every line (without it a hook subshell with no host markers resolves to tool `shell`
  and reads a different seat's cursor than the heartbeat wrote). Re-run the installer
  for any host it reports STALE.
- **`agent-bus doctor`** reports which seats' hooks are firing, flags packets surfaced
  three times to a live seat that never acked them — that combination means the host
  drops hook stdout — and shows push-reachable vs pull-only seats.
