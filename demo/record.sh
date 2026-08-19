#!/usr/bin/env bash
# demo/record.sh — scripted two-pane agent-bus demo, built for recording.
#
# Left pane:  codex/schema-impl   (worker: claims a file, posts a handoff)
# Right pane: claude/schema-review (reviewer: takes @review, reads, resolves)
#
# The director (this script) types into both panes at human speed while you
# record the attached window. Everything runs against a throwaway
# AGENT_BUS_HOME, with inbox sockets stripped, so the demo can never touch
# your real bus or poke a live session.
#
# Usage:
#   ./demo/record.sh            # builds the session, waits for Enter, runs
#   tmux attach -t agent-bus-demo   # <- attach THIS in your recording window
#
# Env knobs:
#   DEMO_SPEED=0      smoke-test mode: instant typing, minimal pauses
#   DEMO_AUTOSTART=1  skip the "press Enter" gate (useful headless/CI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SESSION=agent-bus-demo
SPEED="${DEMO_SPEED:-1}"

command -v tmux >/dev/null 2>&1 || { echo "demo: tmux is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "demo: jq is required" >&2; exit 1; }

DEMO_HOME=$(mktemp -d "${TMPDIR:-/tmp}/agent-bus-demo.XXXXXX")

# Pane targets are resolved to real pane ids after creation — hardcoded
# indexes break under custom base-index/pane-base-index tmux configs.
L=''   # left  — codex worker
R=''   # right — claude reviewer

# Human-ish typing. SPEED=0 pastes instantly for smoke tests.
type_cmd() {
  local pane="$1" cmd="$2" i ch
  if [ "$SPEED" = 0 ]; then
    tmux send-keys -t "$pane" -l "$cmd"
  else
    for ((i = 0; i < ${#cmd}; i++)); do
      ch="${cmd:i:1}"
      tmux send-keys -t "$pane" -l "$ch"
      sleep 0.022
    done
  fi
  tmux send-keys -t "$pane" Enter
}

nap() { if [ "$SPEED" = 0 ]; then sleep 0.4; else sleep "$1"; fi; }

# Wait until the demo ledger holds a msg row, then print the newest id.
last_packet_id() {
  local i id
  for i in $(seq 1 50); do
    id=$(jq -r 'select(.kind=="msg") | .id' "$DEMO_HOME/ledger.jsonl" 2>/dev/null | tail -1)
    [ -n "$id" ] && { printf '%s' "$id"; return 0; }
    sleep 0.2
  done
  echo "demo: no packet appeared in $DEMO_HOME/ledger.jsonl" >&2
  return 1
}

# One bash per pane: pinned seat identity, throwaway bus home, no inbox
# socket (so post-time pokes cannot reach a real Claude session), labeled
# prompt, no rc files so the recording is reproducible on any machine.
pane_shell() { # args: tool worktree session-label ps1
  printf 'env AGENT_BUS_HOME=%q AGENT_BUS_TOOL=%q AGENT_BUS_WT=%q AGENT_BUS_SESSION=%q CLAUDE_CODE_MESSAGING_SOCKET= CLAUDECODE= PATH=%q PS1=%q bash --noprofile --norc' \
    "$DEMO_HOME" "$1" "$2" "$3" "$ROOT/bin:$PATH" "$4"
}

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x 260 -y 45 -c "$ROOT" \
  "$(pane_shell codex schema-impl demo-impl '\[\e[1;33m\]codex · schema-impl\[\e[0m\] $ ')"
tmux split-window -h -t "$SESSION" -c "$ROOT" \
  "$(pane_shell claude schema-review demo-review '\[\e[1;36m\]claude · schema-review\[\e[0m\] $ ')"
L=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n 1p)
R=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n 2p)
[ -n "$L" ] && [ -n "$R" ] || { echo "demo: failed to resolve tmux panes" >&2; exit 1; }
sleep 0.5
# Register both seats off-camera (whoami alone does not touch the registry),
# so the reviewer's `who` shows the full roster from its first beat.
tmux send-keys -t "$L" -l 'agent-bus heartbeat; clear'; tmux send-keys -t "$L" Enter
tmux send-keys -t "$R" -l 'agent-bus heartbeat; clear'; tmux send-keys -t "$R" Enter
sleep 0.6

if [ "${DEMO_AUTOSTART:-0}" != 1 ]; then
  cat <<EOF

Demo session ready (bus home: $DEMO_HOME)

  1. In your RECORDING terminal:   tmux attach -t $SESSION
  2. Start your recorder (asciinema rec / vhs / screen capture)
  3. Press Enter HERE to run the choreography (~75s)

EOF
  read -r
fi

# ---------------------------------------------------------------- the show

# Scene 1 — two harnesses introduce themselves.
type_cmd "$L" '# a Codex session, working the impl worktree'
nap 1.6
type_cmd "$L" 'agent-bus whoami'
nap 2.4

type_cmd "$R" '# a Claude Code session — different harness, same repo'
nap 1.6
type_cmd "$R" 'agent-bus role review'
nap 2.2
type_cmd "$R" 'agent-bus who'
nap 2.8

# Scene 2 — the worker claims a file and hands off for review.
type_cmd "$L" 'agent-bus claim src/SchemaEditorNode.ts'
nap 2.0
type_cmd "$L" 'agent-bus post --to @review --state needs-review --touched src/SchemaEditorNode.ts -m "SchemaEditorNode: cyclic-ref validation ready. 42 tests pass — review before I wire the UI."'
nap 2.6

PKT_ID=$(last_packet_id)

# Scene 3 — the reviewer reads, replies, and explicitly closes the thread.
type_cmd "$R" 'agent-bus read'
nap 4.0
type_cmd "$R" "agent-bus post --re $PKT_ID --to codex/schema-impl --state done -m \"Reviewed: validation is sound. Ship it.\""
nap 2.4
type_cmd "$R" "agent-bus resolve $PKT_ID"
nap 2.0

# Scene 4 — the worker gets the verdict; the bus is clean.
type_cmd "$L" 'agent-bus read'
nap 3.2
type_cmd "$L" 'agent-bus release src/SchemaEditorNode.ts'
nap 1.8
type_cmd "$R" 'agent-bus triage'
nap 2.2

type_cmd "$L" '# no daemon, no server — just bash, jq, and a ledger'
nap 2.5

cat <<EOF

Choreography finished. Stop your recorder, then clean up with:

  tmux kill-session -t $SESSION
  rm -rf $DEMO_HOME

EOF
