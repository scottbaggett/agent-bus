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
