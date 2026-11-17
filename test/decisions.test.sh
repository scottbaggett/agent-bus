#!/usr/bin/env bash
# Standing decisions: the user's confirmed calls, recorded by the lead, read by
# every seat in every repo at start and after every reset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agent-bus"
pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "  want: $2
  got:  $3"; fi; }
assert_has() { if grep -Fq -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "  missing: $2
  in: $3"; fi; }
assert_lacks() { if grep -Fq -- "$2" <<<"$3"; then bad "$1" "  unexpected: $2"; else ok "$1"; fi; }
unset CODEX_THREAD_ID CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET OPENCODE OPENCODE_SESSION_ID HC_TERMINAL_ID
for _v in $(env | sed -n 's/^\(AGENT_BUS_[A-Z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
T=$(mktemp -d); T=$(cd "$T" && pwd -P); trap 'rm -rf "$T"' EXIT
export AGENT_BUS_HOME="$T/bus" AGENT_BUS_NO_PUSH=1 AGENT_BUS_NO_AUTO_GC=1 AGENT_BUS_NO_PEERS=1 AGENT_BUS_BRANCH=develop
mkdir -p "$AGENT_BUS_HOME"
mk() { mkdir -p "$1" && (cd "$1" && git init -q && git commit -q --allow-empty -m init); }
mk "$T/a"; mk "$T/b"
in_a() { local s="$1"; shift; (cd "$T/a" && AGENT_BUS_SESSION="$s" AGENT_BUS_TOOL=claude AGENT_BUS_WT=main "$BIN" "$@"); }
in_b() { local s="$1"; shift; (cd "$T/b" && AGENT_BUS_SESSION="$s" AGENT_BUS_TOOL=opencode AGENT_BUS_WT=main "$BIN" "$@"); }
LEAD=$(in_a lead whoami | awk '/^seat/{print $2}')
export AGENT_BUS_WATCH_LEAD="$LEAD"

out=$(in_a worker decide --global --confirmed "Scott, 9pm" "Agents may write Dev secrets" 2>&1 || true)
assert_has "a worker cannot record a standing decision" "only the lead" "$out"
out=$(in_a lead decide --global "Agents may write Dev secrets" 2>&1 || true)
assert_has "a standing decision says where the user confirmed it" "--confirmed" "$out"
out=$(in_a lead decide --global --confirmed "Scott, ask panel, 9:14 PM" "Agents may write Dev secrets" -m "He said so twice")
d1=$(sed -n 's/.*; \(2[0-9T]*Z-[0-9a-f]*\)).*/\1/p' <<<"$out" | head -1)
assert_has "the lead records it" "standing decision: Agents may write Dev secrets" "$out"
out=$(AGENT_BUS_VIA=hook in_b fresh digest </dev/null)
assert_has "a new seat in another repo reads it at start" "Agents may write Dev secrets (confirmed: Scott, ask panel, 9:14 PM" "$out"
assert_has "stated to outrank what it remembers" "replace anything you remember" "$out"
out=$(AGENT_BUS_VIA=hook in_b fresh digest </dev/null)
assert_lacks "not repeated on every prompt" "standing decisions" "$out"
out=$(printf '{"hook_event_name":"SessionStart","source":"compact"}' | AGENT_BUS_VIA=hook in_b fresh digest)
assert_has "after a compaction it is read again" "Agents may write Dev secrets" "$out"
out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}' | AGENT_BUS_VIA=hook in_b fresh digest)
assert_lacks "a plain prompt does not re-orient" "standing decisions" "$out"
assert_has "decisions --global lists it" "standing  Agents may write Dev secrets" "$(in_b fresh decisions --global)"
assert_has "and shows who confirmed it" "confirmed: Scott, ask panel, 9:14 PM" "$(in_a worker decisions)"
out=$(in_a lead decide --global --confirmed "Scott, 9:30 PM" --supersedes "$d1" "Agents may write Dev secrets, never Prod")
assert_lacks "a superseded decision is gone" "  - Agents may write Dev secrets (" "$(AGENT_BUS_VIA=hook in_b other digest </dev/null)"
assert_has "and its replacement stands" "never Prod" "$(AGENT_BUS_VIA=hook in_b other2 digest </dev/null)"
d2=$(sed -n 's/.*; \(2[0-9T]*Z-[0-9a-f]*\)).*/\1/p' <<<"$out" | head -1)
assert_has "retracting needs a reason" "needs -m why" "$(in_a lead decide --retract "$d2" 2>&1 || true)"
in_a lead decide --retract "$d2" -m "Scott withdrew it" >/dev/null
assert_lacks "a retracted decision is gone" "never Prod" "$(in_b fresh decisions --global)"
in_a worker decide "Use pnpm here" --repo-wide >/dev/null
assert_lacks "repo decisions stay in their repo" "Use pnpm" "$(in_b fresh decisions)"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
