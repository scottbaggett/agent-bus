#!/usr/bin/env bash
# agent-bus proof: review requests name their commit and carry checks and
# artifacts recorded against it; readers see stale, dirty or failing proof.
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

unset CODEX_THREAD_ID CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET OPENCODE OPENCODE_SESSION_ID
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE
for _v in $(env | sed -n 's/^\(AGENT_BUS_[A-Z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
export AGENT_BUS_HOME="$T/bus" AGENT_BUS_NO_PUSH=1 AGENT_BUS_NO_AUTO_GC=1 AGENT_BUS_NO_PEERS=1
export AGENT_BUS_POLICY_OWNER=pm AGENT_BUS_POLICY_REVIEW=none
mkdir -p "$AGENT_BUS_HOME"

R="$T/repo"; mkdir -p "$R"
( cd "$R" && git init -q -b feat-x && git config user.email t@t && git config user.name t && echo a >a.txt \
  && git add a.txt && git commit -qm one )
commit() { (cd "$R" && echo "$1" >>a.txt && git commit -qam "$1"); }
sha() { git -C "$R" rev-parse HEAD; }

seat() { local s="$1" t="$2" w="$3"; shift 3; (cd "$R" && AGENT_BUS_SESSION="$s" AGENT_BUS_TOOL="$t" AGENT_BUS_WT="$w" "$BIN" "$@"); }
b() { seat b opencode main "$@"; }
r() { seat r claude rev "$@"; }
idof() { sed -n 's/.*id=//p' | tail -1; }
L="$AGENT_BUS_HOME/ledger.jsonl"
field() { jq -r --arg id "$1" "select(.id == \$id) | $2" "$L"; }
b who >/dev/null; r who >/dev/null
RV=$(r whoami | awk '/^seat/{print $2}')

# --- off by default ---
id=$(b post --to "$RV" --state needs-review -m "# plain review" | idof)
assert_eq "without the rule or --proof a review carries no sha" null "$(field "$id" .sha)"
assert_lacks "and readers see no proof line" "proof" "$(r read)"

# --- recording ---
out=$(b proof run -- sh -c 'echo tests pass; exit 0' 2>&1)
assert_has "proof run shows the command's output" "tests pass" "$out"
assert_has "and records it at HEAD" "exit 0 at $(sha | cut -c1-7)" "$out"
set +e; b proof run -- sh -c 'exit 3' >/dev/null 2>&1; rc=$?; set -e
assert_eq "proof run exits with the command's code" 3 "$rc"
(cd "$R" && echo report >report.html)
b proof add report.html >/dev/null
assert_has "proof show lists checks and files against HEAD" "report.html" "$(b proof show)"

# --- a fresh, passing manifest ---
b proof clear >/dev/null
b proof run -- true >/dev/null 2>&1
b proof add report.html >/dev/null
out=$(b post --to "$RV" --state needs-review --proof auto -m "# please review")
id=$(idof <<<"$out")
assert_has "post says what the reviewer will see" "all made at this commit" "$out"
assert_eq "the request names its commit" "$(sha)" "$(field "$id" .sha)"
assert_eq "and carries the check" "true" "$(field "$id" '.proof.checks[0].cmd')"
assert_has "the reviewer sees fresh proof" "1 check(s) passed, 1 artifact(s), all made at this commit" "$(r read)"

# --- stale: a commit after the checks ---
commit two
out=$(b post --to "$RV" --state needs-review --proof auto -m "# after a fix")
id=$(idof <<<"$out")
old=$(field "$id" '.proof.checks[0].sha' | cut -c1-7)
assert_has "proof older than the commit is flagged" "\`true\` ran at $old, not $(sha | cut -c1-7)" "$(r read)"
assert_has "so is an artifact made before it" "report.html was made at $old" "$(r show "$id")"
assert_has "show marks the entry" "(older commit)" "$(r show "$id")"

# --- failing and dirty ---
b proof run -- sh -c 'exit 1' >/dev/null 2>&1 || true
assert_has "a failing check is recorded" "exit 1" "$(b proof show)"
out=$(b post --to "$RV" --state needs-review --proof auto -m "# failing")
assert_has "a failing check is flagged" "FAILED (exit 1)" "$out"
b proof clear >/dev/null
echo wip >>"$R/a.txt"
b proof run -- true >/dev/null 2>&1
out=$(b post --to "$RV" --state needs-review --proof auto -m "# dirty")
assert_has "a check run on uncommitted changes is flagged" "ran on uncommitted changes" "$out"
assert_has "and so is a request posted with them" "posted with uncommitted changes" "$out"
(cd "$R" && git checkout -q a.txt)

# --- the branch moves after the request ---
b proof clear >/dev/null; b proof run -- true >/dev/null 2>&1
id=$(b post --to "$RV" --state needs-review --proof auto -m "# moving" | idof)
asked=$(sha | cut -c1-7)
commit three
assert_has "a reviewer is told the branch moved since the request" "branch feat-x has moved to $(sha | cut -c1-7) since this request (asked about $asked)" "$(r read)"

# --- team rule ---
b proof clear >/dev/null
out=$(AGENT_BUS_POLICY_PROOF=warn b post --to "$RV" --state needs-review -m "# warn rule" 2>&1)
assert_has "proof=warn names the commit without --proof" "proof: none attached" "$out"
assert_has "and nudges" "agent-bus proof run" "$out"
out=$(AGENT_BUS_POLICY_PROOF=require b post --to "$RV" --state needs-review -m "# require rule" 2>&1 || true)
assert_has "proof=require refuses a review without proof" "team rule proof=require" "$out"
b proof run -- true >/dev/null 2>&1; commit four
out=$(AGENT_BUS_POLICY_PROOF=require b post --to "$RV" --state needs-review -m "# stale under require" 2>&1 || true)
assert_has "and one with stale proof" "team rule proof=require" "$out"
b proof run -- true >/dev/null 2>&1
out=$(AGENT_BUS_POLICY_PROOF=require b post --to "$RV" --state needs-review -m "# fresh under require" 2>&1)
assert_has "fresh passing proof goes through" "posted" "$out"
out=$(AGENT_BUS_POLICY_PROOF=require b post --to "$RV" --state needs-review --proof none -m "# opt out" 2>&1)
assert_has "--proof none skips it" "posted" "$out"
out=$(AGENT_BUS_POLICY_PROOF=require b post --to "$RV" --state fyi -m "# not a review" 2>&1)
assert_lacks "only review requests carry proof" "proof" "$out"
assert_has "proof clear keeps the records" "kept as" "$(b proof clear)"
assert_eq "set aside, not deleted" yes "$(ls "$AGENT_BUS_HOME"/proof/*.cleared.* >/dev/null 2>&1 && echo yes)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
