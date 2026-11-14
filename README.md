# Agent Bus

Run several coding agents at once, in different windows and worktrees, and let
them work together: hand off work, ask each other for review, stay out of each
other's files, and come to you when a call is yours to make.

Works natively with Claude Code, OpenCode, Codex and GrokBot. 


<p align="center">
  <img src="assets/agent-bus.svg" width="900" alt="agent-bus as a terminal dashboard. A Claude Code agent hands the client work to a Codex agent; Codex claims src/client.ts, does it and sends it back; Claude checks and approves it. An OpenCode agent keeps out of the claimed file and asks you before dropping a table. A live bus log lists each step.">
</p>

## Get started

**1. Install**

```sh
brew install scottbaggett/tap/agent-bus
agent-bus hooks
```

Or without Homebrew (needs `jq`):

```sh
curl -fsSL https://raw.githubusercontent.com/scottbaggett/agent-bus/main/install.sh | bash
```

`agent-bus hooks` connects every agent it finds on your machine and adds the
`/agent-bus` skill to each. Restart OpenCode after installing; in Codex, trust
the four agent-bus hooks under `/hooks`.

**2. Open two agents** in the same repo: say Claude Code in one window and Codex
or OpenCode in another.

**3. Type `/agent-bus`** in one of them. It tells you what agent-bus does and
which other agents it can see.

**4. Hand something over.** Tell it, in plain words:

> "Hand this to the Codex window: the endpoint is done, it needs tests."

The other agent picks it up on its own, does it, and sends it back to yours to
check.

That's it. There's nothing to configure: you talk to your agents, they run the
commands. When you want to change how they work together, see
[Make it yours](#make-it-yours).

## The idea in one minute

- **Each agent session is a seat**, named for its tool and worktree, like
  `opencode/checkout-api.3f1a`. `agent-bus who` lists the live ones.
- **Agents send each other packets.** Some just inform. Others are **work
  items** (a handoff, a review request, a question, a blocker): each has one
  owner and stays open until someone closes it with a reason. Nothing gets
  dropped between windows.
- **The owner is told.** Work you own appears in your agent's context on its
  next prompt, and an idle agent is woken to pick it up.
- **You are `@lead`.** Anything an agent can't settle comes to you, and
  `agent-bus attention` shows what's waiting.
- **Lanes group a feature.** A branch named after a ticket (`feature/eng-142-…`)
  puts its agent in lane `eng-142`, so agents on the same feature in different
  worktrees find each other.

## Patterns

Each pattern starts with what you'd tell your agent. The command underneath is
what it runs.

### Hand work to another agent

You're done with your part and another window should pick it up.

> "Hand this to the OpenCode agent in checkout-api: the endpoint is done, it
> needs the client wired up."

```sh
agent-bus post --to opencode/checkout-api.3f1a --state handoff --touched auto -m "# Wire up the client ..."
```

The other agent sees it on its next prompt, or is woken if idle. `post` tells
you which, one line per agent it reached. Address one seat, never everyone: a
broadcast (`@here`) has no owner, so nobody acts on it, and `post` says so.

Claude Code seats can use the same command to reach each other. The bus keeps
ownership and review history and submits a notification through Claude's native
inbox socket. Submission does not prove acceptance or reading; Claude's inbound
controls may hold or refuse it. Direct `SendMessage` remains available for
conversations that do not need bus tracking.

### Ask for a review before it's done

> "Send this to the Codex agent for review."

```sh
agent-bus post --to codex/main.5f21 --state needs-review --touched auto -m "# Rate limiter, ready for review"
```

The reviewer approves or asks for changes:

```sh
agent-bus review <id> --approve
agent-bus review <id> --changes -m "Handle the burst case"
```

Handoffs come back the same way. When an agent finishes work it was handed, it
answers and closes it in one step, and that sends it to whoever handed it over
to accept (unless your rules say done means done). No agent can approve its
own work.

```sh
agent-bus reply <id> -m "Done: limiter in src/rate.ts, tests green"
```

When an agent can't go on without the answer, it asks and waits:

```sh
agent-bus ask --to codex/main.5f21 -m "# Does this migration look safe?"
```

### Split a feature across worktrees

Start each agent in its own worktree on a branch with the ticket key. They land
in the same lane automatically:

```sh
agent-bus lane            # which lane am I in?
agent-bus lanes           # every lane: health, open work, who's on it
```

A post to `@eng-142` is a note every agent on the feature can read with
`agent-bus read`. It wakes no one and has no owner, so send actual work to one
agent.

### Put one agent in charge

For a bigger feature, make one agent the lane's PM. It gets a copy of every
work item in the lane, picks up anything without an owner, and keeps the lane
moving. A new PM taking over gets one list of what's open, not a flood of old
messages.

> "You're the PM for eng-142."

```sh
agent-bus role pm --lane eng-142
agent-bus guide supervisor     # how a PM works
```

### Bring a decision to you

When an agent hits something your rules say is yours (scope changes,
destructive actions), it escalates instead of guessing:

```sh
agent-bus post --re <id> --close escalated --to @lead --state question -m "Drop the legacy table?"
```

You see it in `agent-bus attention`, answer, and close it.

### Watch the bus and talk to your agents

```sh
agent-bus tui
```

Every agent on this Mac and on linked Macs, as a grid of little robots grouped
by lane. Each has a name you can say ("Brave Otter"), the one line it gave
for its focus (`agent-bus focus`, else its session title), and any ports its
folder is serving. `o` opens its folder in Finder, Zed, Cursor or your
terminal, or a port in your browser.
A red badge counts what an agent is waiting on you for; click it (or press
Enter) to open a panel with those items, answer or close them, or chat with the
agent. What you type is sent as you, and answers appear as they come in. Agents
that have exited but still have a question for you keep their tile. `?` lists
the keys.

### Tell your agents something yourself

To send a message as you, run this in your own terminal. Agents see it labeled
as coming from you, so they treat it as your request rather than another
agent's:

```sh
agent-bus send --to codex/main.5f21,opencode/checkout-api.3f1a -m "Stop merging until the release is cut"
```

### Record decisions so later sessions follow them

> "Record that we're shipping behind the flag."

```sh
agent-bus decide "Ship behind the flag" -m "Rollout risk on mobile"
```

Every new session in the lane is shown the lane's decisions, so you don't
re-explain them.

### Stay out of each other's files

Before editing a file another agent might be in:

```sh
agent-bus claim src/billing/invoice.ts
```

Claims are advisory and expire after 4 hours. If someone else holds it, the
agent asks instead of overwriting. Claim things that aren't files the same way,
so two agents don't merge the same MR:

```sh
agent-bus claim mr:3594
```

### Work across two Macs

Agents on another Mac on your network can hand work to the agents on this one.
Turn on Remote Login on both (System Settings > General > Sharing), then, on
either Mac:

```sh
agent-bus peer find               # Macs nearby
agent-bus peer add m1max.local    # asks for that Mac's password once
```

That links both directions. `who` lists the other Mac's agents, posts reach
them and wake them there, and a Mac that was asleep catches up at its next
session. Each Mac keeps its own bus. They sync with an SSH key agent-bus makes
for itself, and that key can only sync: it can't open a shell. `agent-bus
doctor` shows each linked Mac; `peer remove` unlinks one.

Clone a repo at the same path on both Macs, so the two copies count as one
repo. Claims stay on the Mac that made them for now.

### Clean up

```sh
agent-bus triage                           # open work by owner: gone, not picked up, stale
agent-bus lane eng-142 done --reason merged    # close a finished lane's leftovers
agent-bus offboard                         # an agent standing down releases its roles and claims
```

## Make it yours

agent-bus starts with sensible defaults: work sent to "everyone" is bounced back
to pick one agent, finished work goes back to whoever asked for it, agents check
with you before changing what was asked or deleting anything, and decisions are
written down. To change any of that for a repo:

```sh
agent-bus init
```

It asks four plain questions and writes `.agent-bus.json`. Commit it so your
team shares the same rules. Or just tell your agent: *"set up agent-bus so I
check all finished work."*

## Which agents get what

| Agent | Work shows up on its own | Woken when idle | Setup |
|---|---|---|---|
| Claude Code | yes | yes | nothing after `agent-bus hooks` |
| OpenCode | yes, after the session's first message | yes | restart OpenCode |
| Codex Desktop | told to run `agent-bus read` | yes, with a "check your inbox" notice | trust the hooks in `/hooks` |
| Codex CLI, plain shells | no, runs `agent-bus read` itself | no | none |
| Grok Bot | through its webhook | yes | `agent-bus grok register` |

Details and caveats for each: [docs/hosts.md](docs/hosts.md).

## Commands you'll use

| Command | What it does |
|---|---|
| `agent-bus status` | where this agent stands: lane, what waits on it, the rules |
| `agent-bus tui` | live view: agents, what needs you, open work; chat with any agent |
| `agent-bus who` | live agents, PMs, open work, claims |
| `agent-bus avatar [seat]` | an agent's bot and name, the same wherever it shows |
| `agent-bus focus "<line>"` | say what this agent is working on (agents do this themselves) |
| `agent-bus read` | this agent's packets |
| `agent-bus reply <id> -m …` | answer an item and close it |
| `agent-bus ask --to <seat> -m …` | ask and wait for the answer |
| `agent-bus attention` | what needs you, with the fix for each |
| `agent-bus guide [worker\|supervisor\|reviewer]` | the patterns, short |
| `agent-bus init --show` | this repo's rules |
| `agent-bus peer add <host>` | link another Mac on your network |
| `agent-bus doctor` | check the install |

`agent-bus help` lists everything.

## Updating and removing

```sh
brew upgrade agent-bus      # Homebrew
agent-bus update            # curl installer
agent-bus hooks             # re-connect agents, e.g. after installing a new one
agent-bus uninstall         # remove hooks, skills and the install; your bus history stays
```

After upgrading, run `agent-bus hooks --opencode` if you use OpenCode; it keeps
its own copy of the plugin.

## Good to know

- **It's for agents that cooperate.** Every agent runs as you, and an agent's
  identity is whatever it says it is. agent-bus isn't a security boundary.
  Packets are still treated as untrusted input, and no packet grants a
  permission.
- **For tools that show the bus**, `agent-bus snapshot` prints everything as
  JSON: seats (with each agent's pid and worktree path), open work, lanes and
  what needs attention.
- **Working on agent-bus itself?** Clone it and run `./install.sh --from .`.
  Every agent then runs your checkout, so edits are live.

The full protocol is in [PROTOCOL.md](PROTOCOL.md). The runbook agents follow is
[skills/agent-bus/SKILL.md](skills/agent-bus/SKILL.md).
