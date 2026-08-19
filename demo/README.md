# Recording the demo

`record.sh` builds a two-pane tmux session — **left: `codex/schema-impl`** (worker),
**right: `claude/schema-review`** (reviewer) — and types a ~75-second choreography into
both panes at human speed while you record. It runs against a throwaway
`AGENT_BUS_HOME` with inbox sockets stripped, so it never touches your real bus or
pokes a live session.

The story it tells: two different harnesses on one repo. The reviewer takes the
`@review` named role; the worker claims a file and posts a `needs-review` handoff to
`@review`; the reviewer reads it (peer-context banner, touched files, live claim),
replies `done`, and explicitly resolves the thread; `triage` confirms a clean bus.

## Steps

```sh
# terminal A (director)
./demo/record.sh          # builds the session, then waits

# terminal B (the one you record — size it >= 260x45 first)
tmux attach -t agent-bus-demo

# start your recorder on terminal B, then press Enter in terminal A
```

When it finishes, stop the recorder and clean up with the commands the director
prints (`tmux kill-session -t agent-bus-demo`, `rm -rf <demo home>`).

## Recorder options

- **asciinema → GIF**: run `asciinema rec demo.cast` in terminal B *before* attaching,
  attach, record, exit. Convert with [agg](https://github.com/asciinema/agg):
  `agg --font-size 14 demo.cast demo.gif`
- **Screen capture** (CleanShot, QuickTime, Kap): crop to the terminal, export GIF or
  MP4. MP4 embeds fine in the GitHub README via drag-and-drop into an issue/PR body.
- Use a dark theme with good contrast and a Nerd-Font-free monospace (the script uses
  plain ASCII + `→` only), 14–16px.

## Knobs

| Env | Effect |
|---|---|
| `DEMO_SPEED=0` | instant typing, minimal pauses — smoke-testing the script |
| `DEMO_AUTOSTART=1` | skip the press-Enter gate (headless runs) |

A full smoke test: `DEMO_SPEED=0 DEMO_AUTOSTART=1 ./demo/record.sh`, then inspect with
`tmux capture-pane -pt <pane-id>`.
