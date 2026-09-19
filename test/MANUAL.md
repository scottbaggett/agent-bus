# Manual test plan

`./test/agent-bus.test.sh` runs the CLI directly with a pinned identity. It
cannot verify that a host fires its hooks, that hook stdout reaches the model,
or that an idle session can be woken. **Every delivery bug this project has
shipped lived in exactly that gap**, and none of them errored: seats stayed
listed, `agent-bus read` honestly reported nothing unread, and the failure was
found weeks later by a human noticing an agent had gone quiet.

This plan covers the gap. Run it against every surface before tagging a
release, and after any host upgrade that touches hooks, plugins, or sessions.

Two tests. T1 is self-contained. T2 needs a second seat and is the only one
that proves an unprompted wake.

---

## T1 — in-host delivery probe

Proves, from bus state rather than from the model's say-so: hooks fired for
this seat, the seat's hooks and shell resolved to **one** identity, the digest
surfaced a packet, hook output actually reached the model, and the Stop hook
continued the seat at a turn boundary.

Inside the session under test:

```sh
agent-bus init
```

`init` is `watch on` plus `selftest` in one step. Doing them separately is easy
to half-do, and a probe armed with watch off reports the wake check as SKIPPED,
which reads like a pass.

`selftest` arms a probe addressed to this seat and prints no nonce. On the
**next turn** the agent runs the command the probe body tells it to:

```sh
agent-bus selftest check <nonce>
```

The nonce is the load-bearing part. The agent can only know it by having read
an injected digest, so supplying it is proof that hook stdout reached the
model rather than merely landing in a file.

**Pass:** `check` reports identity, hooks, digest, nonce and wake all OK.
**Partial:** wake SKIP means `watch` was off, which `init` prevents.
**Fail:** any FAIL, or the agent never runs `check` on its own, which is
itself a digest-delivery failure.

## T2 — unprompted idle wake

Proves a packet arriving while the session sits idle continues it with **no
human input**. T1 only exercises the turn-boundary path.

A model cannot self-report this. A successful resume arrives as an ordinary
inbound turn, so an agent asked "were you woken?" will often say no in good
faith. The nonce is what discriminates, observed from outside.

1. In the session under test, leave `watch` on from `init`, then stop typing.
   Let it go fully idle.
2. From **another seat** (sender exclusion means the poster cannot be the seat
   under test):

```sh
agent-bus post --to <seat-under-test> --state question \
  -m "reply with this nonce and nothing else: <nonce>"
```

3. Touch nothing. Watch from outside:

```sh
agent-bus read --peek                                  # did a reply arrive?
jq -c '{wake_count,last_wake}' ~/.agents/bus/state/<seat-slug>.json
```

**Pass:** a reply carrying the nonce, and no human typed. That is the whole
test; the counters below only say *which* path delivered it.

`wake_count` moves on the Stop-hook path and not on the socket poke, so the
two surfaces read differently:

- **Claude**: `post` prints `pushed wake to 1 peer(s)` and `wake_count` stays
  put. The poke woke it at post time, before any hook was involved.
- **OpenCode**: `wake_count` increments and `last_wake` matches the second the
  packet was posted, because the plugin asked `stop-hook` whether to resume.

**Fail:** no reply after a minute on a surface where T2 applies. On Claude
also check that the seat records a socket, since a seat with none silently
degrades to the pull digest.

---

## Surfaces

Run T1 on every row. **T2 applies to two surfaces only.** Waking a session
that is already idle needs a channel into a host with no turn running, and
only Claude Code and OpenCode have one: an inbox socket poked at post time,
and a synthetic message that resumes the session. Everywhere else the Stop
hook fires at the end of a turn that is already running, so an idle session
has no hook to fire and the packet waits for the next prompt. That is not a
bug and T1 already covers it.

| Surface | Wake mechanism | Known risk |
|---|---|---|
| `claude` CLI | Stop hook, plus inbox-socket poke | T2 applies. Reference surface: if this fails, suspect the install, not the host. |
| Claude.app | Stop hook, plus inbox-socket poke | T2 applies. Launch env differs from a login shell; check PATH reaches `agent-bus`. |
| `codex` CLI | Stop hook, turn boundary only | **T2 does not apply.** No socket, no resume: a Codex session idle at an empty prompt cannot be woken. Use `agent-bus wait`. |
| Codex in ChatGPT.app | Stop hook, turn boundary only | T2 does not apply, same as the CLI. |
| `cursor-agent` CLI | `followup_message`, turn boundary only | T2 does not apply. Separate binary from the app; both use the same adapter. |
| Cursor.app | `followup_message`, turn boundary only | T2 does not apply. Hooks run from `~/.cursor`, not the workspace. See gotchas. |
| `opencode` TUI | `session.synthetic({resume:true})` | T2 applies. Session must take one turn after plugin load. See gotchas. |
| `opencode run` | none | Headless, one-shot. T1 only, and expect no `session.created`. |

## Per-surface gotchas

These are failure modes already paid for. Each one produced a false negative.

**All surfaces.** `WAKE_BUDGET` is three per seat and resets only on
`agent-bus resolve` or `agent-bus watch reset`, never on `read`. A third
consecutive test run goes quiet for that reason alone. Reset between runs.

**Cursor, both surfaces.** `hooks.json` is read at launch, so restart or
reload the window after `./install-hooks.sh`. If the workspace root is a
nested git repo inside a worktree, hooks anchor to the nested repo while the
shell anchors to the worktree, and the two disagree about identity. Not
fixable from the bus; use a workspace root that is the worktree root.

**Codex, both surfaces.** New hook commands are untrusted; Codex asks for
approval on next launch. Until approved, nothing fires and the seat looks
merely quiet.

**OpenCode.** The plugin cannot enumerate existing sessions, so a chat sitting
idle when the plugin loads is invisible until it takes one more turn. Send one
message before starting T2. Do **not** reinstall the plugin mid-test: the hot
reload wipes session tracking and the chat goes invisible again, which reads
as a broken wake.

**Desktop apps generally.** They do not inherit a login shell. If `agent-bus`
or `jq` is missing from the app's PATH, hooks fail silently.

---

## Procedure

**Before.** Confirm the installs match the current installer, then start from
a known state:

```sh
./test/agent-bus.test.sh     # green first; a red suite makes T1/T2 unreadable
./install-hooks.sh           # only if doctor says STALE
agent-bus doctor             # hook install per host, seats, wake budgets
```

`doctor` naming a host `STALE` or `not installed` is a fail before any session
is opened. Restart any host whose config was rewritten.

**During.** One surface at a time. Do not reinstall hooks or plugins while a
test is in flight.

**After, per surface.**

```sh
agent-bus watch off
agent-bus resolve <probe-id>     # also resets the wake budget
agent-bus release --all
```

## Record

Keep the result with the release. A surface that was not run is not a pass.

### v0.2.0 — 2026-09-19

claude 2.1.278 · codex 0.154.0 · Cursor 3.21.13 · cursor-agent 2026.09.15 · opencode 2.0.8

| Surface | T1 | T2 | Notes |
|---|---|---|---|
| `claude` CLI | pass | — | Observed across a working session, not probed. |
| Claude.app | pass 5/5 | **pass, 3s** | Socket poke; `wake_count` stays 0 by design. |
| `codex` CLI | pass 5/5 | n/a | Turn-boundary wake only. |
| Codex in ChatGPT.app | pass 5/5 | n/a | Turn-boundary wake only. |
| `cursor-agent` CLI | pass 5/5 | n/a | 2026.09.15-d2fe57e. Turn-boundary wake only. |
| Cursor.app | pass 5/5 | n/a | Cursor 3.21.13. Turn-boundary wake only. |
| `opencode` TUI | — | **pass, 4s** | `session.synthetic({resume:true})`, 2.0.8. |
| `opencode run` | — | n/a | Headless one-shot, not run. |

Both idle-wake paths are proven: the inbox socket on Claude, the synthetic
resume on OpenCode. Every other surface is turn-boundary only, which T1 covers.

Codex exports only `CODEX_SHELL` from both its CLI and the ChatGPT app, and
Cursor's two surfaces share one adapter. Both pairs were run separately anyway,
and each pair agreed.

`agent-bus init` run from a plain terminal rather than inside a harness arms a
probe on a markerless `shell/<worktree>` seat that no hook will ever touch, so
the check can never pass. `identity_report` warns but `init` proceeds, and the
probe is left unresolvable by anyone but that seat. Arm only from inside the
session under test.

## When this plan is not enough

T1 and T2 are point-in-time. They say nothing about a host that upgrades next
week and silently drops a hook. Two standing checks cover that between
releases:

- `agent-bus doctor` compares each host's installed hook lines against what
  the current installer emits and flags drift.
- A seat with `watch` on, `wake_pending` above zero, and a `last_wake` that
  has not advanced has a dead wake path. That is the signature of every bug
  this plan exists to catch, and it is visible from bus state alone.
