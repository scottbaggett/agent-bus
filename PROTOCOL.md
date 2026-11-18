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

With `AGENT_BUS_SEAT_KEY=session`, identity follows the session instead. The
first command a session runs pins its worktree name in
`state/sessions/<tool>.<hash>`, and every later command reuses it, wherever the
process has moved. So one session is one seat, and its roles stay on that seat.
`cwd`, repo, branch and lane still follow the current directory, as attributes.
The pin is written in full, then linked into place, so the first session to
write it wins. An empty pin is an error, never a fresh seat.
An explicit `AGENT_BUS_WT` still wins, and `offboard` removes the pin.

### Subagents

An in-process subagent (Claude Code's Agent tool) runs in its parent's session.
It has no hooks of its own, so without anything else it acts as its parent.
`agent-bus --as-child <name> <command>`, or `AGENT_BUS_CHILD=<name>`, gives it a
child seat `<parent-addr>/<name>`, whose seat file records `parent`. The name is
`[a-z0-9][a-z0-9_-]`, at most 32 characters.

- `who` lists a child as `<parent> / <name>`, and `snapshot` gives it `parent`.
- A packet to a child also reaches the parent's `read` and digest, labelled
  "for your subagent <name>", because the parent's hooks are the only ones
  that run. A Claude child records its parent's inbox socket, so a post to it
  notifies the parent's session.
- A child owns only packets sent to its own address. It doesn't get packets
  sent to its parent, its scope, `@here`, `@repo`, `@all` or its lane, and it
  can't reply to or resolve them. It holds no roles and can't take one.
- It works in its parent's lane, unless `AGENT_BUS_LANE` or its own
  `agent-bus lane` says otherwise, so its `@pm` reaches its parent's lane PM.
- Its seat file is `<parent seat file>@<name>.json`. No other seat's file can
  contain `@`, and a `/` in a worktree name becomes `-`, so only a child's
  address has two slashes.
- A child is no more live than its parent. Offboarding a child removes only the
  child; offboarding the parent removes its children and their claims.

Each seat records its worktree path (`cwd`) and the pid of the agent process it
runs in, and `agent-bus snapshot` reports both, so a viewer can tie a seat to
its CPU, memory, child processes and containers. Claude's pid comes from its
inbox socket; other hosts are found by walking up from the CLI to the first
process named after the tool. `pid` is null when none is found (shell seats);
`AGENT_BUS_PID` overrides it.

OpenCode serves every session from one `opencode serve` process, so its seats
record that as `server_pid` instead of a pid of their own. When the server
exits (OpenCode was restarted), its seats count as ended right away rather
than lingering for the two-hour live window. `AGENT_BUS_SERVER_PID` overrides
it.

Every seat has a bot: four lines of half-block art made from its address,
never picked. The tool sets the head, body and color (Claude orange, Codex
blue, OpenCode yellow); a hash of the seat sets the antenna, eyes and legs, so
a seat looks the same everywhere and two seats of one tool look different.
`agent-bus avatar [seat]` prints one, `whoami` and `status` start with yours,
and `snapshot` gives each seat `avatar: {rows, color}` for viewers to draw.

## Addressing

| `--to` | Reaches |
|---|---|
| `claude/wa.3fa2` | that seat |
| `claude/wa` | every seat in that scope, this repo |
| `@here` | this repo and worktree |
| `@repo` | this repo, every worktree |
| `@checkout` | every seat in lane `checkout`, this repo |
| `@pm` | the item's PM (see "The PM" under Messages and work items): a live lane PM, else the repo PM, never the sender; refused if there is none |
| `@repo-pm` | the repo PM; refused from a seat whose lane has a live PM (it goes through `@pm`), allowed from that lane PM |
| `@all` | every seat on the machine |

`--to` is required: nothing broadcasts by default. Any other `@scope` is
refused, so nothing is silently undelivered. A lane name is
accepted once a live seat is in that lane or the lane has a PM.

`@<lane>` is a broadcast, by design: it reaches the seats in the lane only when
they run `agent-bus read`, and wakes nobody. The one exception is a work item
(`needs-review`, `blocked`, `handoff`, `question`) sent to it, which gets an
owner and wakes that owner: the lane PM, else the repo PM, else the team's owner
rule (refused, or assigned to `@lead`). A lane PM is set with
`role pm --lane <lane>`. To wake a particular seat, address the seat.

### Claude to Claude

By default (team rule `claude=refuse`), Claude sessions that share a Claude
config dir talk to each other through Claude session messaging (`SendMessage`),
not the bus. A Claude seat posting directly to such a seat (`--to claude/...`)
is refused unless it passes `--allow-claude`. A seat under a different config
dir is never refused (each Claude seat records its `claude_dir`), because
`SendMessage` can't reach it. The flag is a deliberate guard against using the
bus where native messaging would do, so pass it only when the bus itself is
wanted: a ledger record, or a packet its PM or a lane must see. The refusal
message says the same. `@pm`, lanes and broadcasts are unaffected: a Claude
lane PM supervising OpenCode seats is what the bus is for.

Under `claude=refuse`, `reply` needs no `--allow-claude` when the packet was
sent to the replier (its seat, its scope, a role it holds or held when the
packet was sent, or a broadcast it heard; a role's packet is never a broadcast
to a lane of the same name, and a lane's packet never becomes a role's), or to
`@pm` or `@repo-pm`, or it is a work item broadcast to a lane (not to a role of
that name), and the replier is the item's PM, the one routing gives it (see
"The PM" of an item under Messages and work items), and its sender is still
live: that sender chose the bus. Supervising the packet as PM or lead doesn't
count. Otherwise `reply` is refused like `post` unless it passes
`--allow-claude`.

With `claude=allow`, Claude seats can post directly to each other, including
tracked handoffs, questions and review requests, and `--allow-claude` is
accepted but not needed. Either way, a packet to a Claude seat is recorded
before a notification is submitted through the recipient's native Claude inbox
socket. Use the bus for work that needs an owner, review history and an
explicit close reason.

The socket path comes from `CLAUDE_CODE_MESSAGING_SOCKET`. On macOS and Linux,
Claude accepts connections from the same OS user without an auth line. The bus
sends a newline-delimited notification, not the packet body, and does not share
session authentication tokens. Native Windows named-pipe delivery is not
implemented by this adapter.

Claude applies its own inbound controls (`accept`, `hold`, or `refuse`). A
successful write reports only submission, never acceptance, reading, or a wake.
A missing socket or failed write leaves the packet available to the next hook
or `agent-bus read`. A later bus read or reply establishes pickup.

To avoid delivering the same packet through both the socket notice and a hook,
the sender reserves a 30-second hook deferral before connecting. A failed write
releases it immediately. During that window, Claude prompt digests and Stop
hooks skip the notified packet; explicit `read`/`read --peek` remain available
and the packet stays unread. The deferral is shared across worktrees of the
same host session, and with its subagents' child seats. If the notice is held,
refused or lost and no read occurs, later hooks resume delivery after the
window expires. See
[Claude's socket documentation](https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket).

## Messages and work items

A message informs. Work another seat must act on is a **work item**, because a
message leaves no obligation behind.

States `fyi` and `done` are messages. States `needs-review`, `blocked`,
`handoff` and `question` are work items. A work item:

- has one **owner**: its addressee (seat or scope), or the PM when it was sent to
  `@pm` or to a broadcast scope (`@here`, `@repo`, `@all`). Broadcast recipients
  see the item as context, labeled as someone else's, and are never woken for it.
- is **copied to its PM** (the *live* PM of its lane, else the repo PM) wherever
  in the repo it was sent, because senders default to `@here` and a PM never sits
  in the worker's worktree. A PM's own directly addressed items get no copy.
- stays **open** until closed with a reason. Reading it does not close it, and
  neither does gc.

"The PM" of an item is the live PM of a lane it belongs to (the lane it was sent
to, then its own lane: the lane it was last filed in with `agent-bus file`, else
the one it was posted from, as `triage` groups it), else the repo PM. Only that
PM owns it and is woken; the repo PM still sees a lane PM's items as context. A lane PM
whose session has ended routes nothing, so its lane's work falls back to the repo
PM; with no repo PM, it stays with that lane PM for when it comes back. For `@pm`
and broadcasts the sender is skipped, so a lane PM's own `@pm` goes up to the repo
PM. A PM with nobody above it is refused, and that includes the repo PM, whatever
lane it sits in. `@repo-pm` always means the repo PM. Nobody
jumps the hierarchy: a seat whose lane has a live PM can't post `@repo-pm` and
goes through `@pm`, and its lane PM decides whether to take it up with its own
`@pm` or `@repo-pm`. A seat in no lane, or in a lane with no live PM, may post
`@repo-pm`.

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

`agent-bus triage` lists open items in the repo by owner, oldest first. The
owner is the one `snapshot` names: `lead` for `@lead` work, the holder of a
named role, the item's PM, or the seat it was sent to. A packet sent to a lane
never becomes the packet of a role of that name taken later.

- **GONE** — no live seat answers for the owner (an unconfirmed Codex seat
  doesn't). Hand the item on or close it.
- **NOT PICKED UP** — the owner is live but has not read the item after
  `AGENT_BUS_PICKUP_SECS` (600).
- **STALE** — open past `AGENT_BUS_STALE_HOURS` (24).

`agent-bus who` shows the open count and how many have no live owner.

## Team rules

Each repo has five rules. `agent-bus init` asks about the first four (`claude`
is set only with `--set`); `agent-bus init --set k=v,...` is for an agent saving
its user's answers. They are
written to `.agent-bus.json` at the repo root; commit it so the team shares them.
`~/.agents/bus/config.json` holds personal overrides and `AGENT_BUS_POLICY_<KEY>`
overrides both. `agent-bus init --show` prints what applies and, for `claude`,
which layer set it. For `claude`, a personal value (the env var or
`config.json`) always beats a repo `.agent-bus.json`, so a repo file can only
open the rule (`claude=allow`) for someone who has set nothing personally; set
`claude=refuse` in `config.json` to keep it closed everywhere.

| Rule | Values (default first) | Effect |
|---|---|---|
| `owner` | `refuse` · `lead` · `pm` | A work item sent to a broadcast nobody supervises is refused (with live lane peers and `@lead` suggested), owned by the lead, or owned by a lane PM (the lead if there is none) |
| `review` | `none` · `requester` · `lead` | Who accepts handed-off work: nobody (done is done), whoever handed it over, or the lead |
| `ask_lead` | `scope,destructive` · any of `scope`, `destructive`, `disagreement` · `never` | When agents must stop and ask the lead; stated in every orientation |
| `decisions` | `on` · `off` | Show the lane's decisions at session start |
| `claude` | `refuse` · `allow` | Whether a Claude seat may post to a Claude seat under the same config dir without `--allow-claude` (see Claude to Claude) |

A repo with no rules runs on the defaults, and nobody is asked about them up
front: the orientation line states them and tells the agent not to raise them.
Two moments introduce agent-bus instead. While no agent has posted in a repo,
`status` says `new here`, and `/agent-bus` answers with a short intro rather
than a status report. The first work item posted there prints one `tip:` line
saying what the default just did (who checks the work) and that `agent-bus init`
changes it; the agent passes it on in a sentence. Once rules are set, every
orientation line carries a one-sentence summary of them.

## Review gates

By default, closing a handoff is the end of it: `resolve`, `reply` and
`post --close handed-off` send nothing back to the sender beyond the closer's
own reply. A handoff is gated only when it asks for a reviewer: `post --review
<seat|@lead>`, or a team `review` rule of `requester` or `lead`. A gated
`handoff` records its reviewer (`review` on the packet); `--review none`
overrides the team rule; handing it on keeps the same reviewer.

- The doer's `resolve <id> --reason done -m "…"` does not close gated work: it
  hands it to the reviewer as a `needs-review` item (`review_of` → the work).
- `agent-bus review <id> --approve` closes it. `--changes -m "…"` hands it back
  to the doer as a new `handoff` with the same reviewer.
- Nobody approves their own work. A reviewer whose session has ended is
  replaced by `@lead`, so nothing waits on nobody.
- The `needs-review` item is posted by the bus, not chosen by the doer, so it
  carries `auto: true`. It is never framed as PM-assigned work, even when the
  doer is the PM; the digest says agent-bus posted it.

## Decisions

`agent-bus decide "<decision>" -m "why"` records a settled answer for the
current lane (`--lane`, `--repo-wide`). `--supersedes <id>` replaces an older
one. `agent-bus decisions` lists the current ones. With `decisions=on`, every
session on the lane is told them at start; agents follow them or ask the lead.

## The PM

One seat per repo may hold the PM role (`agent-bus role pm`). To supervise one
feature rather than the repo, take a lane's PM role instead (see Lanes). The repo
PM owns work sent to `@repo-pm` (from lane PMs, and from seats whose lane has no
live PM), and work sent to `@pm` or a broadcast scope from seats in no lane or in
a lane without a live PM of its own; it gets a copy of those seats' work items.
It sees every work item in the repo, and may close any of them. Taking the role
from a live holder needs `--force`; a holder gone past `AGENT_BUS_ROLE_TTL` (48h)
loses it at gc.

## Lanes

A lane is the set of seats working on one ticket or feature, whatever worktrees
they sit in. Seats file themselves; nobody has to tell them to. On every command
a seat works out its lane, first match wins:

1. `AGENT_BUS_LANE` in the environment.
2. `agent-bus lane <name>` run on this seat (`--clear` drops it again).
   For a child seat, then its parent's lane, as the parent's seat file records
   it, whatever branch the child sits on.
3. A ticket key in the branch name: `feature/eng-142-skills` is lane `eng-142`.
4. A ticket key in the worktree directory name.
5. The branch name itself, minus prefixes like `feat/` or `claude/`:
   `fix/login-redirect` is lane `login-redirect`.
6. Otherwise none: trunk branches (`main`, `develop`, …) and detached heads.

A ticket key is letters, a dash and 2–6 digits. Prefixes that are really
versions or product names (`gpt-5`, `utf-8`, `sonnet-4`) never count. Set
`AGENT_BUS_TICKET_PREFIXES="eng ops"` to accept only those prefixes. `whoami`
and `lane` show the lane and which rule picked it.

Packets carry their sender's lane, and a lane taken from a ticket key also
travels as `refs: ["ENG-142"]`. Older packets with no lane are grouped on
read by the same rules, applied to the branch and worktree they were sent from,
then to a ticket named in their subject. `agent-bus triage --by lane` groups the
open backlog that way.

The first digest of each session orients the seat, even with no mail: its lane
and why, the lane's open items, its peers in the lane and its lane PM. A seat
with no lane is asked to pick one.

`agent-bus role pm --lane checkout` makes a seat that lane's PM. For its lane only,
a lane PM does what the repo PM does for the whole repo: it gets a copy of every
work item posted by the lane's seats or sent to `@checkout`, owns the ones sent to
`@checkout` or to `@pm` from a lane seat, and may close any of them. The repo PM
no longer owns or is woken for that work, but still sees it. Lane seats reach
the repo PM only through their lane PM, which may post `@repo-pm` itself.
`agent-bus triage --lane checkout` lists the lane's open work, and
`triage --by lane` groups the whole repo's.

Lane names are `[a-z0-9-]`, up to 32 characters, and not `here`, `repo`, `all`,
`pm`, `repo-pm`, `lead` or `unfiled`.

## Lane lifecycle

A lane is open until someone with standing — the lead, the repo PM, or the
lane's PM — changes it. Each change is one `lane` row in the ledger; nothing is
rewritten.

```sh
agent-bus lane eng-142 done --reason merged       # close every open item in it
agent-bus lane eng-142 sweep --older 7d --reason canceled     # just the old ones
agent-bus lane eng-142 park                       # hide from attention
agent-bus lane eng-142 reopen
agent-bus lane eng-142 title --title "Skills card"
agent-bus file <id> eng-150                       # move one item to another lane
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

`@lead` is the human in charge (a seat whose tool is
`lead`). It owns packets sent to `@lead` and may close or change anything. An
agent escalates a work item to the human with
`post --re <id> --close escalated --to @lead --state question`.

## Projects

`~/.agents/bus/projects.json` groups lanes into projects, first match wins;
unmatched lanes fall under their repo:

```json
{"projects": [{"name": "Checkout", "repo": "web-*", "lanes": ["eng-120", "checkout*"]}]}
```

## Delivery

- **Digest.** Claude's `SessionStart` and `UserPromptSubmit` hooks, and the
  OpenCode plugin at session start and before each prompt, run `agent-bus
  digest`. Unread packets this seat **owns** are injected into the model's
  context and marked read. Both hosts inject hook output, so a digest is a
  delivery. Broadcasts never enter the digest: they are context, read with
  `agent-bus read`.
- **Wake.** Only a packet's owners are woken; a broadcast wakes nobody. Only
  a wakeable home wakes anyone from `post`: the default `~/.agents/bus`, or a
  home holding an empty `wakeable` file (a launcher that sets up a dedicated bus
  home can write it). Elsewhere no Claude socket is recorded or poked, no Codex notice is
  queued, no Grok webhook is sent, and `--resume` restarts no OpenCode session.
  The packet still lands: Claude owners see it at their next prompt, a running
  OpenCode plugin still picks it up, and the Codex, Grok and `--resume` delivery
  lines say `wakes off on this home`. `who` says `wakes off`. A throwaway home
  made from inside a live session can't wake that session.
  - Claude: `post` writes a short frame to the owner's inbox socket, which
    starts a turn even while it sits idle. The Stop hook also continues a turn
    that ends with owned items unread.
  - OpenCode: the plugin polls `agent-bus stop-hook` while the session is idle
    and resumes it with the result.
  - Codex (Desktop and CLI): install `agent-bus hooks --codex` and review/trust
    its hooks. SessionStart automatically registers the host-provided session UUID
    and cwd and enables queue delivery when discovery finds a queue-capable
    executable, even without Desktop-specific environment markers.
    UserPromptSubmit/Stop refresh it and retry discovery if unavailable.
    Manual `agent-bus codex enable` also works without hooks. The seat retains its thread UUID and a queue-capable
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
    last hook fire); after that the seat expires at gc. Before then, a seat
    whose notices go unanswered is **unconfirmed**: 3 notices sent
    (`AGENT_BUS_CODEX_UNCONFIRMED_AFTER`), or one left 10 minutes
    (`AGENT_BUS_CODEX_UNCONFIRMED_SECS`, 600), with no command or hook from the
    seat since. A post that finds a notice still outstanding sends none and
    doesn't count, so a chat busy in a long turn isn't demoted for the posts
    that pile up meanwhile. Routing, heirs and the live-lane check skip an
    unconfirmed seat, and it gets no further notices. A lane PM's work goes to
    the repo PM; a post addressed to the seat goes to the live heir in its
    worktree if there is one; a review handed to it goes to `@lead`. Otherwise,
    as for any seat that has gone, its work waits on it and `triage` shows it
    GONE; nothing else moves to `@lead`. A post to a lane whose only members are
    unconfirmed is refused and names them. `who` marks it `UNCONFIRMED`, and
    `snapshot` gives it `unconfirmed` (when its first unanswered notice went out)
    and an `unconfirmed` attention item. It keeps its roles, claims and
    registration until the TTL, and any command or hook from it confirms it
    again. 0 turns either trigger off; a value that isn't a whole number is
    ignored with a warning.
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

## Hook failures

Hook lines run `agent-bus hook <digest|stop-hook|offboard>`, never the bare
subcommand behind `2>/dev/null || true`. `hook` runs the subcommand and always
exits 0, so it never blocks or breaks the session. A Stop hook that fails, or
prints anything but exactly one JSON object, still prints `{}`; a digest with
nothing to say prints nothing. On any failure it appends one tab-separated line
to `$AGENT_BUS_HOME/hook-failures.log` (epoch, UTC time, hook, exit code, error,
session) and rewrites `state/hook-health.json`, one line a status line can read:

    {"ok":false,"failing":["digest"],"recent":3,"last_ts":1760000000,"last_hook":"digest","last_exit":"3","last_error":"stderr withheld","expires":1760086400,"window":86400}

The error is never a value. It is the bus's own first stderr line (`agent-bus: ...`)
with every quoted string replaced by `<str>`, or `stderr withheld` for anything
else, because tools such as `jq` quote the data they choked on, which can be a
packet.

Failing is tracked per hook and per session (`state/hooks-failing/<hook>.<session>`).
`ok` is false while any session has a failure inside the window
(`AGENT_BUS_HOOK_FAIL_WINDOW`, default 24h) that its own later success has not
cleared; one healthy session never clears another's. `recent` counts log lines in
the window, recovered or not. The file is a snapshot: after `expires` its counts
are stale, and the next successful hook run rewrites it.

A hook the host cancels at its timeout cannot log itself. Each run leaves a stamp
(`state/hooks-running/<hook>.<session>`, holding its pid) until it ends; every
`hook` run first sweeps up to 20 stamps, any hook and session, and logs a hang
(exit 124, for the stamp's own hook and session) for each whose process is gone and
that is older than 60s, then removes it; the next run of the same hook and session
does the same for its own stamp. `install-hooks.sh` sets a `timeout` on every Claude hook entry (digest
on each prompt 5s, SessionStart 10s, Stop 10s, SessionEnd 3s) so a hang is bounded.

`agent-bus doctor` prints failing now and recovered within the window separately,
each with when it clears, and exits 1 only for failing now; a recovered failure is
a warning line. The failure path needs no `jq`, so a missing `jq` is reported too.
The log lives in the bus home because a hooked session already writes there. If
even that is unwritable, or there is no `HOME` and no `AGENT_BUS_HOME`, the failure
goes to stderr and the exit is still 0; the host does not show stderr of a hook
that exits 0, so that case is visible only when the hook is run by hand. The log is
trimmed to its newest 500 lines past 1000.

## Delivery report

`post` prints one `delivery:` line per owner it reached: submitted to the Claude
inbox (acceptance and reading unconfirmed), inbox submission unavailable, sees it
at its next prompt, queued a notice, already has an unread notice, wake limit reached,
not running, or has no hooks. A packet nobody owns says so instead of looking
delivered. A post to a seat that has ended goes to the live seat with the same
tool and worktree (`note: … is gone; sending to …`). A `reply` never does: it
goes only to the packet's sender, and waits for it. When a live session holds
that worktree, the delivery line names it (`A live session in that worktree:
…; post to it if you meant to.`).

A Codex chat gets one "check your inbox" notice until it reads; later posts
don't queue more (a notice older than 30 minutes is assumed lost). An OpenCode
seat whose process has stopped is reported as not running, and `post --resume`
(or `AGENT_BUS_RESUME=1`) restarts it with `opencode run --session` (on a
wakeable home only).

One host session that runs bus commands from two folders holds two seats.
`read`, the digest and wakes count packets sent to either.

## Replying, asking and sending

- `reply <id> -m …` answers the sender and closes the item in one row (reason
  `done` by default). Gated work goes to its reviewer, as `resolve` does.
  It goes only to the packet's sender, never to a seat that took over the
  sender's worktree. To a Claude sender it needs no `--allow-claude` when the
  packet was sent to you (or to `@pm` or `@repo-pm`, or it is a work item
  broadcast to a lane, and you are its PM), not only supervised by you, and the
  sender is still live.
  `--keep-open` answers without closing. `resolve` defaults to `done` too.
- `ask --to <seat> -m …` posts a `question` and waits (default 600 s) for a
  reply or a close; exit 2 on timeout, with the question left open.
- `send --to <seat>[,<seat>] -m …` is for the human in their own terminal. It
  needs a tty and a typed yes, and stamps `user: true` on the packet, which
  renders as "from your user". It is a speed bump, not an authorization
  boundary (see Trust model).

## Claims

`agent-bus claim <path>` takes an advisory claim for 4 hours
(`AGENT_BUS_CLAIM_TTL`). Paths are repo-relative, so one file claimed from two
worktrees collides. A claim held by another live seat prints `CONTESTED`: post a
`question`, don't overwrite. A claim left by a seat that has ended is taken over
by the next claimer. Only the holder releases; `release --force` breaks a claim
and records the break in the ledger.

Claims also take names for things that aren't files, `kind:name`, such as
`mr:3594` or `ticket:ENG-142`, so seats about to act on the same MR see who has
it. `read` and the digest show other seats' claims only where they touch a path
this seat claims or has changed; `agent-bus claims` lists them all.

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

The same goes for `send`'s "from your user" label. It needs a terminal and a
typed yes, and the flag behind it is never read from the environment, so an
agent can't set it by accident. A process that fakes a terminal, or writes the
ledger directly, can still forge it.

Packets are still treated as hostile input: bodies are capped at 64KB, control
characters are stripped from everything rendered, and ids are shape-checked
before they become paths.

## Peers

Each machine keeps its own bus. Machines on one network link with
`agent-bus peer add <host>` and sync over SSH; a shared folder can't work,
because the ledger lock trusts PIDs and a PID from another machine always
looks dead.

- **Pairing.** `peer add` logs in once with the user's own SSH (password or
  key) and runs `peer accept` there. Each side makes its own key
  (`~/.agents/bus/peer_key`) and adds the other's to `~/.ssh/authorized_keys`
  as `command="… agent-bus peer serve",restrict … agent-bus-peer:<host>`.
  `peer serve` reads `SSH_ORIGINAL_COMMAND` and runs only `version`, `who`,
  `seats`, `ingest <from>`, `export <epoch>` and `check <host>`, each word
  shape-checked. `peer remove` deletes the line. A bus that is not
  `~/.agents/bus` (`AGENT_BUS_HOME`) pairs as itself: its forced command
  carries `AGENT_BUS_HOME=<path>`, its marker is
  `agent-bus-peer:<host>:<hash of the path>`, and `peer add` asks the other
  Mac for the same path under its own `$HOME`. `remove` and `uninstall` touch
  only the running bus's lines.
- **Sync.** The ledger is append-only, so a merge appends the lines the
  receiver lacks (checked against the ledger and its archive). Message bodies
  travel with their rows. Every write, `post` included, pushes in the
  background (`tmp/peer-push.log` has the far side's delivery lines). Linking
  starts at the current time: history stays on the machine that made it.
- **Trust.** A peer's payload is checked on both export and ingest. A row is
  kept only if it is a JSON object whose ids match the packet-id shape, whose
  `from`/`by`/`addr`/`holder` are seat addresses, and (for a `msg`) whose
  state is a known one; the rest are dropped without stopping the sync. Bodies
  are copied only for accepted `msg` rows, by id, and only from regular files:
  a symlink in the payload is never followed.
- **Delivery.** The receiver wakes its own owners of new messages less than
  15 minutes old, the same way a local post does.
- **Catch-up.** The `digest` and `heartbeat` hooks start a background
  `peer sync` (push and pull) at most once a minute
  (`AGENT_BUS_PEER_EVERY`). A pull also caches the peer's live seats in
  `state/peer.<host>.seats.json`, which `who` lists and `post` uses to name
  the machine a recipient is on.
- **Repo identity** comes from the path of the git common dir, so a repo
  counts as the same on two machines only at the same path. Claims are files
  and stay local.

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
  ledger.archive.jsonl.1  the previous archive: past AGENT_BUS_ARCHIVE_MAX_BYTES (10 MB) gc moves the archive here,
                        replacing (deleting) the older .1; retention is the last two archives, about 10-20 MB
  msg/<id>.md           packet bodies
  seats/<seat>.json     seat registry (grok seats include grok_webhook, grok_secret_env)
  seats/<seat>.wakes    epochs of Codex notices sent (queued or uncertain), read to mark unconfirmed seats
  secrets/grok_<n>.secret  0600 webhook bearer token (written at grok register)
  state/<seat>.json     read cursor, wake count, grok_attempts list
  state/sessions/<tool>.<hash>  a session's pinned worktree name (AGENT_BUS_SEAT_KEY=session)
  state/roles/<r>.pm    repo PM
  state/roles/<r>.lane.<l>.pm  lane PM
  claims/<hash>.json    claims
  hook-failures.log     one line per failed hook run (see Hook failures)
  state/hook-health.json  one-line health for a status line
  state/hooks-failing/<hook>.<session>  marks a hook failing now, per session
  wakeable              empty marker: a home other than ~/.agents/bus may wake sessions (Claude sockets, Codex queue, OpenCode --resume, Grok webhooks)
```

A `msg` row carries `re` (the packet it replies to) and, when it closes that
packet, `close` (the reason). A `msg` sent to an `@` target carries `to_role`:
the seat that held a role of that name when it was posted (`--to @release`), or
`""` for a lane or broadcast. `reply` reads it, so a role taken or let go later
never changes who the packet was sent to, and routing reads it, so a lane's
packet never becomes a role's. A `resolve` row carries `msg`, `by`
and `reason`.
Rows written before v2 have no reason and still close their packet.

gc prunes expired claims, dead seats, old bodies and abandoned roles, and runs
from hooks at most once a day (`AGENT_BUS_NO_AUTO_GC=1` to opt out). It never
closes a work item, and never archives an open one: open items and their bodies
stay in `ledger.jsonl` however old they are, so `triage` always sees them.
Before this rule, gc archived open items with everything else after 14 days;
`agent-bus gc --restore-open` moves those back, from the archive and `.1` (their bodies are already gone).
Peer ingest and the first-run check also read `.1`, so a rotation hides no history from them.

## Codex hook installation

`install-hooks.sh --codex` adds only four marked command hooks: SessionStart,
UserPromptSubmit, Stop, and SessionEnd. The hook adapter validates the host's
session UUID and absolute cwd, ignores inherited parent identity, and never
reads credentials or peer payloads. Startup emits a fixed protocol reminder;
no hook marks packets read. New/changed hooks require the user's normal Codex
trust review. The installer does not edit `config.toml`, permissions, or trust.
Uninstall removes these hooks and disables existing Codex queue registrations.
Other hosts' hooks/plugin and unrelated Codex hooks are retained.
