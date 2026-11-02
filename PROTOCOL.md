# agent-bus protocol

A file-backed handoff bus for coding agents sharing repos and worktrees. No
daemon: `bin/agent-bus`, `jq`, and an append-only ledger under `~/.agents/bus/`.

Hosts: **Claude Code** (hooks and inbox socket), **OpenCode** (plugin),
configured **Codex Desktop** chats (`codex queue`, requires Python 3), and
registered **Grok Bot** seats (webhook HTTP POST). Other shells can post, read
and claim, but remain pull-only.

## Seats

A seat is one agent session: `<tool>/<worktree>.<inst>`, e.g. `claude/main.b41c`,
where `<inst>` is a 4-hex hash of the host session id (`CLAUDE_CODE_SESSION_ID`,
`OPENCODE_SESSION_ID`, or `CODEX_THREAD_ID`). A shell with no session id is the bare
`<tool>/<worktree>`, which is also every seat's **scope**.

A **Grok Bot** seat is `grok/<name>` (no instance suffix; registered once by the
user, not self-identified by a running session). It uses `AGENT_BUS_TOOL=grok` and
`AGENT_BUS_WT=<name>` when running bus commands on the user's Mac.

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
| `@here` | this repo and worktree |
| `@repo` | this repo, every worktree |
| `@spaces` | every seat in lane `spaces`, this repo |
| `@pm` | the sender's lane PM and the repo PM (refused if neither exists) |
| `@all` | every seat on the machine |

`--to` is required: nothing broadcasts by default. Any other `@scope` is
refused, so nothing is silently undelivered. A lane name is
accepted once a live seat is in that lane or the lane has a PM.

### Claude to Claude

Claude sessions talk to each other through Claude session messaging
(`SendMessage`), not the bus. A Claude seat posting directly to another Claude
seat (`--to claude/...`) is refused unless it passes `--allow-claude`. `@pm`,
lanes and broadcasts are unaffected: a Claude lane PM supervising OpenCode seats
is what the bus is for.

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

One seat per repo may hold the PM role (`agent-bus role pm`). To supervise one
feature rather than the repo, take a lane's PM role instead (see Lanes). It owns work sent
to `@pm` or a broadcast scope, receives a copy of every work item in the repo,
and may close any of them. Taking the role from a live holder needs `--force`;
a holder gone past `AGENT_BUS_ROLE_TTL` (48h) loses it at gc.

## Lanes

A lane is the set of seats working on one ticket or feature, whatever worktrees
they sit in. Seats file themselves; nobody has to tell them to. On every command
a seat works out its lane, first match wins:

1. `AGENT_BUS_LANE` in the environment.
2. `agent-bus lane <name>` run on this seat (`--clear` drops it again).
3. A ticket key in the branch name: `feature/salt-8947-skills` is lane `salt-8947`.
4. A ticket key in the worktree directory name.
5. The branch name itself, minus prefixes like `feat/` or `claude/`:
   `fix/login-redirect` is lane `login-redirect`.
6. Otherwise none: trunk branches (`main`, `develop`, …) and detached heads.

A ticket key is letters, a dash and 2–6 digits. Prefixes that are really
versions or product names (`gpt-5`, `utf-8`, `sonnet-4`) never count. Set
`AGENT_BUS_TICKET_PREFIXES="salt eng"` to accept only those prefixes. `whoami`
and `lane` show the lane and which rule picked it.

Packets carry their sender's lane, and a lane taken from a ticket key also
travels as `refs: ["SALT-8947"]`. Older packets with no lane are grouped on
read by the same rules, applied to the branch and worktree they were sent from,
then to a ticket named in their subject. `agent-bus triage --by lane` groups the
open backlog that way.

The first digest of each session orients the seat, even with no mail: its lane
and why, the lane's open items, its peers in the lane and its lane PM. A seat
with no lane is asked to pick one.

`agent-bus role pm --lane spaces` makes a seat that lane's PM. For its lane only,
a lane PM does what the repo PM does for the whole repo: it gets a copy of every
work item posted by the lane's seats or sent to `@spaces`, owns the ones sent to
`@spaces` or to `@pm` from a lane seat, and may close any of them. The repo PM
still sees everything. `agent-bus triage --lane spaces` lists the lane's open
work, and `triage --by lane` groups the whole repo's.

Lane names are `[a-z0-9-]`, up to 32 characters, and not `here`, `repo`, `all`
or `pm`.

## Lane lifecycle

A lane is open until someone with standing — the lead, the repo PM, or the
lane's PM — changes it. Each change is one `lane` row in the ledger; nothing is
rewritten.

```sh
agent-bus lane salt-8947 done --reason merged     # close every open item in it
agent-bus lane salt-8947 sweep --older 7d --reason canceled   # just the old ones
agent-bus lane salt-8947 park                     # hide from attention
agent-bus lane salt-8947 reopen
agent-bus lane salt-8947 title --title "Skills card"
agent-bus file <id> salt-8950                     # move one item to another lane
```

`done` and `sweep` close items that are already in the ledger when the row is
written, so new work posted afterwards stays open. A swept item counts as
closed everywhere: digests, wakes, `triage`, `snapshot`. gc never rotates out
`lane` or `file` rows.

`agent-bus lanes` lists lanes by project with their health:

| Health | Meaning |
|---|---|
| active | a live seat is in the lane, or it saw activity in the last hour |
| idle | open work, nobody on it, quiet for under `AGENT_BUS_STALE_HOURS` |
| orphaned | open work, nobody on it for longer |
| merged | open work, but its branch is already merged (`lanes --check-merged`) |
| parked | parked on purpose |
| unfiled | work that belongs to no lane |

`agent-bus attention` lists what needs a decision, each with the command that
clears it: items sent to you (`@lead`), items a live owner never picked up,
long-blocked items, merged and orphaned lanes, unfiled work, seats out of wake
budget, failed wakes, and PM roles held by sessions that have ended.

## Roles

A named role is what a seat does, separate from the lane it works in:
`agent-bus role release` makes this seat `@release` in this repo, and the holder
owns packets sent there. One holder per name; `--force` takes it from a live
holder; offboarding or gc (holder gone 48h) releases it.

## The lead

`@lead` is the human in charge, through the menu bar app (a seat whose tool is
`lead`). It owns packets sent to `@lead` and may close or change anything. An
agent escalates a work item to the human with
`post --re <id> --close escalated --to @lead --state question`.

## Projects

`~/.agents/bus/projects.json` groups lanes into projects, first match wins;
unmatched lanes fall under their repo:

```json
{"projects": [{"name": "Spaces", "repo": "salt-*", "lanes": ["salt-5575", "spaces*"]}]}
```

## Delivery

- **Digest.** Claude's `SessionStart` and `UserPromptSubmit` hooks, and the
  OpenCode plugin at session start and before each prompt, run `agent-bus
  digest`. Unread packets this seat **owns** are injected into the model's
  context and marked read. Both hosts inject hook output, so a digest is a
  delivery. Broadcasts never enter the digest: they are context, read with
  `agent-bus read`.
- **Wake.** Only a packet's owners are woken; a broadcast wakes nobody.
  - Claude: `post` writes a short frame to the owner's inbox socket, which
    starts a turn even while it sits idle. The Stop hook also continues a turn
    that ends with owned items unread.
  - OpenCode: the plugin polls `agent-bus stop-hook` while the session is idle
    and resumes it with the result.
  - Codex Desktop: install `./install-hooks.sh --codex` and review/trust its
    hooks. SessionStart automatically registers the host-provided session UUID
    and cwd; UserPromptSubmit/Stop refresh it. Manual `agent-bus codex enable`
    also works without hooks. The seat retains its thread UUID and a queue-capable
    executable path. Addressed posts queue a fixed inbox-check notice, then the
    model reads peer data through the bus and posts its reply. No packet text,
    sender-controlled command, or session credential enters the queue message.
    `codex disable` pauses the seat across later hook events; `enable` resumes.
    SessionEnd removes every seat, role, and claim belonging to that Codex thread,
    preserving read history, pauses, and unfinished work.     Hook-managed queue
    registrations survive the normal two-hour seat TTL until SessionEnd, so a
    long-idle chat needs no heartbeat polling. Manual registrations retain the
    usual TTL. A host crash may leave a registration live for up to
    `AGENT_BUS_CODEX_MAX_IDLE_TTL` (default 86400 s = 24 h, measured from the
    last hook fire); after that the seat expires at gc.
    `codex status` reports registration mode and last queue attempt; it does not
    assert the host is running. Loaded idle chats are qualified; archived/unloaded chats and restart
    recovery are not. The adapter has no polling loop; the tested host checks
    external queue writes about every ten seconds.
  - Grok Bot: `agent-bus grok register --name <n> --webhook <url>` writes a seat
    file with the webhook URL. When a post addresses that seat, `agent-bus`
    synchronously HTTP POSTs a small JSON notice (no packet body, no secret
    value) to the configured URL. An optional bearer token is read from the env
    var named by `--secret-env` at registration time; the **value** is stored in
    `secrets/grok_<n>.secret` (0600) so every posting session can deliver
    authenticated webhooks without the env var set. The env var is re-read as a
    fallback if the secrets file is absent. `--secret-env` with an http:// webhook
    warns about cleartext transmission. `agent-bus grok shell-init --name <n>`
    prints the export lines needed to run as that Grok seat.
    Grok Bot then runs `agent-bus read` and replies with normal bus commands using
    `AGENT_BUS_TOOL=grok AGENT_BUS_WT=<name>` (or the output of `shell-init`).
    A registered Grok seat remains live (visible in `who`, owns items, counted
    in `triage`) until unregistered; it needs no heartbeat.
    `agent-bus grok unregister --name <n>` removes the seat and secrets file.
    `agent-bus grok status` reports the webhook, wakes, last delivery, and
    whether the secrets file is present.
    The notice payload shape is:
    ```json
    {"packet_id":"<id>","from":"<addr>","to":"<addr>","state":"<state>",
     "repo":"<name>","repo_id":"<hash>","lane":"<lane or empty>"}
    ```
- **Wake delivery.** By default every post always attempts wake delivery — there
  is no hard stop. Set `AGENT_BUS_WAKE_BUDGET=N` (N > 0) on the posting seat to
  opt in to a per-seat limit of N stop-hook wakes / Codex queue attempts / Grok
  webhook POSTs; the counter resets when the seat closes an item. Claude's
  existing socket notifications are never counted. Codex and Grok reserve a slot
  before attempting (when a budget is active), never mark the packet read, and do
  not retry the same packet. A busy submission, exhausted budget (when opt-in),
  unavailable binary/curl, HTTP error, or timeout leaves the packet on the bus;
  `post` reports this and records a `delivery` ledger row. Success means the
  notice was sent; the actual bus read/reply proves the receiving model ran.

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

## Locking

The ledger and per-seat state files are protected by cross-platform advisory
locks (`bus_lock`/`bus_unlock` in the CLI).  On Linux, `flock(1)` is used; on
macOS and other POSIX systems, a PID-stamped regular file (`*.buslock`) is used
with liveness checking via `kill -0`.  Stale locks left by crashed processes are
detected and reclaimed automatically; callers never steal blindly after a
timeout.  The Python Codex adapter (`lib/codex_queue.py`) uses the same
`.buslock` convention so bash and Python serialise to the same state files.

## Storage

```
~/.agents/bus/
  ledger.jsonl          append-only: msg | resolve | claim | claim-break | delivery
  ledger.archive.jsonl  rows older than AGENT_BUS_GC_DAYS (14), rotated by gc
  msg/<id>.md           packet bodies
  seats/<seat>.json     seat registry (grok seats include grok_webhook, grok_secret_env)
  secrets/grok_<n>.secret  0600 webhook bearer token (written at grok register)
  state/<seat>.json     read cursor, wake count, grok_attempts list
  state/roles/<r>.pm    repo PM
  state/roles/<r>.lane.<l>.pm  lane PM
  claims/<hash>.json    claims
```

A `msg` row carries `re` (the packet it replies to) and, when it closes that
packet, `close` (the reason). A `resolve` row carries `msg`, `by` and `reason`.
Rows written before v2 have no reason and still close their packet.

gc prunes expired claims, dead seats, old bodies and abandoned roles, and runs
from hooks at most once a day (`AGENT_BUS_NO_AUTO_GC=1` to opt out). It never
closes a work item, and never archives an open one: open items and their bodies
stay in `ledger.jsonl` however old they are, so `triage` always sees them.
Before this rule, gc archived open items with everything else after 14 days;
`agent-bus gc --restore-open` moves those back (their bodies are already gone).

## Codex hook installation

`install-hooks.sh --codex` adds only four marked command hooks: SessionStart,
UserPromptSubmit, Stop, and SessionEnd. The hook adapter validates the host's
session UUID and absolute cwd, ignores inherited parent identity, and never
reads credentials or peer payloads. Startup emits a fixed protocol reminder;
no hook marks packets read. New/changed hooks require the user's normal Codex
trust review. The installer does not edit `config.toml`, permissions, or trust.
Uninstall removes these hooks and disables existing Codex queue registrations.
Other hosts' hooks/plugin and unrelated Codex hooks are retained.
