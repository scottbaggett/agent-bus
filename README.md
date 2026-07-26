# agent-bus

A file-backed handoff bus so coding agents in different windows — Codex panes, Claude Code
sessions, anything with a shell — can hand work to each other without a human retyping
context between them.

No daemon, no server, no network. One bash script, `jq`, and an append-only log.

## Install

```sh
ln -sf "$PWD/bin/agent-bus" ~/.local/bin/agent-bus   # or anywhere on PATH
./install-hooks.sh                                   # lifecycle hooks for Claude, Codex, Cursor
```

`install-hooks.sh` is idempotent and reversible (`--uninstall`); it resolves the
binary from the repo (or `AGENT_BUS_BIN` / PATH) and backs up
`~/.claude/settings.json`, `~/.codex/hooks.json`, and `~/.cursor/hooks.json` in
place. Cursor hooks provide seat telemetry and best-effort digest injection;
Cursor's `sessionStart` `additional_context` path is unreliable in the IDE, so
Cursor delivery still rests primarily on the skill / `AGENTS.md` layer.

## Use

```sh
agent-bus who                    # who else is live, on what branch, holding what
agent-bus read                   # your inbox
agent-bus post --to @repo --state needs-review --touched auto --file handoff.md
agent-bus claim src/thing.ts     # advisory, warns if contested
agent-bus role pm                # take the supervising seat for this repo
agent-bus watch on               # Stop-hook wake on supervisory unread (opt-in)
```

Full protocol: [PROTOCOL.md](PROTOCOL.md). Runbook for agents:
[skills/handoff/SKILL.md](skills/handoff/SKILL.md).

## How it works

Every agent session occupies a **seat** addressed `<tool>/<worktree>` — `codex/64ef`,
`claude/main`. Seats post packets and take advisory file claims.

Delivery is **pull, not push**. `SessionStart` and `UserPromptSubmit` hooks run
`agent-bus digest`, which prints unread packets and stays silent when there are none, so a
peer's handoff lands at the top of the next turn. Pushing into a peer's terminal was
rejected: it clobbers their input line mid-task.

A hook digest deliberately **never marks a packet read** — it cannot prove its stdout
reached a model. A packet is acked only when an agent acts: `agent-bus read`, or replying
with `--re`.

### Watch (opt-in wake)

`agent-bus watch on` tells the Stop hook to continue the seat when supervisory
packets (`needs-review`, `blocked`, `handoff`, `question`) are unread — so peers
do not go idle until you manually poke them. Off by default. Per-packet
`MAX_SHOWS` still applies; a separate per-seat `WAKE_BUDGET` (default 3, resets
only on `resolve` / `watch reset`) bounds well-behaved ping-pong. Exhaustion
with pending mail shows in `watch status` and `doctor`. A seat sitting at an
empty prompt with no recent turn still needs one poke; Stop only fires after a
turn ends.

### Scopes

| `--to` | Reaches |
|---|---|
| `codex/64ef` | that exact seat |
| `@here` (default) | same repo **and** same worktree |
| `@repo` | every seat in this repo, any worktree |
| `@pm` | the repo's registered PM seat |
| `@codex` / `@claude` / `@cursor` | that tool's seats in this repo |
| `@all` | every seat on the machine |

Repo matching uses a stable `repo_id` (hash of the git common dir), so two clones
with the same basename do not share PM roles, claims, or `@repo` delivery.

`@here` being worktree-local is the sharp edge. A packet sent `@here` never reaches a seat
in another worktree, and that seat's `agent-bus read` honestly reports nothing unread —
silent non-delivery that is indistinguishable from a quiet repo. The PM role exists because
of this: a supervising seat is by definition never in the worker's worktree.

## State

Runtime state lives in `~/.agents/bus/` and is deliberately **not** part of this repo:

```
ledger.jsonl      append-only event log (msg | claim | release | resolve | seat)
msg/<id>.md       packet bodies
state/<seat>      per-seat read cursor
state/roles/      per-repo PM registry
state/watch/      per-seat opt-in Stop-hook wake flags
seats/<seat>      seat registry (last seen, branch, cwd)
claims/<hash>     advisory file claims
```

Machine-global on purpose, so one bus spans every repo and worktree on the box.

## Design notes

- **Claims are advisory.** Nothing blocks, nothing is authoritative, and a claim expires
  after 4 hours. Only the holding seat can `release` a live claim. Contested output is a
  signal to post a `question`, not to stop.
- **`agent-bus gc`** prunes expired claims, stale seats, and old message bodies.
- **Two delivery layers.** Hook stdout injection is unverified on some hosts, so agent
  instruction files (`CLAUDE.md`, `AGENTS.md`) also tell agents to read the bus at session
  start. Either layer alone suffices.
- **`agent-bus doctor`** reports which seats' hooks are firing, and flags packets surfaced
  three times without an ack — that combination means the host drops hook stdout.
