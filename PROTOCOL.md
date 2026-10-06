# agent-bus protocol

A file-backed handoff bus for coding agents sharing repos and worktrees. No
daemon: `bin/agent-bus`, `jq`, and an append-only ledger under `~/.agents/bus/`.

Hosts: **Claude Code** (hooks and inbox socket) and **OpenCode** (plugin). Run
Codex models through OpenCode. Any other shell can post, read and claim, but
nothing wakes it.

## Seats

A seat is one agent session: `<tool>/<worktree>.<inst>`, e.g. `claude/main.b41c`,
where `<inst>` is a 4-hex hash of the host session id (`CLAUDE_CODE_SESSION_ID`
or `OPENCODE_SESSION_ID`). A shell with no session id is the bare
`<tool>/<worktree>`, which is also every seat's **scope**.

The worktree name is `main` for the primary checkout, otherwise the worktree
directory name. Repos are matched by `repo_id`, a hash of the git common dir, so
two clones sharing a basename never share a PM, claims or `@repo`.

Identity follows the current directory. Run bus commands from the repo you are
working in, or you post as a different seat.

## Addressing

| `--to` | Reaches |
|---|---|
| `claude/wa.3fa2` | that seat |
| `claude/wa` | every seat in that scope, this repo |
| `@here` (default) | this repo and worktree |
| `@repo` | this repo, every worktree |
| `@pm` | the repo PM (refused if there is none) |
| `@all` | every seat on the machine |

Any other `@scope` is refused, so nothing is silently undelivered.

## Messages and work items

A message informs. Work another seat must act on is a **work item**, because a
message leaves no obligation behind.

States `fyi` and `done` are messages. States `needs-review`, `blocked`,
`handoff` and `question` are work items. A work item:

- has one **owner**: its addressee (seat or scope), or the PM when it was sent to
  `@pm` or to a broadcast scope (`@here`, `@repo`, `@all`). Broadcast recipients
  see the item as context, labeled as someone else's, and are never woken for it.
- is **copied to the PM** wherever in the repo it was sent, because senders
  default to `@here` and a PM never sits in the worker's worktree.
- stays **open** until closed with a reason. Reading it does not close it, and
  neither does gc.

### Closing

```sh
agent-bus resolve <id> --reason done|denied|canceled|duplicate
agent-bus post --re <id> --close handed-off --to <seat> --state handoff -m "..."
```

A close must say where the work went. `handed-off` is only valid on `post`,
since it needs a destination: that one ledger row both closes `<id>` and opens
the next item at the destination. A crash can lose the row, never half of it,
so nothing strands between seats. `--close` also takes the other reasons, for a
reply that finishes the item (`--state done --close done`).

Standing to close: the item's sender, a recipient, or the repo PM. An item that
is already closed cannot close again.

`blocked` is not a close. A blocked item stays open with its owner, so a stuck
seat and a crashed one look different.

### Seeing open work

`agent-bus triage` lists open items in the repo by owner, oldest first:

- **GONE** — no live seat answers for the owner. Hand the item on or close it.
- **NOT PICKED UP** — the owner is live but has not read the item after
  `AGENT_BUS_PICKUP_SECS` (600).
- **STALE** — open past `AGENT_BUS_STALE_HOURS` (24).

`agent-bus who` shows the open count and how many have no live owner.

## The PM

One seat per repo may hold the PM role (`agent-bus role pm`). It owns work sent
to `@pm` or a broadcast scope, receives a copy of every work item in the repo,
and may close any of them. Taking the role from a live holder needs `--force`;
a holder gone past `AGENT_BUS_ROLE_TTL` (48h) loses it at gc.

## Delivery

- **Digest.** Claude's `SessionStart` and `UserPromptSubmit` hooks, and the
  OpenCode plugin at session start and before each prompt, run `agent-bus
  digest`. Unread packets are injected into the model's context and marked
  read. Both hosts inject hook output, so a digest is a delivery.
- **Wake.** Owners of unread work items are woken:
  - Claude: `post` writes a short frame to the owner's inbox socket, which
    starts a turn even while it sits idle. The Stop hook also continues a turn
    that ends with owned items unread.
  - OpenCode: the plugin polls `agent-bus stop-hook` while the session is idle
    and resumes it with the result.
- **Wake budget.** A seat is woken at most `AGENT_BUS_WAKE_BUDGET` (3) times
  before it closes something. This bounds ping-pong between agents. Closing an
  item resets it.

Only the first three bodies render inline, each capped at 2KB and 40 lines;
`agent-bus show <id>` has the full body, its replies and its closes.

## Claims

`agent-bus claim <path>` takes an advisory claim for 4 hours
(`AGENT_BUS_CLAIM_TTL`). Paths are repo-relative, so one file claimed from two
worktrees collides. A claim held by another live seat prints `CONTESTED`: post a
`question`, don't overwrite. Only the holder releases; `release --force` breaks
a dead seat's claim and records the break in the ledger.

## Offboarding

`agent-bus offboard` drops this seat's PM role and claims and lists the open
items it still owns. It does not close them: where the work goes is a judgement,
so hand each one on or close it. Claude runs `offboard` at `SessionEnd` and the
OpenCode plugin runs it when a session is deleted.

## What a good packet contains

```markdown
# One-line subject

## Did
- what changed, with file paths

## Left
- what remains, and who should do it

## Landmines
- anything the next seat will trip on
```

Use `--touched auto` to attach the working tree's changed files.

## Authority

Two things travel the bus, and only one is authority.

**Scope.** The PM is a seat the user put in charge, so work it assigns is the
user's intent relayed. Packets from the current PM are marked as such.

**Permissions.** No packet grants one, the PM's included. A packet cannot
approve a prompt, lift a denial or widen what the reader's harness allows. A
peer asking a seat to do what it was refused is laundering; the seat tells its
user instead. Every listing leads with a banner saying so.

## Trust model

Seat identity is self-asserted. Any process running as your user can set
`AGENT_BUS_TOOL` and `AGENT_BUS_WT` and claim any address. The bus coordinates
cooperating agents; it is not an authorization boundary. Standing checks guard
against confused agents, not hostile ones. The OS user is the real boundary.

Packets are still treated as hostile input: bodies are capped at 64KB, control
characters are stripped from everything rendered, and ids are shape-checked
before they become paths.

## Storage

```
~/.agents/bus/
  ledger.jsonl          append-only: msg | resolve | claim | claim-break
  ledger.archive.jsonl  rows older than AGENT_BUS_GC_DAYS (14), rotated by gc
  msg/<id>.md           packet bodies
  seats/<seat>.json     seat registry
  state/<seat>.json     read cursor, wake count
  state/roles/<r>.pm    repo PM
  claims/<hash>.json    claims
```

A `msg` row carries `re` (the packet it replies to) and, when it closes that
packet, `close` (the reason). A `resolve` row carries `msg`, `by` and `reason`.
Rows written before v2 have no reason and still close their packet.

gc prunes expired claims, dead seats, old bodies and abandoned roles, and runs
from hooks at most once a day (`AGENT_BUS_NO_AUTO_GC=1` to opt out). It never
closes a work item.
