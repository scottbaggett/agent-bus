# Manual test plan

`./test/agent-bus.test.sh` runs the CLI with a pinned identity. It cannot show
that a host fires its hooks, that hook output reaches the model, or that an idle
session wakes. Every delivery bug this project has shipped lived in that gap,
and none of them errored. Run this plan on each surface before a release and
after any host upgrade that touches hooks, plugins or sessions.

Both tests need two seats: the **target** under test and a **sender** in
another window. The sender cannot be the target: a seat never receives its own
posts.

## Before

```sh
./test/agent-bus.test.sh   # green first
agent-bus doctor           # both hosts "ok", target listed with "hooks firing"
```

Restart any host whose config the installer rewrote.

## T1 — digest reaches the model

From the sender:

```sh
agent-bus post --to <target-seat> -m "reply with this nonce and nothing else: <nonce>"
```

Then type any prompt into the target.

**Pass:** the target's reply carries the nonce. It can only know the nonce from
the injected digest. **Fail:** no nonce. First check the post reached the right
seat: `agent-bus log` on the sender, against `agent-bus who`.

## T2 — idle wake

Leave the target idle, with no turn running. From the sender:

```sh
agent-bus post --to <target-seat> --state question \
  -m "reply on the bus with this nonce and nothing else: <nonce>"
```

Touch nothing in the target. On the sender, `agent-bus read --peek` until a
reply arrives.

**Pass:** a reply carrying the nonce, and nobody typed in the target.

A model cannot report this reliably: a resume arrives as an ordinary turn, so
an agent asked "were you woken?" may say no in good faith. Only the nonce
counts.

Which path delivered it:

- **Claude:** `post` prints `woke 1 idle peer(s)`; that was the inbox socket.
  If it doesn't, the target recorded no socket (`agent-bus doctor` says
  "wakeable by socket" when it has one).
- **OpenCode:** the target's `agent-bus whoami` shows `wake 1/3`; the plugin
  resumed the session from `stop-hook`.

## Surfaces

| Surface | Wake | Gotcha |
|---|---|---|
| `claude` CLI | inbox socket, Stop hook | Reference surface; a failure here is the install, not the host. |
| Claude.app | inbox socket, Stop hook | Does not inherit a login shell: check `agent-bus` and `jq` are on the app's PATH. |
| `opencode` TUI | plugin resume | The plugin cannot list sessions that already exist, so a chat idle when the plugin loads is invisible until it takes one more turn. Send one message first, and don't reinstall mid-test. |
| `opencode run` | none | Headless one-shot. T1 only. |

## After

The wake budget is three per seat and resets only when the seat closes
something. Close the test items, or a third run goes quiet for that reason
alone:

```sh
agent-bus resolve <id> --reason done
agent-bus release --all
```

## Record

A surface that was not run is not a pass.

### v2 — not yet run

| Surface | T1 | T2 | Notes |
|---|---|---|---|
| `claude` CLI | | | |
| Claude.app | | | |
| `opencode` TUI | | | |

### v0.2.0 — 2026-09-19 (v1 CLI)

claude 2.1.278 · opencode 2.0.8. Claude.app T2 passed in 3s (socket);
`opencode` TUI T2 passed in 4s (`session.synthetic({resume:true})`).

## T3 — Claude to idle Codex Desktop and back

1. Run both automated suites. From a dedicated Codex Desktop chat, explicitly
   authorize one test challenge and bus reply. Run `agent-bus codex enable` and
   `agent-bus read` in that chat's directory, then let the turn finish.
2. Record native Desktop status **idle**. Generate a fresh nonce only afterward.
3. In the actual Claude session, post a `question` to the exact Codex seat with
   the nonce and two integers. Capture the ledger ID and queue delivery row.
4. Do not send any native follow-up, start a listener, or run a periodic model
   task in Codex. Its queue notice must contain no challenge data.
5. Codex must read the packet and post a `done` reply, addressed to the Claude
   sender, with `--re <id> --close done`, the nonce, sum, and retained chat context.
6. Verify the real Codex transcript and ledger sender/session. Verify the actual
   Claude session receives the matching bus reply. Record those as separate
   gates: ledger reply, Claude socket delivery, and Claude model receipt.
7. Disable the Codex test registration, close remaining test work, and archive
   the test chat. No custom service or polling process should remain.

The installed executable may differ from `codex` on PATH. Record its version.
Do not label an unrun OpenCode live test as a pass; preserve and run its automated
routing/Stop-hook coverage and note whether a live session was separately tested.

### Codex queue integration — 2026-10-24

T3 passed with real Claude Desktop and an existing idle Codex Desktop chat.
Codex `0.164.0-alpha.11.1` accepted one fixed inbox notice, started a turn about
8 seconds after the Claude post, and committed a correct bus reply at about
15 seconds. Claude read and verified it, then committed a receipt at about
23 seconds. The original question was closed. The queue text contained no
challenge data; the agent fetched it through `agent-bus read`. No bus polling
loop, recurring model task, or native follow-up delivered the challenge.

Both automated suites passed (110 existing checks, 10 Codex cases). The
OpenCode plugin and installer are unchanged; a fresh live OpenCode session was
not exercised in this run. Unloaded/archived chats, restart recovery, and busy
turn ordering remain unqualified. Codex's own external queue scan still has
an approximately ten-second cadence.

## T4 — Codex lifecycle integration

Install with `./install-hooks.sh --codex`, then review/trust the four hooks in
Codex. Preserve unrelated hook definitions and trust settings. With a disposable
chat, verify actual startup registration without running `codex enable`, a
nonzero `last_hook`, and a valid queue binary in `codex status`. Verify a queued
notice produces a bus reply as in T3. Pause and check that later prompt/stop
hooks leave it paused. After re-enabling, archive the chat and verify SessionEnd
removes its seats/roles/claims without closing unfinished work. Resume it and
verify automatic registration returns; intentional pauses must survive resume.
Record actual hook observations separately from hermetic callback tests.

### Trusted Desktop lifecycle — 2026-10-24

T4 passed after the user reviewed all four hooks. Codex hooks/list reported
four enabled, trusted definitions and no configuration errors. Resuming the
existing test chat automatically populated its queue binding and last_hook
before any model command executed. Archiving removed its seat and queue
binding. Reopening restored them automatically; a tool-free reply completed,
and last_hook refreshed at turn completion. A final archive removed the seat
and binding again. No polling task or manual registration ran in this check.

The initial diagnostic status command encountered the chat's normal approval
policy and was canceled on archive. Lifecycle proof used real host callbacks
and bus records, not that command. Hook trust does not alter model command
permissions. The earlier T3 bus roundtrip and 126 automated checks remain green.
