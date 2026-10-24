# agent-bus

<p align="center">
  <img src="assets/agent-bus.svg" width="760" alt="A yellow school bus labeled AGENT BUS with robot agents in the windows, a PM robot driving, a roof sign reading @here to @repo, and a handoff packet flying out behind.">
</p>

A handoff bus for coding agents in different windows on the same repo. Claude
Code, OpenCode, and Codex Desktop sessions hand work to each other, claim files,
and wake each other when there is work to do.

No daemon, no server. One bash script, `jq`, and an append-only log under
`~/.agents/bus/`. Codex queue delivery additionally uses Python 3.

## Install

```sh
ln -sf "$PWD/bin/agent-bus" ~/.local/bin/agent-bus
./install-hooks.sh            # Claude hooks + OpenCode plugin; --uninstall reverses
```

Upgrading from v1: `./install-hooks.sh --remove-legacy` strips the Codex and
Cursor hooks v1 installed. Claude hooks from v1 keep working unchanged.

### Codex Desktop

Install the Codex lifecycle integration once:

```sh
./install-hooks.sh --codex
```

Review and trust the four agent-bus hooks in Codex (`/hooks`). Codex requires
trust for each new or changed hook definition; the installer never edits trust
settings. Existing Claude/OpenCode configuration and unrelated Codex hooks are
preserved. Restart/resume the chat after review so its startup hook can run.

Trusted hooks automatically register each Desktop chat from the host's actual
session ID and working directory. Prompt/stop events refresh its registration;
SessionEnd removes that thread's seats, roles, and claims across directories,
without closing unfinished work. Hook-registered chats remain reachable while
idle, without heartbeat polling. A crash can leave a stale registration; queue
acceptance still does not prove the chat ran. Normal CLI sessions stay pull-only.

```sh
agent-bus codex status       # queue mode, hook activity, budget, last delivery
agent-bus codex disable      # pause this seat; hooks respect the pause
agent-bus codex enable       # resume, or manually connect without hooks
agent-bus doctor             # installation and delivery diagnostics
```

The agent reads peer content with `agent-bus read` and replies with the normal
`post --re ... --close done --to ... --state done` command. A queue notice grants
no permission to follow arbitrary peer instructions. Already accepted notices
cannot be recalled. `./install-hooks.sh --codex --uninstall` removes only the
managed Codex hooks and disables existing Codex queue registrations. A normal
`offboard` also disables and removes that Codex seat.

Python 3 and a queue-capable Codex executable are required on the sender's
machine. Discovery uses the Desktop runtime executable, then known app bundles,
then PATH, which may contain an older CLI. Set `AGENT_BUS_CODEX_BIN` for a custom
installation. Use the same bus directory and Codex account/home in both hosts.
With a custom `AGENT_BUS_HOME`, provide that configuration to the receiving
chat and its hook commands too. `AGENT_BUS_CODEX_SETTINGS` can select a different
hooks file for installation.

The Desktop app and registered chat must remain loaded for unattended wake.
Queue acceptance is not proof of execution: read marks and a reply prove receipt.
Agent-bus adds no polling loop or recurring model run, but the tested Codex
implementation checks external queue writes about every ten seconds. Archived
or unloaded chats, app restart recovery, and busy-turn ordering are not qualified.


## Use

```sh
agent-bus who                   # live seats, the PM, open work, claims
agent-bus read                  # your packets
agent-bus post --to <seat|@pm> --state needs-review --touched auto --file handoff.md
agent-bus post --re <id> --close handed-off --to <seat> --state handoff -m "..."
agent-bus resolve <id> --reason done
agent-bus triage                # open work by owner: GONE, NOT PICKED UP, STALE
agent-bus claim src/thing.ts    # advisory; CONTESTED if another seat holds it
agent-bus lane spaces           # this seat works on the spaces feature
agent-bus role pm --lane spaces # supervise that feature (or plain `role pm` for the repo)
agent-bus offboard              # stand down
```

## How it works

**Seats.** Each agent session is a seat, `<tool>/<worktree>.<inst>`, with
`<inst>` hashed from the host session id.

**Messages and work items.** `fyi` and `done` packets inform. `needs-review`,
`blocked`, `handoff` and `question` packets are work items: each has one owner
and stays open until someone closes it with a reason (`done`, `handed-off`,
`denied`, `canceled`, `duplicate`). Handing an item on closes it and opens the
next one in a single ledger row, so work never strands between seats. `triage`
shows what is open and flags owners that have gone away.

**The PM.** One seat per repo can take the PM role. It gets a copy of every work
item in the repo and owns the ones sent to a broadcast scope or `@pm`. A **lane**
groups the seats on one feature across worktrees; a lane PM does the same for
that lane only, and `--to @<lane>` reaches its seats.

**Delivery.** Hooks (Claude) and the plugin (OpenCode) inject unread packets
into the model's context at session start and on every prompt. Owners are woken
when idle: Claude through its inbox socket and Stop hook, OpenCode through the
plugin; opted-in Codex Desktop chats through `codex queue`. Claude/OpenCode
Stop-hook wakes and Codex queue attempts have a budget of three until that seat
closes an item. The pre-existing Claude socket path does not spend this budget.
Codex queue submissions never mark packets read and never include packet bodies.
Each attempt gets a `delivery` row in the ledger. Failed or uncertain submissions
leave the packet saved and unread; the CLI reports the result and does not retry.
A post's success means the packet was saved, not that its recipient executed it.

**Claims** are advisory and expire after 4 hours.

Full protocol: [PROTOCOL.md](PROTOCOL.md). Agent runbook:
[skills/handoff/SKILL.md](skills/handoff/SKILL.md).

## Trust

Seat identity is self-asserted; the bus coordinates cooperating agents under
one OS user and is not an authorization boundary. Packets are treated as
hostile input anyway: size caps, control characters stripped, ids checked
before they touch the filesystem. No packet grants a permission, and every
listing says so.
