#!/usr/bin/env bash
# End-to-end check with the real agent CLIs, headless, on a throwaway bus.
#
# Each scenario posts work the way an agent would, starts a real Claude Code,
# OpenCode or Codex session in a scratch repo, and checks the ledger for the
# answer. Hooks, the OpenCode plugin and the skill come from the installed
# agent-bus, so install the version under test first (brew upgrade, or
# ./install.sh --from .). Your live bus is never touched: everything runs
# under a temporary AGENT_BUS_HOME.
#
# Usage: test/e2e.sh [claude] [opencode] [codex]   (default: all three)
# Costs one short headless model run per scenario (four in all).
# Desktop-app behavior (idle Claude wake, Codex Desktop queue, OpenCode TUI)
# is manual: test/MANUAL.md.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WANT="${*:-claude opencode codex}"
LIMIT="${E2E_TIMEOUT:-240}"
# OpenCode's default model may not support tools; use one that does.
OC_MODEL="${E2E_OPENCODE_MODEL:-openai/gpt-6.1-sol}"
export AGENT_BUS_OPENCODE_MODEL="$OC_MODEL"
PROMPT='Do whatever work agent-bus has waiting for you, then stop. Keep it short.'
pass=0 fail=0 skip=0

ok()   { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
note() { printf 'SKIP  %s — %s\n' "$1" "$2"; skip=$((skip + 1)); }
want() { case " $WANT " in *" $1 "*) return 0 ;; esac; return 1; }

# The agents run the installed CLI, so it must be the version under test.
want_v=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$ROOT/bin/agent-bus")
have_v=$(agent-bus version 2>/dev/null | awk 'NR==1{print $2}')
if [ "$have_v" != "$want_v" ]; then
  printf 'installed agent-bus is %s, this checkout is %s. Install it first:\n  brew upgrade agent-bus   or   ./install.sh --from %s\n' \
    "${have_v:-none}" "$want_v" "$ROOT" >&2
  exit 1
fi

export AGENT_BUS_HOME; AGENT_BUS_HOME=$(mktemp -d)
REPO=$(mktemp -d)/e2e-repo
mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" commit -q --allow-empty -m init
LEDGER="$AGENT_BUS_HOME/ledger.jsonl"
# A team repo has its rules committed; the run checks agents under set rules.
printf 'bus %s\nrepo %s\n\n' "$AGENT_BUS_HOME" "$REPO"

# Child agents must not inherit this session's identity.
clean_env=(env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET
           -u CODEX_THREAD_ID -u OPENCODE -u OPENCODE_SESSION_ID -u AGENT_BUS_TOOL
           -u AGENT_BUS_SESSION -u AGENT_BUS_WT -u AGENT_BUS_NO_PUSH "AGENT_BUS_HOME=$AGENT_BUS_HOME")
# The test itself posts as a plain shell seat, like a person or a script would.
# The posting side runs this checkout, so delivery and --resume are the code
# under test; the agents' hooks run the installed copy.
BIN="$ROOT/bin/agent-bus"
lead() { (cd "$REPO" && AGENT_BUS_TOOL=shell AGENT_BUS_SESSION=e2e "$BIN" "$@"); }
lead init --set owner=refuse,review=requester,ask_lead=scope,destructive,decisions=on >/dev/null
git -C "$REPO" add .agent-bus.json && git -C "$REPO" commit -q -m rules
# Run a command for at most LIMIT seconds.
run_for() { perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$@"; }

# A reply to packet $1 from a seat of tool $2 whose body holds $3.
replied() {
  local r
  r=$(jq -r --arg id "$1" --arg t "$2/" 'select(.kind == "msg" and .re == $id and (.from | startswith($t))) | .id' "$LEDGER" | tail -1)
  [ -n "$r" ] && grep -q "$3" "$AGENT_BUS_HOME/msg/$r.md" 2>/dev/null
}
closed() { jq -e --arg id "$1" 'select((.kind == "msg" and .re == $id and .close != null) or (.kind == "resolve" and .msg == $id))' "$LEDGER" >/dev/null; }
id_of() { sed -n 's/.*id=\([^ ]*\).*/\1/p' | head -1; }

# A handoff to a tool's scope, a headless session of that tool, then the checks.
round() { # tool token command...
  local tool="$1" token="$2" out id; shift 2
  out=$(lead post --to "$tool/main" --state handoff -m "# e2e: reply with the word $token

Close this item with: agent-bus reply <id> -m \"$token\"" 2>&1)
  id=$(id_of <<<"$out")
  case "$out" in *"$tool/main is not running"*) ok "$tool: post says a seat that isn't running yet will wait" ;;
                 *) bad "$tool: delivery line for a seat not yet running" "$out" ;; esac
  # stdin closed: opencode run and codex exec read a prompt from a non-tty stdin.
  (cd "$REPO" && run_for "${clean_env[@]}" "$@") </dev/null >"$AGENT_BUS_HOME/$tool.log" 2>&1
  if replied "$id" "$tool" "$token"; then ok "$tool: picked up the handoff and replied"
  else bad "$tool: no reply with $token" "see $AGENT_BUS_HOME/$tool.log"; fi
  if closed "$id"; then ok "$tool: the item was closed"; else bad "$tool: item still open" "$id"; fi
}

if want claude; then
  if command -v claude >/dev/null; then
    round claude MANGO claude -p "$PROMPT" --allowedTools 'Bash(agent-bus:*)' 'Bash(agent-bus *)'
  else note claude "claude not on PATH"; fi
fi

if want opencode; then
  if command -v opencode >/dev/null; then
    round opencode PAPAYA opencode run -m "$OC_MODEL" "$PROMPT"
    # The session has exited: post says so, and --resume restarts it for ask.
    oc=$(jq -rs 'map(select(.tool == "opencode")) | sort_by(-.epoch) | first | .addr // empty' "$AGENT_BUS_HOME"/seats/*.json 2>/dev/null)
    if [ -z "$oc" ]; then bad "opencode: no seat registered" "the plugin never ran agent-bus"
    else
      out=$(lead post --to "$oc" -m '# e2e: just checking delivery' 2>&1)
      case "$out" in *"$oc — not running"*|*"if it has exited, post --resume"*) ok "opencode: post points at --resume for an exited session" ;;
                     *) bad "opencode: delivery line for an exited session" "$out" ;; esac
      out=$(cd "$REPO" && run_for "${clean_env[@]}" AGENT_BUS_TOOL=shell AGENT_BUS_SESSION=e2e \
              "$BIN" ask --to "$oc" --resume --timeout $((LIMIT - 10)) \
              -m "# e2e: what is 6 times 7? Answer with agent-bus reply <id> -m \"<number>\"" </dev/null 2>&1)
      case "$out" in *"restarted its session to pick this up"*) ok "opencode: --resume restarted the session" ;;
                     *) bad "opencode: --resume" "$out" ;; esac
      case "$out" in *"answer from opencode/"*42*) ok "opencode: ask got the answer back" ;;
                     *) bad "opencode: ask" "$out" ;; esac
    fi
  else note opencode "opencode not on PATH"; fi
fi

if want codex; then
  if command -v codex >/dev/null; then
    round codex GUAVA codex exec --sandbox workspace-write --add-dir "$AGENT_BUS_HOME" "$PROMPT"
  else note codex "codex not on PATH"; fi
fi

printf '\n%d passed, %d failed, %d skipped  (logs and bus: %s)\n' "$pass" "$fail" "$skip" "$AGENT_BUS_HOME"
((fail == 0))
