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
| `@pm` | the sender's lane PM and the repo PM (refused if neither exists) |
| `@all` | every seat on the machine |

`--to` is required: nothing broadcasts by default. Any other `@scope` is
refused, so nothing is silently undelivered. A lane name is
accepted once a live seat is in that lane or the lane has a PM.

### Claude to Claude

Claude seats can post directly to each other, including tracked handoffs,
questions and review requests. The packet is recorded before a notification is
submitted through the recipient's native Claude inbox socket. `--allow-claude`
is accepted for compatibility but is no longer needed. Direct `SendMessage`
remains available for quick conversation. Use the bus for work that needs an
owner, review history and an explicit close reason; do not move tracked work to
`SendMessage` just because both seats are Claude.

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
same host session. If the notice is held, refused or lost and no read occurs,
later hooks resume delivery after the window expires. See
[Claude's socket documentation](https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket).

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

## Team rules

Each repo sets four rules once, with `agent-bus init` (asks) or
`agent-bus init --set k=v,...` (an agent saving its user's answers). They are
written to `.agent-bus.json` at the repo root; commit it so the team shares them.
`~/.agents/bus/config.json` holds personal overrides and `AGENT_BUS_POLICY_<KEY>`
overrides both. `agent-bus init --show` prints what applies.

| Rule | Values (default first) | Effect |
|---|---|---|
| `owner` | `refuse` · `lead` · `pm` | A work item sent to a broadcast nobody supervises is refused (with live lane peers and `@lead` suggested), owned by the lead, or owned by a lane PM (the lead if there is none) |
| `review` | `requester` · `lead` · `none` | Who accepts handed-off work: whoever handed it over, the lead, or nobody |
| `ask_lead` | `scope,destructive` · any of `scope`, `destructive`, `disagreement` · `never` | When agents must stop and ask the lead; stated in every orientation |
| `decisions` | `on` · `off` | Show the lane's decisions at session start |
| `proof` | `off` · `warn` · `require` | Review requests name their commit and carry proof without `--proof auto`; `warn` says what the reviewer will see, `require` refuses one without passing checks run at that commit |
| `supervise` | `off` · `on` | Run the supervisor (`agent-bus watch`, below) and let a restarted PM take its lane's role back |
| `fyi_wake` | `on` · `off` | Off: `fyi` and `done` packets wake nobody; they wait in the digest and `read`. An answer to open work (a reply to a question, blocker, review or handoff) always wakes |
| `thread_reports` | `off` · `on` | On: a report rides on the sender's one open assignment from its recipient (`re`), and a second post of the same kind right behind an unread first one folds into it without waking again; `--new-thread` opts out |

The last three change delivery for every seat, so they stay off until set,
normally in `~/.agents/bus/config.json` by whoever runs the team.

A repo with no rules runs on the defaults, and nobody is asked about them up
front: the orientation line states them and tells the agent not to raise them.
Two moments introduce agent-bus instead. While no agent has posted in a repo,
`status` says `new here`, and `/agent-bus` answers with a short intro rather
than a status report. The first work item posted there prints one `tip:` line
saying what the default just did (who checks the work) and that `agent-bus init`
changes it; the agent passes it on in a sentence. Once rules are set, every
orientation line carries a one-sentence summary of them.

## Review gates

Closing isn't accepting. A `handoff` records its reviewer (`review` on the
packet): by default whoever handed it over; `post --review <seat|@lead|none>`
overrides; handing it on keeps the same reviewer.

- The doer's `resolve <id> --reason done -m "…"` does not close gated work: it
  hands it to the reviewer as a `needs-review` item (`review_of` → the work).
- `agent-bus review <id> --approve` closes it. `--changes -m "…"` hands it back
  to the doer as a new `handoff` with the same reviewer.
- Nobody approves their own work. A reviewer whose session has ended is
  replaced by `@lead`, so nothing waits on nobody.

## Review proof

Evidence that isn't tied to a commit gets reused after the code moves on. A
review request can name the commit it asks about and carry the checks and
artifacts behind it:

```sh
agent-bus proof run -- npm test          # runs it here; records exit code and HEAD
agent-bus proof add out/screens.png      # records a file, its sha256 and HEAD
agent-bus post --to <seat> --state needs-review --proof auto -m "..."
```

`--proof auto` (the default under `proof=warn|require`) records `sha` (HEAD)
and `dirty` on the packet, and attaches this worktree's newest record per
command and per file from the last 24h as `proof`. Every reader gets one line:
`proof at abc1234: 3 check(s) passed, 1 artifact(s), all made at this commit`,
or `STALE OR FAILING:` with each problem named: a check or file made at an older
commit, a check run on uncommitted changes, a request posted with uncommitted
changes, a failing exit code. A reviewer whose checkout of the branch has moved
past the commit is told so. `agent-bus show <id>` lists every entry.

Records live per worktree in `proof/<hash>.jsonl`; `proof show` lists them
against HEAD, `proof clear` sets them aside (renamed, not deleted).

## Decisions

`agent-bus decide "<decision>" -m "why"` records a settled answer for the
current lane (`--lane`, `--repo-wide`). `--supersedes <id>` replaces an older
one. `agent-bus decisions` lists the current ones. With `decisions=on`, every
session on the lane is told them at start; agents follow them or ask the lead.

**Standing decisions** are the user's own calls that hold everywhere: a
permission, a direction, a fact that keeps getting forgotten. Only the lead,
or the seat named in `watch.lead`, records one, and it names where the user
said it:

```sh
agent-bus decide --global --confirmed "Scott, ask panel, 9:14 PM" "Agents may write Dev secrets" -m "why"
agent-bus decide --global --confirmed "…" --supersedes <id> "<the new call>"
agent-bus decide --retract <id> -m "why"
agent-bus decisions --global
```

Every seat in every repo reads the current ones at its first digest, and
again whenever its host's SessionStart hook fires: a resume, `/clear` or a
compaction, which is when a seat loses what it knew. They are stated as
replacing anything the seat remembers, so a stale fact dies with the next
reset instead of surviving it. Superseded and retracted ones drop out.

## The PM

One seat per repo may hold the PM role (`agent-bus role pm`). To supervise one
feature rather than the repo, take a lane's PM role instead (see Lanes). It owns work sent
to `@pm` or a broadcast scope, receives a copy of every work item in the repo,
and may close any of them. Taking the role from a live holder needs `--force`;
a holder gone past `AGENT_BUS_ROLE_TTL` (48h) loses it at gc.

A PM role belongs to its lane, not the session. Line 1 of the role file is the
holder's address; line 2 records the lane, the tool and worktree, and the
Herdr terminal. With `supervise=on`, when the holder is gone, the seat that
plainly succeeded it takes the role back at its next prompt (`PM role for lane
@x taken back by …`): the seat in the same Herdr terminal, or else the only
live seat with the holder's tool, worktree and lane. Two possible successors
means neither takes it.

## Lanes

A lane is the set of seats working on one ticket or feature, whatever worktrees
they sit in. Seats file themselves; nobody has to tell them to. On every command
a seat works out its lane, first match wins:

1. `AGENT_BUS_LANE` in the environment.
2. `agent-bus lane <name>` run on this seat (`--clear` drops it again).
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
still sees everything. `agent-bus triage --lane checkout` lists the lane's open
work, and `triage --by lane` groups the whole repo's.

Lane names are `[a-z0-9-]`, up to 32 characters, and not `here`, `repo`, `all`
or `pm`.

### Nested lanes

A lane may sit under another lane, to any depth: an area over its tickets, or
an area over projects over tickets.

```sh
agent-bus lane eng-142 under checkout     # eng-142 is now part of checkout
agent-bus lane eng-142 under --clear      # back to the top level
```

A seat may file its own lane; anyone else needs standing over the lane or over
the new parent (the lead, the repo PM, or a PM of a lane above). A launcher
does it without a command: a seat started with `AGENT_BUS_LANE_PARENT=checkout`
files its lane under `checkout` the first time it is seen, unless the lane
already has a parent. Each change is one `lane` row carrying `parent`; a loop
is refused.

Everything a lane PM does for its lane, it does for the lanes beneath it:

- it gets a copy of every work item posted from them or sent to them;
- `@pm` from a seat goes to the **nearest** PM up the tree, and the PMs above
  that one still get their copy;
- it may close their items and run their lifecycle (`lane <child> done`);
- its packets are marked as the PM's for seats in those lanes;
- `--to @checkout` reaches the seats in `checkout` and in every lane under it.

`lane <name> done` and `sweep` close only that lane's own items; lanes under it
keep theirs. `triage --lane <name>` lists the whole subtree. `snapshot` and
`lanes --json` give each lane its `parent`, its `path` from the top and `sup`,
the PM who answers for it; `lanes` prints the tree.

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
- **Wake.** Only a packet's owners are woken; a broadcast wakes nobody.
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

## Delivery report

`post` prints one `delivery:` line per owner it reached: submitted to the Claude
inbox (acceptance and reading unconfirmed), inbox submission unavailable, sees it
at its next prompt, queued a notice, already has an unread notice, wake limit reached,
not running, or has no hooks. A packet nobody owns says so instead of looking
delivered. A post to a seat that has ended goes to the live seat with the same
tool and worktree (`note: … is gone; sending to …`).

A Codex chat gets one "check your inbox" notice until it reads; later posts
don't queue more (a notice older than 30 minutes is assumed lost). An OpenCode
seat whose process has stopped is reported as not running, and `post --resume`
(or `AGENT_BUS_RESUME=1`) restarts it with `opencode run --session`.

One host session that runs bus commands from two folders holds two seats.
`read`, the digest and wakes count packets sent to either.

## The supervisor

`agent-bus watch` makes one pass over every repo with seats or open work;
`agent-bus watch --install` runs it from launchd every 2 minutes, and it does
nothing unless `supervise=on`. It posts as `watch/supervisor`.

Herdr is optional. agent-bus needs no terminal manager; when a seat happens
to run in a Herdr terminal (`HC_TERMINAL_ID` is set
and `hc` is installed), the watch can also type a wake line into it and read
whether a turn is in progress. Without Herdr every wake below uses the host's
own channel, exactly as `post` does.

- **Unread work.** A work item its owner has not read after `wake_after`
  (600s) wakes the owner through its own tool: its Herdr terminal if it has one (`hc send`,
  only into a live agent that is idle or done; never a shell, never mid-turn,
  never the lead's terminal or one listed in `watch.no_type`),
  else the Claude socket, an OpenCode resume or the Codex queue. The text names
  only the packet id and state. Still unread `wake_after` later, or the owner
  is gone, a `blocked` alert goes to the lane PM, else the repo PM (never the
  owner itself), else the lead. Still unread after another `wake_after`, the
  lead hears.
- **Backlog stays with triage.** Items older than `max_age` (86400s) are not
  in the ladder, so turning the watch on does not page anyone about last
  week's backlog; `agent-bus triage` lists them.
- **The lead gets one packet.** Everything for the lead (work nobody picked
  up, stale seats with no live PM to tell, lanes with no live PM) goes in one
  open packet whose body is rewritten in place each pass. It closes itself
  when the list is empty.
- **Stale seats.** A live seat that has read open work sent to it directly
  (not through a PM role) and has shown no activity for `stale_after`
  (1200s) is stale. Unread work is the wake ladder's, and claims alone are a
  finished worker's leftovers, so neither makes a seat stale. Activity is the
  newest of, across every worktree the same session works in: a hook or CLI
  call, a packet, a commit, a dirty file, or a Herdr turn in progress.
  `agent-bus wait --until 30m|HH:MM -m why` declares a wait (CI, a long job)
  that counts as activity until then. Its PM gets one alert; `who` marks it
  `STALE (watch)`. Its claims move to `archive/claims/` only when its
  worktree is clean; with uncommitted changes they stay, so nobody edits over
  unsaved work. A gone seat's claims move aside. Work is never reassigned.
- **Dark lanes.** A lane whose PM is not live is listed for the lead.
  `agent-bus lane <lane> park` (or `lane park <lane>`) silences it until a PM
  takes the role again. The seat named in `watch.lead` may change any lane's
  lifecycle, like the lead.
- **Never stale:** Grok bots, the lead and the watch, and anything in
  `watch.exempt` (seat addresses, tool/worktree scopes or tool names). A seat
  is reported once per quiet spell and at most once an hour.
- **Alerts close themselves** (`superseded`) once what they report is read,
  closed, active again or has a PM.

Settings: `~/.agents/bus/config.json` `{"watch": {"wake_after": 600,
"stale_after": 1200, "max_age": 86400, "lead": "@lead", "no_type": ["t1c"]}}`, or
`AGENT_BUS_WATCH_WAKE_AFTER`, `AGENT_BUS_WATCH_STALE_AFTER`,
`AGENT_BUS_WATCH_MAX_AGE`, `AGENT_BUS_WATCH_LEAD`, `AGENT_BUS_WATCH_NO_TYPE`
(comma-separated). `no_type` lists Herdr terminals or seats a person types in;
they are woken by their host's own channel (the Claude socket), never typed into. `lead` may be a seat
address when the lead works through an agent seat. `watch --status` prints what
applies. State lives in `state/watch.json`; alerts are ordinary `msg` rows with
an `alert` field (`kind` unread|stale|no-pm, `items`, `seat`, `lane`).

## Replying, asking and sending

- `reply <id> -m …` answers the sender and closes the item in one row (reason
  `done` by default). Gated work goes to its reviewer, as `resolve` does.
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
  msg/<id>.md           packet bodies
  seats/<seat>.json     seat registry (grok seats include grok_webhook, grok_secret_env)
  secrets/grok_<n>.secret  0600 webhook bearer token (written at grok register)
  state/<seat>.json     read cursor, wake count, grok_attempts list
  proof/<hash>.jsonl    per-worktree proof records (checks, artifacts)
  state/roles/<r>.pm    repo PM (line 2: what the role is bound to)
  state/roles/<r>.lane.<l>.pm  lane PM
  state/watch.json      supervisor ladder, stale seats, dark lanes
  archive/claims/<ts>/  claims the supervisor moved aside
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
