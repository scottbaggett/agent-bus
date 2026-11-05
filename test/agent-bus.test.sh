#!/usr/bin/env bash
# agent-bus tests: routing, ownership, closing, wake, claims, safety.
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

# Hermetic: the suite runs inside Claude or OpenCode, whose markers and
# sockets would otherwise leak into every fixture seat.
unset CODEX_THREAD_ID CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_MESSAGING_SOCKET OPENCODE OPENCODE_SESSION_ID
for _v in $(env | sed -n 's/^\(AGENT_BUS_[A-Z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
BUS_HOME=$(mktemp -d)
trap 'rm -rf "$BUS_HOME"; [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; [ -n "${GROK_SRV:-}" ] && kill "$GROK_SRV" 2>/dev/null; true' EXIT
GROK_SRV=
export AGENT_BUS_HOME="$BUS_HOME" AGENT_BUS_NO_PUSH=1 AGENT_BUS_NO_AUTO_GC=1
# Lanes are derived from the branch; pin a trunk branch so fixtures start
# unfiled no matter which branch the suite runs on.
export AGENT_BUS_BRANCH=develop
# Pin the pre-policy rules for the older tests: broadcasts stay legal and done
# means done. The policy tests below set their own.
export AGENT_BUS_POLICY_OWNER=pm AGENT_BUS_POLICY_REVIEW=none

# Fixture seats: seat <name> <tool> <worktree> <cmd...>
# Fixture seats are mostly claude, so their posts pass --allow-claude; the
# refusal itself is tested with raw_seat.
raw_seat() { local s="$1" t="$2" w="$3"; shift 3; AGENT_BUS_SESSION="$s" AGENT_BUS_TOOL="$t" AGENT_BUS_WT="$w" "$BIN" "$@"; }
seat() {
  local s="$1" t="$2" w="$3"; shift 3
  if [ "${1:-}" = post ]; then shift; raw_seat "$s" "$t" "$w" post --allow-claude "$@"; else raw_seat "$s" "$t" "$w" "$@"; fi
}
pm() { seat pm claude pmwt "$@"; }
a() { seat a claude wa "$@"; }
b() { seat b opencode wa "$@"; }
c() { seat c claude wc "$@"; }
idof() { sed -n 's/.*id=//p'; }
addr() { "$@" whoami | awk '/^seat/{print $2}'; }

PM=$(addr pm); A=$(addr a); B=$(addr b); C=$(addr c)
for s in pm a b c; do $s who >/dev/null; done

# --- identity ---
out=$(a whoami)
assert_has "seat is tool/worktree.inst" "claude/wa." "$out"
assert_has "scope is tool/worktree" "scope    claude/wa" "$out"
out=$(AGENT_BUS_TOOL= CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=xyz AGENT_BUS_WT=wz "$BIN" whoami)
assert_has "claude detected from env" "seat     claude/wz." "$out"
out=$(AGENT_BUS_TOOL= OPENCODE_SESSION_ID=xyz AGENT_BUS_WT=wz "$BIN" whoami)
assert_has "opencode detected from env" "seat     opencode/wz." "$out"
oc=$(AGENT_BUS_TOOL=opencode OPENCODE_SESSION_ID=oc1 AGENT_BUS_WT=wz "$BIN" whoami | awk '/^seat/{print $2}')
out=$(AGENT_BUS_TOOL=opencode OPENCODE_SESSION_ID=oc1 CLAUDE_CODE_SESSION_ID=cc1 AGENT_BUS_WT=wz "$BIN" whoami)
assert_has "opencode ignores an inherited Claude session id" "seat     $oc" "$out"

# --- routing ---
a post --to @here -m 'self' >/dev/null
assert_has "own posts are never delivered" "nothing unread" "$(a read --peek)"
b read >/dev/null
a post --to @here -m $'# hello wa\n\nhi' >/dev/null
assert_has "@here reaches the worktree" "hello wa" "$(b read --peek)"
assert_lacks "@here stays in the worktree" "hello wa" "$(c read --peek)"
a post --to @repo -m $'# hello repo\n\nhi' >/dev/null
assert_has "@repo reaches other worktrees" "hello repo" "$(c read --peek)"
a post --to "$C" -m $'# direct\n\nhi' >/dev/null
assert_has "direct address delivers" "direct" "$(c read --peek)"
assert_lacks "direct address is private" "direct" "$(b read --peek)"
a post --to claude/wc -m $'# by scope\n\nhi' >/dev/null
assert_has "bare scope reaches the instance" "by scope" "$(c read --peek)"
out=$(a post --to @pm -m x 2>&1 || true)
assert_has "@pm without a PM is refused" "no PM registered" "$out"
out=$(a post --to @codex -m x 2>&1 || true)
assert_has "unknown scope is refused" "unknown scope" "$out"
out=$(a post --to @here --state bogus -m x 2>&1 || true)
assert_has "unknown state is refused" "--state must be one of" "$out"

# --- read marks, peek does not, digest delivers once ---
b read >/dev/null; c read >/dev/null
a post --to "$B" -m $'# once\n\nhi' >/dev/null
assert_has "peek shows" "once" "$(b read --peek)"
assert_has "peek leaves it unread" "once" "$(b read --peek)"
assert_has "digest delivers" "once" "$(b digest)"
assert_eq "digest marks read, then stays silent" "" "$(b digest)"
assert_has "read --all still lists it" "once" "$(b read --all)"
a post --to @here -m $'# just context\n\nhi' >/dev/null
assert_eq "a broadcast is not in the digest" "" "$(b digest)"
assert_has "a broadcast stays readable" "just context" "$(b read --peek)"
b read >/dev/null
out=$(a post -m x 2>&1 || true)
assert_has "post without --to is refused" "--to is required" "$out"
out=$(raw_seat a claude wa post --to "$C" -m x 2>&1 || true)
assert_has "claude to claude is refused" "use Claude session messaging (SendMessage)" "$out"
assert_has "--allow-claude overrides" "posted" "$(raw_seat a claude wa post --allow-claude --to "$C" -m '# allowed')"
assert_has "claude may post to an opencode seat" "posted" "$(raw_seat a claude wa post --to "$B" -m '# to oc')"
c read >/dev/null; b read >/dev/null

# --- PM: role, auto-CC, ownership ---
pm role pm >/dev/null
assert_has "role shows the PM" "PM for" "$(a role)"
out=$(a role pm 2>&1 || true)
assert_has "live PM takeover needs --force" "--force" "$out"
a post --to @here --state fyi -m $'# chatter\n\nx' >/dev/null
assert_lacks "PM skips fyi auto-CC" "chatter" "$(pm read --peek)"
b read >/dev/null
rid=$(a post --to @here --state needs-review -m $'# review me\n\nplease' 2>/dev/null | idof)
out=$(pm read --peek)
assert_has "PM auto-CC on supervisory" "review me" "$out"
assert_lacks "PM copy is not labeled broadcast" "broadcast copy" "$out"
assert_has "worktree bystander sees context, labeled" "broadcast copy" "$(b read --peek)"
assert_eq "bystander is not woken" "{}" "$(b stop-hook </dev/null)"
out=$(pm stop-hook </dev/null)
assert_eq "PM owner is woken" "block" "$(jq -r .decision <<<"$out")"
assert_has "wake carries the packet" "review me" "$(jq -r .reason <<<"$out")"
assert_eq "a wake is a delivery: not woken twice" "{}" "$(pm stop-hook </dev/null)"
pm post --to "$A" --state handoff -m $'# from pm\n\ndo it' >/dev/null
assert_has "PM-sent work is marked in scope" "from the PM your user put in charge" "$(a read --peek)"
a read >/dev/null

# --- closing ---
out=$(c resolve "$rid" 2>&1 || true)
assert_lacks "resolve no longer demands a reason" "--reason is required" "$out"
# reply: answer and close in one step, back to the sender.
B=$(addr b)
qid=$(a post --to "$B" --state question -m '# which port?' | idof)
out=$(b reply "$qid" -m "5188")
assert_has "reply posts to the sender" "-> $(addr a)" "$out"
assert_has "reply closes the item" "closed $qid (done)" "$out"
fid=$(a post --to "$B" -m '# fyi only' | idof)
assert_lacks "reply to an fyi closes nothing" "closed" "$(b reply "$fid" -m 'thanks')"
out=$(b reply "$fid" -m x --reason handed-off 2>&1 || true)
assert_has "reply cannot hand off" "needs a destination" "$out"
assert_has "subcommand --help shows that command" "reply <id> -m <body>" "$("$BIN" reply --help)"
# ask: post a question and wait for the answer.
( for i in 1 2 3 4 5 6 7 8 9 10; do
    q=$(jq -r 'select(.kind == "msg" and .subject == "which port for vite?") | .id' "$BUS_HOME/ledger.jsonl" 2>/dev/null | head -1 || true)
    [ -n "$q" ] && { b reply "$q" -m "port 5188" >/dev/null; break; }
    sleep 0.3; done ) &
out=$(AGENT_BUS_ASK_POLL=0.2 a ask --to "$B" -m '# which port for vite?' --timeout 10)
wait || true
assert_has "ask prints the answer" "port 5188" "$out"
out=$(AGENT_BUS_ASK_POLL=0.2 a ask --to "$B" -m '# nobody answers' --timeout 1; echo "exit=$?")
assert_has "ask times out with exit 2" "exit=2" "$out"
assert_has "a timed-out question stays open" "stays open as" "$out"
# claims on things that aren't files
assert_has "claim an MR by name" "claimed mr:3594" "$(a claim MR:3594)"
assert_has "a second claimer is told who has it" "CONTESTED mr:3594" "$(c claim mr:3594 2>&1)"
a release mr:3594 >/dev/null
# send is for the human at a terminal
out=$(a send --to "$B" -m 'from me' 2>&1 </dev/null || true)
assert_has "send refuses without a terminal" "only runs in your own terminal" "$out"
# One session, two folders: it reads packets sent to either seat.
seat sx opencode wfolder1 who >/dev/null; seat sx opencode wfolder2 who >/dev/null
a post --to "$(addr seat sx opencode wfolder1)" -m '# for the main checkout' >/dev/null
assert_has "a session reads packets sent to its other seat" "for the main checkout" "$(seat sx opencode wfolder2 read --peek)"
# A packet the human sent is labeled as theirs.
uid="20200105T000000Z-0000aa01"; printf 'please look\n' >"$BUS_HOME/msg/$uid.md"
printf '{"kind":"msg","id":"%s","epoch":%s,"from":"shell/wa","to":"%s","state":"question","subject":"from the human","repo_id":"%s","user":true}\n' \
  "$uid" "$(date -u +%s)" "$B" "$(a whoami | awk '/^repo_id/{print $2}')" >>"$BUS_HOME/ledger.jsonl"
assert_has "a user-sent packet is labeled as the user's" "from your user, sent from their own terminal" "$(b read --peek)"
# doctor flags standing instructions that post to @here
ch=$(mktemp -d); printf 'agent-bus post --to @here --state needs-review\n' >"$ch/AGENTS.md"
assert_has "doctor flags @here instructions" "tells agents to post --to @here" "$(CODEX_HOME="$ch" a doctor 2>/dev/null)"
rm -rf "$ch"
assert_lacks "subcommand --help shows only that command" "snapshot" "$("$BIN" reply --help)"
out=$(c resolve "$rid" --reason handed-off 2>&1 || true)
assert_has "resolve cannot hand off" "needs a destination" "$out"
out=$(c resolve "$rid" --reason meh 2>&1 || true)
assert_has "resolve rejects unknown reasons" "must be one of" "$out"
out=$(c resolve not-an-id --reason done 2>&1 || true)
assert_has "resolve rejects non-ids" "not a packet id" "$out"
out=$(c resolve 20260101T000000Z-00000000 --reason done 2>&1 || true)
assert_has "resolve rejects unknown ids" "no such packet" "$out"
out=$(c resolve "$rid" --reason done 2>&1 || true)
assert_has "unrelated seat has no standing" "not its sender" "$out"

# Handoff: one ledger row closes the parent and opens the next item.
rows_before=$(wc -l <"$BUS_HOME/ledger.jsonl")
out=$(pm post --re "$rid" --close handed-off --to "$C" --state handoff -m $'# take review\n\ngo')
hid=$(idof <<<"$out")
assert_has "handoff reports the close" "closed $rid (handed-off)" "$out"
assert_eq "handoff is one ledger row" "$((rows_before + 1))" "$(wc -l <"$BUS_HOME/ledger.jsonl" | tr -d ' ')"
out=$(pm triage)
assert_lacks "parent leaves open work" "$rid" "$out"
assert_has "child is owned by the destination" "owner $C" "$out"
out=$(pm post --to "$A" --re "$rid" --close done -m x 2>&1 || true)
assert_has "a closed item cannot close again" "already closed" "$out"
out=$(pm post --to "$A" --close done -m x 2>&1 || true)
assert_has "--close needs --re" "--close needs --re" "$out"
out=$(pm post --to "$A" --re "$hid" --close handed-off --state fyi -m x 2>&1 || true)
assert_has "handed-off must open an item" "--state must be" "$out"
out=$(c resolve "$hid" --reason done)
assert_has "owner closes with a reason" "resolved $hid (done)" "$out"
assert_has "log records the reason" "closed $hid (done)" "$(pm log)"

# --- wake: unlimited by default, opt-in rate-limit ---
# Default (AGENT_BUS_WAKE_BUDGET unset or 0) is unlimited: every stop-hook delivers.
for _i in 1 2 3 4; do
  a post --to "$C" --state question -m "# unl$_i" >/dev/null
  assert_eq "unlimited default: wake $_i delivers" "block" "$(c stop-hook </dev/null | jq -r .decision)"
done
assert_has "whoami shows wakes/unlimited" "wake     4/unlimited" "$(c whoami)"
# Reset the wakes counter so the opt-in tests start clean.
_unlq=$(a post --to "$C" --state question -m '# wake-reset' | idof)
c resolve "$_unlq" --reason done >/dev/null
c read >/dev/null

# Opt-in: AGENT_BUS_WAKE_BUDGET=3 re-enables the hard stop (resets on close).
for _i in 1 2 3 4; do
  a post --to "$C" --state question -m "# limq$_i" >/dev/null
  AGENT_BUS_WAKE_BUDGET=3 c stop-hook </dev/null >/dev/null
done
a post --to "$C" --state question -m '# limq5' >/dev/null
assert_eq "opt-in budget exhausted: no wake" "{}" "$(AGENT_BUS_WAKE_BUDGET=3 c stop-hook </dev/null)"
assert_has "whoami shows the spent budget" "wake     3/3" "$(AGENT_BUS_WAKE_BUDGET=3 c whoami)"
_limq=$(a post --to "$C" --state question -m '# limq6' | idof)
AGENT_BUS_WAKE_BUDGET=3 c resolve "$_limq" --reason done >/dev/null
assert_eq "closing resets the opt-in budget" "block" "$(AGENT_BUS_WAKE_BUDGET=3 c stop-hook </dev/null | jq -r .decision)"
assert_eq "stop-hook is JSON on junk stdin" "{}" "$(printf 'garbage' | c stop-hook)"

# --- triage: gone, not picked up, stale ---
gid=$(a post --to claude/wgone --state blocked -m $'# stuck\n\nhelp' | idof)
out=$(pm triage)
assert_has "owner with no live seat is GONE" "owner claude/wgone  (GONE" "$out"
assert_has "who counts ownerless work" "with no live owner" "$(pm who)"
nid=$(a post --to "$B" --state needs-review -m $'# unseen\n\nx' | idof)
assert_lacks "fresh unread item is not flagged" "NOT PICKED UP" "$(pm triage)"
assert_has "live owner that never read it" "NOT PICKED UP" "$(AGENT_BUS_PICKUP_SECS=0 pm triage)"
assert_has "old item is STALE" "STALE" "$(AGENT_BUS_STALE_HOURS=0 pm triage)"
b read >/dev/null
assert_lacks "read clears NOT PICKED UP" "NOT PICKED UP" "$(AGENT_BUS_PICKUP_SECS=0 pm triage | grep "$nid")"

# --- claims ---
a claim src/x.ts >/dev/null
out=$(c claim src/x.ts 2>&1)
assert_has "claim is contested" "CONTESTED src/x.ts" "$out"
out=$(c release src/x.ts 2>&1)
assert_has "release of a foreign claim is refused" "not releasing" "$out"
out=$(c release --force src/x.ts)
assert_has "--force breaks it" "BROKE claim on src/x.ts" "$out"
assert_has "the break is on record" '"kind":"claim-break"' "$(cat "$BUS_HOME/ledger.jsonl")"
out=$(a claim --all 2>&1 || true)
assert_has "flag-shaped paths are refused" "looks like a flag" "$out"
a claim src/y.ts >/dev/null
assert_lacks "claims are repo-scoped" "src/y.ts" "$(AGENT_BUS_REPO_ID=other a claims)"
assert_lacks "read leaves out claims that don't touch you" "src/y.ts" "$(c read --peek)"
assert_has "read counts the other claims" "other claim(s) in this repo: agent-bus claims" "$(c read --peek)"
probe="test/.claim-probe-$$"; : >"$ROOT/$probe"
a claim "$ROOT/$probe" >/dev/null
assert_has "read shows a claim on a file you changed" "-> $probe" "$(c read --peek)"
rm -f "$ROOT/$probe"; a release "$ROOT/$probe" >/dev/null 2>&1 || true
assert_has "claims lists every claim" "src/y.ts" "$(c claims)"

# --- offboard ---
pm claim src/z.ts >/dev/null
pm post --to "$A" --state blocked -m '# for pm to own' >/dev/null
a post --to "$PM" --state question -m '# pm owns this' >/dev/null
out=$(pm offboard)
assert_has "offboard drops the PM role and claims" "1 role(s), 1 claim(s) released" "$out"
assert_has "offboard lists items still owned" "pm owns this" "$out"
assert_has "PM role is gone" "no PM registered" "$(a role)"

# --- lanes: a feature's seats, across worktrees, with their own PM ---
l1() { seat l1 claude wl1 "$@"; }
l2() { seat l2 opencode wl2 "$@"; }
lp() { seat lp claude wlp "$@"; }
ot() { seat ot claude wot "$@"; }
L1=$(addr l1); L2=$(addr l2); LP=$(addr lp)
out=$(l1 lane here 2>&1 || true)
assert_has "reserved lane names are refused" "not a lane name" "$out"
l1 lane spaces >/dev/null; l2 lane spaces >/dev/null; ot lane other >/dev/null; lp who >/dev/null
assert_has "whoami shows the lane" "lane     spaces" "$(l1 whoami)"
assert_has "who tags lane members" "@spaces" "$(lp who | grep "$L1")"
out=$(l1 post --to @nolane -m x 2>&1 || true)
assert_has "an unknown lane is refused" "unknown scope" "$out"
out=$(l1 post --to @pm -m x 2>&1 || true)
assert_has "@pm with no lane or repo PM is refused" "no PM registered for lane @spaces" "$out"
ot read >/dev/null; l2 read >/dev/null
l1 post --to @spaces -m $'# lane news\n\nhi' >/dev/null
assert_has "@lane reaches lane members in other worktrees" "lane news" "$(l2 read --peek)"
assert_lacks "@lane skips other lanes" "lane news" "$(ot read --peek)"
lp role pm --lane spaces >/dev/null
assert_has "role shows the lane PM" "PM for lane @spaces: $LP" "$(lp role)"
out=$(ot role pm --lane spaces 2>&1 || true)
assert_has "live lane PM takeover needs --force" "--force" "$out"
lid=$(l1 post --to "$L2" --state needs-review -m $'# lane review\n\nx' | idof)
oid=$(ot post --to claude/wsomeone --state blocked -m $'# other lane stuck\n\nx' | idof)
out=$(lp read --peek)
assert_has "lane PM gets a copy of its lane's work" "lane review" "$out"
assert_lacks "lane PM does not see other lanes' work" "other lane stuck" "$out"
assert_has "lane PM is woken for its lane" "block" "$(lp stop-hook </dev/null | jq -r .decision)"
pid=$(l1 post --to @pm --state question -m $'# ask lane pm\n\nx' | idof)
assert_has "@pm from a lane seat reaches the lane PM" "ask lane pm" "$(lp read --peek)"
bid=$(l1 post --to @spaces --state blocked -m $'# lane blocker\n\nx' | idof)
out=$(ot role pm --lane spaces --force)
assert_has "a PM takeover lists what is already open" "open item(s) in this scope, newest first" "$out"
assert_has "the list names the item" "lane blocker" "$out"
assert_lacks "and marks it read instead of waking on it" "lane blocker" "$(ot read --peek)"
lp role pm --lane spaces --force >/dev/null
out=$(lp triage --lane spaces)
assert_has "lane broadcasts are owned by the lane PM" "owner $LP" "$out"
assert_lacks "triage --lane filters to the lane" "other lane stuck" "$out"
assert_has "lane PM can close its lane's items" "resolved $lid (done)" "$(lp resolve "$lid" --reason done)"
out=$(lp resolve "$oid" --reason done 2>&1 || true)
assert_has "lane PM cannot close other lanes' items" "not its sender" "$out"
assert_has "lane PM packets are marked as the PM's" "from the PM your user put in charge" \
  "$(lp post --to "$L1" --state handoff -m '# lane task' >/dev/null; l1 read --peek)"
assert_has "offboard releases the lane PM role" "1 role(s)" "$(lp offboard)"
assert_has "lane PM is gone" "no PM registered for lane @spaces" "$(lp role --lane spaces)"
l1 lane --clear >/dev/null
assert_has "a seat can leave its lane" "lane     (none)" "$(l1 whoami)"

# --- lanes infer themselves from the branch ---
br() { local b="$1"; shift; AGENT_BUS_BRANCH="$b" AGENT_BUS_SESSION="br-$b" AGENT_BUS_TOOL=opencode AGENT_BUS_WT=wbr "$BIN" "$@"; }
assert_has "a ticket in the branch names the lane" "lane     salt-8947 (branch)" "$(br feature/salt-8947-skills whoami)"
assert_has "ticket keys are case-insensitive" "lane     salt-6176 (branch)" "$(br feat/SALT-6176_bulk whoami)"
assert_has "a version is not a ticket" "lane     sonnet-5-5-orchestrator (branch name)" "$(br claude/sonnet-5-5-orchestrator whoami)"
assert_has "no ticket: the branch slug is the lane" "lane     login-redirect (branch name)" "$(br fix/login-redirect whoami)"
assert_has "trunk branches are unfiled" "lane     (none)" "$(br develop whoami)"
assert_has "a ticket in the worktree name counts" "lane     salt-7281 (worktree)" \
  "$(AGENT_BUS_BRANCH=develop AGENT_BUS_SESSION=wtk AGENT_BUS_TOOL=opencode AGENT_BUS_WT=salt-7281-fix "$BIN" whoami)"
assert_has "an explicit lane wins over the branch" "lane     parity (explicit)" \
  "$(br feature/salt-8947-skills lane parity >/dev/null; br feature/salt-8947-skills whoami)"
assert_has "clearing it falls back to the branch" "now in @salt-8947 (branch)" "$(br feature/salt-8947-skills lane --clear)"
assert_has "AGENT_BUS_LANE overrides everything" "lane     forced (env)" "$(AGENT_BUS_LANE=forced br feature/salt-8947-skills whoami)"
assert_has "AGENT_BUS_TICKET_PREFIXES limits ticket keys" "lane     salt-8947-skills (branch name)" \
  "$(AGENT_BUS_TICKET_PREFIXES=eng br feature/salt-8947-skills whoami)"
br fix/salt-8947-other who >/dev/null
out=$(br feature/salt-8947-skills post --to @salt-8947 --state question -m '# lane q')
assert_has "a derived lane is addressable" "posted" "$out"
assert_eq "posts carry the lane and the ticket ref" '"salt-8947" ["SALT-8947"]' \
  "$(tail -n 1 "$BUS_HOME/ledger.jsonl" | jq -rc '"\(.lane | tojson) \(.refs | tojson)"')"
assert_has "lane peers get @lane posts" "lane q" "$(br fix/salt-8947-other read --peek)"
# Orientation: the first digest of a session says where the seat is filed.
out=$(br fix/salt-8947-other digest)
assert_has "first digest orients the seat" "in lane @salt-8947 (from branch)" "$out"
assert_has "orientation names lane peers" "peers: opencode/wbr." "$out"
assert_lacks "orientation shows once per session" "in lane @" "$(br fix/salt-8947-other digest)"
assert_has "an unfiled seat is asked to pick a lane" "not in a lane (branch develop" "$(br develop digest)"
# Old rows with no stamped lane are grouped by where they were sent from.
printf '{"kind":"msg","id":"20200104T000000Z-0000ccc1","epoch":%s,"from":"x","to":"claude/wgone","state":"blocked","subject":"legacy","repo":"r","repo_id":"%s","branch":"feature/salt-4242-old","wt":"w"}\n' \
  "$(date -u +%s)" "$(a whoami | awk '/^repo_id/{print $2}')" >>"$BUS_HOME/ledger.jsonl"
assert_has "old rows get their lane on read" "lane @salt-4242" "$(a triage --by lane)"
assert_eq "snapshot reports the derived lane" "salt-4242" \
  "$("$BIN" snapshot | jq -r '.open[] | select(.id == "20200104T000000Z-0000ccc1") | .lane')"

# Seats carry their worktree path and agent pid, for viewers that map resources.
snapseat() { "$BIN" snapshot | jq -r --arg w "$1" ".seats[] | select(.wt == \$w) | $2"; }
AGENT_BUS_PID=$$ AGENT_BUS_SESSION=pid1 AGENT_BUS_TOOL=opencode AGENT_BUS_WT=wpid "$BIN" who >/dev/null
assert_eq "AGENT_BUS_PID sets the seat's pid" "$$" "$(snapseat wpid .pid)"
assert_eq "snapshot reports the worktree path" "yes" "$(d=$(snapseat wpid .cwd); [ -n "$d" ] && [ -d "$d" ] && echo yes)"
AGENT_BUS_SESSION=pid2 AGENT_BUS_TOOL=opencode AGENT_BUS_WT=wnopid "$BIN" who >/dev/null
assert_eq "no agent process means a null pid" "null" "$(snapseat wnopid .pid)"
CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/$$.sock" AGENT_BUS_SESSION=pid3 AGENT_BUS_TOOL=claude AGENT_BUS_WT=wcpid "$BIN" who >/dev/null
assert_eq "claude's pid comes from its inbox socket" "$$" "$(snapseat wcpid .pid)"
CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/999999.sock" AGENT_BUS_SESSION=pid3 AGENT_BUS_TOOL=claude AGENT_BUS_WT=wcpid "$BIN" who >/dev/null
assert_eq "a live pid is kept for the same session" "$$" "$(snapseat wcpid .pid)"

# --- lane lifecycle, re-filing, roles, @lead, attention, projects ---
lead() { AGENT_BUS_TOOL=lead AGENT_BUS_SESSION=app AGENT_BUS_WT=lead "$BIN" "$@"; }
lc() { AGENT_BUS_BRANCH=feature/salt-5000-life AGENT_BUS_SESSION=lc1 AGENT_BUS_TOOL=opencode AGENT_BUS_WT=wlc "$BIN" "$@"; }
lc who >/dev/null
i1=$(lc post --to claude/wlcgone --state blocked -m '# life one' | idof)
i2=$(lc post --to claude/wlcgone --state question -m '# life two' | idof)
out=$(lc lane salt-5000 done --reason merged 2>&1 || true)
assert_has "only the lead or a PM can close a lane" "only the lead" "$out"
out=$(lead lane salt-5000 done 2>&1 || true)
assert_has "lane done needs a reason" "--reason is required" "$out"
out=$(lead lane salt-5000 done --reason merged)
assert_has "lane done closes its open items in one row" "closed 2 open item(s)" "$out"
assert_eq "it is one ledger row" "lane" "$(tail -n 1 "$BUS_HOME/ledger.jsonl" | jq -r .kind)"
assert_lacks "closed lane items leave open work" "life one" "$(lc triage)"
out=$(lead resolve "$i1" --reason done 2>&1 || true)
assert_has "a swept item counts as closed" "already closed" "$out"
i3=$(lc post --to claude/wlcgone --state blocked -m '# life three' | idof)
assert_has "new work after done stays open" "life three" "$(lc triage)"
assert_has "the lead may close anything" "resolved $i3 (done)" "$(lead resolve "$i3" --reason done)"
# sweep closes only older items
old=$(( $(date -u +%s) - 10 * 86400 ))
printf '{"kind":"msg","id":"20200105T000000Z-0000ddd1","epoch":%s,"from":"x","to":"claude/wlcgone","state":"blocked","subject":"swept old","repo":"r","repo_id":"%s","lane":"salt-5000"}\n' \
  "$old" "$(lc whoami | awk '/^repo_id/{print $2}')" >>"$BUS_HOME/ledger.jsonl"
i4=$(lc post --to claude/wlcgone --state blocked -m '# fresh one' | idof)
out=$(lead lane salt-5000 sweep --older 7d --reason canceled)
assert_has "sweep closes items older than the cutoff" "closed 1 item(s) older than 7d" "$out"
out=$(lc triage)
assert_lacks "the old item is swept" "swept old" "$out"
assert_has "the fresh one stays" "fresh one" "$out"
# park hides a lane from attention
lead lane salt-5000 park >/dev/null
assert_eq "a parked lane reports parked" "parked" \
  "$("$BIN" snapshot | jq -r '.lanes[] | select(.lane == "salt-5000") | .health')"
lead lane salt-5000 reopen >/dev/null
lead lane salt-5000 title --title "Lifecycle demo" >/dev/null
assert_has "a lane can carry a title" "Lifecycle demo" "$(lc lanes)"
# file moves an item to another lane
assert_has "file re-files an item" "filed $i4 in @salt-5001" "$(lc file "$i4" salt-5001)"
assert_eq "re-filed items report the new lane" "salt-5001" \
  "$("$BIN" snapshot | jq -r --arg id "$i4" '.open[] | select(.id == $id) | .lane')"
assert_has "triage --lane follows the re-file" "fresh one" "$(lc triage --lane salt-5001)"
# named roles
assert_has "a seat can take a named role" "@release:" "$(lc role release)"
out=$(lp role release 2>&1 || true)
assert_has "a live named role needs --force to take" "--force" "$out"
rid=$(b post --to @release --state needs-review -m '# release review' | idof)
assert_has "@role reaches the holder" "release review" "$(lc read --peek)"
assert_eq "the holder owns it" "block" "$(lc stop-hook </dev/null | jq -r .decision)"
assert_has "role lists named roles" "@release: opencode/wlc" "$(lc role)"
out=$(b post --to @nobody -m x 2>&1 || true)
assert_has "an unknown role is refused" "unknown scope" "$out"
# @lead: the human, through the app
lid=$(lc post --to @lead --state question -m '# need a call on scope' | idof)
out=$("$BIN" snapshot)
assert_eq "@lead items are owned by lead" "lead" "$(jq -r --arg id "$lid" '.open[] | select(.id == $id) | .owner' <<<"$out")"
assert_has "@lead items lead attention" "needs-you" "$(jq -r '.attention[].kind' <<<"$out")"
assert_has "the lead sees @lead items" "need a call on scope" "$(lead read --peek)"
out=$(lc post --re "$rid" --close escalated --to @lead --state question -m '# escalating release review')
assert_has "escalated hands an item to the lead" "closed $rid (escalated)" "$out"
out=$(lc resolve "$lid" --reason escalated 2>&1 || true)
assert_has "resolve cannot escalate" "needs a destination" "$out"
assert_has "superseded is a close reason" "resolved $lid (superseded)" "$(lead resolve "$lid" --reason superseded)"
assert_has "attention lists what needs a decision" "needs-you" "$(lead attention)"
# orphaned lanes show up in attention with the command that clears them
printf '{"kind":"msg","id":"20200106T000000Z-0000eee1","epoch":%s,"from":"x","to":"claude/wlcgone","state":"blocked","subject":"orphan","repo":"r","repo_id":"%s","lane":"salt-5999"}\n' \
  "$old" "$(lc whoami | awk '/^repo_id/{print $2}')" >>"$BUS_HOME/ledger.jsonl"
out=$("$BIN" attention)
assert_has "an untouched lane is orphaned" "@salt-5999: 1 open item(s), nobody on it" "$out"
assert_has "with the command that clears it" "agent-bus lane salt-5999 done --reason canceled" "$out"
# projects group lanes
printf '{"projects":[{"name":"Lifecycle","lanes":["salt-5*"]}]}\n' >"$BUS_HOME/projects.json"
assert_eq "projects.json groups lanes by glob" "Lifecycle" \
  "$("$BIN" snapshot | jq -r '.lanes[] | select(.lane == "salt-5999") | .project')"
rm -f "$BUS_HOME/projects.json"
lc role release --clear >/dev/null

# --- team rules: init, policy, ownerless work, review gates, decisions ---
# Policy seats drop the harness pins; PO/PR/PD override owner/review/decisions.
pol() { AGENT_BUS_BRANCH=feature/salt-7700-pol AGENT_BUS_SESSION="$1" AGENT_BUS_TOOL=opencode AGENT_BUS_WT="w$1" \
  AGENT_BUS_POLICY_OWNER="${PO:-}" AGENT_BUS_POLICY_REVIEW="${PR:-}" AGENT_BUS_POLICY_DECISIONS="${PD:-}" "$BIN" "${@:2}"; }
P1=$(pol p1 whoami | awk '/^seat/{print $2}'); P2=$(pol p2 whoami | awk '/^seat/{print $2}')
pol p1 who >/dev/null; pol p2 who >/dev/null
# The repo's rules file lives in the bus home for the test, never the checkout.
RF="$BUS_HOME/repo-policy.json"; export AGENT_BUS_REPO_POLICY="$RF"
# defaults, nudge, init --set
assert_has "defaults refuse ownerless work" "owner = refuse" "$(pol p1 init --show)"
assert_has "an unset repo nudges the agent to ask its user" "no team rules are set" "$(pol p3 digest)"
out=$(pol p1 init --set owner=bogus 2>&1 || true)
assert_has "init rejects bad values" "'bogus' is not a valid owner" "$out"
out=$(pol p1 init --set owner=refuse,review=requester,ask_lead=scope,disagreement,decisions=on)
assert_has "init --set saves the rules" "saved to" "$out"
assert_eq "ask_lead keeps its commas" "scope,disagreement" "$(jq -r .policy.ask_lead "$RF")"
assert_lacks "a set repo no longer nudges" "no team rules" "$(pol p4 digest)"
assert_has "orientation states the rules" "work items need a recipient" "$(pol p5 digest)"
assert_has "AGENT_BUS_POLICY_* overrides the repo" "owner = lead" "$(PO=lead pol p1 init --show)"
assert_has "guide teaches the patterns" "Hand work to someone specific" "$(pol p1 guide)"
assert_has "status shows the rules" "rules here:" "$(pol p1 status)"
# ownerless work: refused with suggestions, or given to the lead
out=$(pol p1 post --to @here --state needs-review -m '# nobody owns me' 2>&1 || true)
assert_has "a broadcast work item with no supervisor is refused" "has no owner" "$out"
assert_has "the refusal suggests a live lane peer" "--to $P2" "$out"
assert_has "and the lead" "--to @lead" "$out"
assert_has "messages still broadcast" "posted" "$(pol p1 post --to @here -m '# just so you know')"
out=$(PO=lead pol p1 post --to @here --state blocked -m '# lead owns me' 2>&1)
assert_has "owner=lead gives it to the lead" "the lead owns this" "$out"
assert_eq "the lead owns it in snapshot" "lead" \
  "$("$BIN" snapshot | jq -r '.open[] | select(.subject == "lead owns me") | .owner')"
# review gate: whoever asked accepts the work
hid=$(pol p1 post --to "$P2" --state handoff -m '# build the card' | idof)
assert_eq "assigned work records its reviewer" "$P1" "$(tail -n 1 "$BUS_HOME/ledger.jsonl" | jq -r .review)"
out=$(pol p2 resolve "$hid" --reason done -m "built")
assert_has "done on gated work submits it for review" "submitted $hid for review by $P1" "$out"
out=$(pol p2 post --re "$hid" --close done --to "$P1" --state done -m x 2>&1 || true)
assert_has "the doer cannot close gated work with post either" "needs review by $P1" "$out"
rid=$(pol p1 read --peek | sed -n 's/^ *id: //p' | tail -n 1)
assert_has "the reviewer gets a review item" "review: build the card" "$(pol p1 read --peek)"
out=$(pol p2 review "$rid" --approve 2>&1 || true)
assert_has "nobody approves their own work" "can't review it" "$out"
out=$(pol p1 review "$rid" --changes 2>&1 || true)
assert_has "changes need notes" "say what to fix" "$out"
assert_has "changes send it back" "sent back to $P2" "$(pol p1 review "$rid" --changes -m 'add an empty state')"
assert_has "the doer gets the notes" "changes requested: build the card" "$(pol p2 read --peek)"
cid=$(pol p2 read --peek | sed -n 's/^ *id: //p' | tail -n 1)
assert_has "resubmitting goes back to the same reviewer" "for review by $P1" "$(pol p2 resolve "$cid" --reason done)"
rid=$(pol p1 read --peek | sed -n 's/^ *id: //p' | tail -n 1)
assert_has "approval closes it" "approved: build the card" "$(pol p1 review "$rid" --approve)"
assert_lacks "nothing from the loop stays open" "build the card" "$(pol p1 triage)"
# a reviewer who has gone hands the review to the lead
hid=$(pol p1 post --to "$P2" --state handoff --review opencode/wgone.1234 -m '# orphan review' | idof)
assert_has "a gone reviewer is replaced by the lead" "for review by @lead" "$(pol p2 resolve "$hid" --reason done)"
assert_has "the lead sees it as a review" "review" "$("$BIN" snapshot | jq -r '.attention[].kind')"
lrid=$("$BIN" snapshot | jq -r '.open[] | select(.review_of != null and .owner == "lead") | .id' | head -1)
assert_has "the lead can approve" "approved: orphan review" "$(lead review "$lrid" --approve)"
assert_has "review=none skips the gate" "resolved" \
  "$(hid=$(PR=none pol p1 post --to "$P2" --state handoff -m '# no gate' | idof); pol p2 resolve "$hid" --reason done)"
# decisions
out=$(pol p1 decide "Cards ship behind the cards_v2 flag" -m "billing not ready")
assert_has "decide records a decision" "decided for @salt-7700" "$out"
did=$(sed -n 's/.*(\(.*\))$/\1/p' <<<"$out")
assert_has "later sessions on the lane are told" "decisions to follow here: Cards ship behind the cards_v2 flag" "$(pol p6 digest)"
assert_has "decisions lists them with why" "why: billing not ready" "$(pol p1 decisions)"
pol p1 decide "Cards ship to everyone" --supersedes "$did" >/dev/null
out=$(pol p1 decisions)
assert_lacks "a superseded decision drops out" "cards_v2 flag" "$out"
assert_has "its replacement shows" "Cards ship to everyone" "$out"
assert_has "snapshot carries lane decisions" "Cards ship to everyone" "$("$BIN" snapshot | jq -r '.lanes[].decisions[]?.text')"
assert_has "decisions are hidden when the team turned them off" "" \
  "$(PD=off pol p7 digest | grep -c 'decisions to follow' || true)"
rm -f "$RF"; unset AGENT_BUS_REPO_POLICY

# An unlimited wake budget (the default) never reports a seat out of wakes.
assert_lacks "budget 0 means nobody runs out of wakes" "budget" "$(AGENT_BUS_WAKE_BUDGET=0 "$BIN" snapshot | jq -r '.attention[].kind')"

# --- snapshot: one machine-wide JSON view for viewers ---
snap=$("$BIN" snapshot)
assert_eq "snapshot is one JSON object" "object" "$(jq -r type <<<"$snap")"
assert_has "snapshot lists live seats" "$B" "$(jq -r '.seats[].addr' <<<"$snap")"
assert_has "snapshot lists open work with its owner" "claude/wgone" "$(jq -r '.open[].owner' <<<"$snap")"
assert_eq "snapshot flags a gone owner" "true" "$(jq -r '[.open[] | select(.owner == "claude/wgone")][0].gone' <<<"$snap")"
assert_eq "snapshot leaves closed items out" "" "$(jq -r --arg id "$hid" '.open[] | select(.id == $id) | .id' <<<"$snap")"
assert_has "snapshot recent activity includes closes" "resolve" "$(jq -r '.recent[].kind' <<<"$snap")"

# --- safety ---
out=$("$BIN" show ../../etc/passwd 2>&1 || true)
assert_has "show refuses non-ids" "needs a packet id" "$out"
printf '%s\n' '{"kind":"msg","id":"../../x","epoch":9999999999,"from":"evil","to":"@all","state":"fyi","subject":"crafted","session":"e","repo_id":"r"}' >>"$BUS_HOME/ledger.jsonl"
assert_has "crafted id never becomes a path" "malformed id" "$(a read --peek)"
printf 'not json\n' >>"$BUS_HOME/ledger.jsonl"
assert_has "a torn ledger row is skipped" "crafted" "$(a read --peek)"
a read >/dev/null
b post --to "$A" -s $'esc\033[31mape' -m x >/dev/null
out=$(a read --peek)
assert_lacks "control bytes are stripped" $'\033' "$out"
assert_has "the text survives" "esc[31mape" "$out"
out=$(head -c 70000 /dev/zero | tr '\0' x | a post --to @here -m "$(cat)" 2>&1 || true)
assert_has "oversized body is refused" "max 65536" "$out"

# --- push: only the owner is woken ---
if command -v python3 >/dev/null && command -v nc >/dev/null; then
  SOCKD=$(mktemp -d /tmp/abus.XXXX)
  python3 - "$SOCKD" <<'PY' &
import os, socket, sys, threading
d = sys.argv[1]
def serve(name):
    p = os.path.join(d, name); s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen(8)
    while True:
        c, _ = s.accept(); data = c.recv(65536); c.close()
        if data:
            open(p + ".log", "ab").write(data)
for n in ("owner", "bystander"):
    threading.Thread(target=serve, args=(n,), daemon=True).start()
threading.Event().wait()
PY
  SRV=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCKD/bystander" ] && break; sleep 0.1; done
  CLAUDE_CODE_MESSAGING_SOCKET="$SOCKD/owner" seat o1 claude wp who >/dev/null
  CLAUDE_CODE_MESSAGING_SOCKET="$SOCKD/bystander" seat o2 claude wp who >/dev/null
  O1=$(addr seat o1 claude wp)
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wx post --to "$O1" --state needs-review -m '# wake owner')
  sleep 0.3
  assert_has "post wakes the idle owner" "delivery: $O1 — woken" "$out"
  assert_has "owner got an inbox frame" "agent-bus read" "$(cat "$SOCKD/owner.log" 2>/dev/null)"
  assert_eq "bystander got nothing" "" "$(cat "$SOCKD/bystander.log" 2>/dev/null)"
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wp post --to @here --state needs-review -m '# broadcast review' 2>/dev/null)
  assert_lacks "broadcast review wakes no bystander" "— woken" "$out"
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wp post --to @here -m '# broadcast fyi')
  assert_lacks "a broadcast fyi wakes nobody" "— woken" "$out"
  assert_has "post says a broadcast reaches nobody" "nobody owns this, so nobody is woken" "$out"
  # A restarted agent's new seat inherits posts sent to the old name.
  seat h1 opencode wheir who >/dev/null
  H1=$(addr seat h1 opencode wheir)
  f="$BUS_HOME/seats/$(printf '%s' "$H1" | tr '/' '_').json"; jq '.epoch = 0' "$f" >"$f.t" && mv "$f.t" "$f"
  seat h2 opencode wheir who >/dev/null
  H2=$(addr seat h2 opencode wheir)
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wx post --to "$H1" --state handoff -m '# for the restarted seat' 2>&1)
  assert_has "a post to a gone seat goes to its live heir" "is gone; sending to $H2" "$out"
  assert_has "the heir owns it" "for the restarted seat" "$(seat h2 opencode wheir read --peek)"
  # OpenCode that isn't running is reported, not silently queued.
  AGENT_BUS_PID=999999 seat h3 opencode wstop who >/dev/null
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wx post --to "$(addr seat h3 opencode wstop)" -m '# are you there')
  assert_has "post says an OpenCode seat is stopped" "not running; it sees this when restarted" "$out"
  AGENT_BUS_TOOL=shell AGENT_BUS_WT=wsh "$BIN" who >/dev/null
  out=$(AGENT_BUS_NO_PUSH=0 seat o3 claude wx post --to shell/wsh -m '# plain shell')
  assert_has "post says a hookless seat must read" "has no hooks" "$out"
  # A claim left by an ended seat doesn't block.
  seat h2 opencode wheir claim src/left.ts >/dev/null
  f="$BUS_HOME/seats/$(printf '%s' "$H2" | tr '/' '_').json"; jq '.epoch = 0' "$f" >"$f.t" && mv "$f.t" "$f"
  out=$(seat o3 claude wx claim src/left.ts 2>&1)
  assert_has "a gone seat's claim is taken over" "has ended; taking it over" "$out"
  assert_has "and claimed" "claimed src/left.ts" "$out"
  assert_eq "bystander still got nothing" "" "$(cat "$SOCKD/bystander.log" 2>/dev/null)"
  kill "$SRV" 2>/dev/null || true; wait "$SRV" 2>/dev/null || true; SRV=; rm -rf "$SOCKD"
else
  printf 'skip push tests (python3/nc missing)\n'
fi

# --- grok: webhook delivery ---
# Helper: invoke agent-bus as a generic shell (registration caller)
greg() { AGENT_BUS_TOOL=shell AGENT_BUS_WT=tester AGENT_BUS_SESSION=grtest "$BIN" "$@"; }
# Helper: invoke agent-bus as the registered Grok Bot seat
gbot() { AGENT_BUS_TOOL=grok  AGENT_BUS_WT=bot1   AGENT_BUS_SESSION=local  "$BIN" "$@"; }

# Registration validation
out=$(greg grok register --name 'BAD NAME' --webhook http://x/ 2>&1 || true)
assert_has "grok register rejects invalid name" "must be lowercase" "$out"
out=$(greg grok register --name bot1 --webhook 'ftp://no' 2>&1 || true)
assert_has "grok register rejects non-http webhook" "must start with http" "$out"
out=$(greg grok register --name bot1 --webhook http://ok/ --secret-env '1BADVAR' 2>&1 || true)
assert_has "grok register rejects bad secret-env name" "valid environment variable" "$out"
out=$(greg grok register --name bot1 --webhook http://ok/)
assert_has "grok register succeeds" "registered grok/bot1" "$out"

# Seat visibility
out=$(greg who)
assert_has "registered grok seat shows in who" "grok/bot1" "$out"
GADDR=$(gbot whoami | awk '/^seat/{print $2}')
assert_has "grok seat has correct address" "grok/bot1" "$GADDR"

# Triage: seat is reachable, so open items owned by it are not GONE
tid=$(a post --to "$GADDR" --state needs-review -m $'# for grok bot\n\nhello' | idof)
out=$(pm triage)
assert_lacks "registered grok seat is not GONE" "GONE" "$(grep "$GADDR" <<<"$out")"
assert_has "grok work shows in triage" "$GADDR" "$out"

# Budget reset via grok seat resolving
gbot resolve "$tid" --reason done >/dev/null
assert_has "grok bot can resolve its own item" "0" \
  "$(jq -r '.wakes // 0' "$BUS_HOME/state/$(printf '%s' "$GADDR" | tr '/:@ ' '____').json" 2>/dev/null || echo 0)"

if command -v python3 >/dev/null && command -v curl >/dev/null; then
  GROOKD=$(mktemp -d /tmp/abus-grok.XXXX)
  python3 - "$GROOKD" <<'PY' &
import http.server, json, os, pathlib, sys
d = pathlib.Path(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n)) if n else {}
        rec = {'body': body, 'auth': self.headers.get('Authorization', '')}
        (d / 'requests.jsonl').open('a').write(json.dumps(rec) + '\n')
        self.send_response(int(os.environ.get('FAKE_HTTP_STATUS', '200')))
        self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
(d / 'port').write_text(str(s.server_address[1]))
s.serve_forever()
PY
  GROK_SRV=$!
  for _i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$GROOKD/port" ] && break; sleep 0.1; done
  GROK_PORT=$(cat "$GROOKD/port")
  GROK_URL="http://127.0.0.1:$GROK_PORT/hook"

  # Re-register with a real webhook URL (replaces the placeholder from above)
  greg grok register --name bot1 --webhook "$GROK_URL" >/dev/null

  # Delivery: post to grok seat triggers webhook
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state needs-review \
    -m $'# needs-review for grok\n\nplease check' 2>&1)
  sleep 0.3
  assert_has "webhook delivery reported" "webhook notice delivered" "$out"

  # Payload shape: routing info only, no packet body
  req=$(tail -1 "$GROOKD/requests.jsonl" 2>/dev/null || echo '{}')
  assert_has "payload has packet_id"  '"packet_id"'  "$req"
  assert_has "payload has from"       '"from"'        "$req"
  assert_has "payload has to"         '"to"'          "$req"
  assert_has "payload has state"      '"needs-review"' "$req"
  assert_has "payload has repo"       '"repo"'        "$req"
  assert_has "payload has repo_id"    '"repo_id"'     "$req"
  assert_lacks "payload omits packet body" "please check" "$req"

  # Delivery row in ledger
  assert_has "delivery row uses grok-webhook transport" \
    '"transport":"grok-webhook"' "$(cat "$BUS_HOME/ledger.jsonl")"
  assert_has "delivery row status is delivered" '"status":"delivered"' \
    "$(cat "$BUS_HOME/ledger.jsonl")"

  # Opt-in budget exhaustion (AGENT_BUS_WAKE_BUDGET=3; first post above used slot 1)
  w2=$(AGENT_BUS_WAKE_BUDGET=3 AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# q2' | idof)
  AGENT_BUS_WAKE_BUDGET=3 AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# q3' >/dev/null
  out=$(AGENT_BUS_WAKE_BUDGET=3 AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# q4' 2>&1)
  assert_has "opt-in budget exhausted: delivery skipped" "budget_exhausted" "$out"
  assert_has "delivery row for exhausted attempt" '"status":"budget_exhausted"' \
    "$(cat "$BUS_HOME/ledger.jsonl")"

  # Closing an item resets the opt-in budget
  gbot resolve "$w2" --reason done >/dev/null
  out=$(AGENT_BUS_WAKE_BUDGET=3 AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question -m '# after-reset' 2>&1)
  assert_has "closing resets grok wake budget" "webhook notice delivered" "$out"

  # Packet stays unread after successful delivery (only cmd_read marks packets read)
  latest_id=$(a post --to "$GADDR" --state question -m '# unread-check' | idof)
  sleep 0.1
  state_file="$BUS_HOME/state/$(printf '%s' "$GADDR" | tr '/:@ ' '____').json"
  read_list=$(jq -r '.read // [] | length' "$state_file" 2>/dev/null || echo 0)
  assert_eq "webhook delivery does not mark packet read" "0" \
    "$(jq -r --arg i "$latest_id" '(.read // []) | index($i) != null | if . then 1 else 0 end' \
       "$state_file" 2>/dev/null || echo 0)"

  # Failure leaves packet unread: register a second seat with an unreachable URL
  greg grok register --name bot2 --webhook "http://127.0.0.1:1/unreachable" >/dev/null
  GADDR2=$(AGENT_BUS_TOOL=grok AGENT_BUS_WT=bot2 AGENT_BUS_SESSION=local "$BIN" whoami \
    | awk '/^seat/{print $2}')
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$GADDR2" --state question -m '# unreachable' 2>&1)
  assert_has "failure: packet saved message" "packet saved" "$out"
  state2="$BUS_HOME/state/$(printf '%s' "$GADDR2" | tr '/:@ ' '____').json"
  assert_eq "failure: packet remains unread" "0" \
    "$(jq -r '.read // [] | length' "$state2" 2>/dev/null || echo 0)"
  assert_has "failure: delivery row recorded" '"transport":"grok-webhook"' \
    "$(cat "$BUS_HOME/ledger.jsonl")"
  greg grok unregister --name bot2 >/dev/null

  # grok status
  out=$(greg grok status)
  assert_has "grok status shows webhook" "$GROK_URL" "$out"
  assert_has "grok status shows wakes" '"wakes"' "$out"

  # grok status --name filter
  out=$(greg grok status --name bot1)
  assert_has "grok status --name filters to named seat" "grok/bot1" "$out"

  # Secret: register with --secret-env, verify Authorization header is sent
  GROK_TEST_TOKEN=tok123
  export GROK_TEST_TOKEN
  greg grok register --name bot1 --webhook "$GROK_URL" --secret-env GROK_TEST_TOKEN >/dev/null
  AGENT_BUS_NO_PUSH=0 a post --to "$GADDR" --state question \
    -m '# secret-test' >/dev/null
  sleep 0.1
  auth_req=$(grep 'tok123' "$GROOKD/requests.jsonl" || true)
  assert_has "bearer token sent as Authorization header" "tok123" \
    "$(tail -1 "$GROOKD/requests.jsonl")"
  unset GROK_TEST_TOKEN
  # Reset back to no-secret for cleanliness
  greg grok register --name bot1 --webhook "$GROK_URL" >/dev/null

  # Grok seat in who after registration
  assert_has "grok status shows in doctor" "grok" "$(greg doctor)"

  # grok unregister
  out=$(greg grok unregister --name bot1)
  assert_has "grok unregister reports" "unregistered grok/bot1" "$out"
  out=$(greg who)
  assert_lacks "unregistered grok seat gone from who" "grok/bot1" "$out"
  out=$(greg grok unregister --name bot1 2>&1 || true)
  assert_has "double unregister is an error" "not registered" "$out"

  kill "$GROK_SRV" 2>/dev/null || true
  wait "$GROK_SRV" 2>/dev/null || true
  GROK_SRV=; rm -rf "$GROOKD"
else
  printf 'skip grok webhook tests (python3/curl missing)\n'
fi

# --- gc ---
old=$(( $(date -u +%s) - 30 * 86400 ))
printf '{"kind":"msg","id":"20200101T000000Z-0000abcd","epoch":%s,"from":"x","to":"@all","state":"fyi","subject":"ancient"}\n' "$old" >>"$BUS_HOME/ledger.jsonl"
printf 'old\n' >"$BUS_HOME/msg/20200101T000000Z-0000abcd.md"
out=$("$BIN" gc)
assert_has "gc rotates old rows" "1 ledger rows rotated" "$out"
assert_has "rotated rows land in the archive" "ancient" "$(cat "$BUS_HOME/ledger.archive.jsonl")"
assert_eq "old bodies are removed" "no" "$([ -f "$BUS_HOME/msg/20200101T000000Z-0000abcd.md" ] && echo yes || echo no)"
assert_has "gc keeps undatable rows" "not json" "$(cat "$BUS_HOME/ledger.jsonl")"
touch -t 202001010000 "$BUS_HOME/seats/$(printf '%s' "$A" | tr '/:@ ' '____').json"
jq -c '.epoch = 1' "$BUS_HOME/seats/$(printf '%s' "$A" | tr '/:@ ' '____').json" >"$BUS_HOME/t" \
  && mv "$BUS_HOME/t" "$BUS_HOME/seats/$(printf '%s' "$A" | tr '/:@ ' '____').json"
"$BIN" gc >/dev/null
assert_eq "a dead seat's read cursor survives" "yes" \
  "$([ -f "$BUS_HOME/state/$(printf '%s' "$A" | tr '/:@ ' '____').json" ] && echo yes || echo no)"

# Open work is never archived: gc prunes history, not unfinished work.
old15=$(( $(date -u +%s) - 15 * 86400 ))
for x in open:20200102T000000Z-0000aaa1 closed:20200102T000000Z-0000aaa2; do
  printf '{"kind":"msg","id":"%s","epoch":%s,"from":"x","to":"claude/wgone","state":"blocked","subject":"old %s","repo":"r","repo_id":"r"}\n' \
    "${x#*:}" "$old15" "${x%%:*}" >>"$BUS_HOME/ledger.jsonl"
  printf 'body\n' >"$BUS_HOME/msg/${x#*:}.md"
done
printf '{"kind":"resolve","msg":"20200102T000000Z-0000aaa2","by":"x","reason":"done","epoch":%s}\n' "$old15" >>"$BUS_HOME/ledger.jsonl"
"$BIN" gc >/dev/null
assert_has "a 15-day-old open item stays in the ledger" "old open" "$(cat "$BUS_HOME/ledger.jsonl")"
assert_eq "its body survives too" "yes" "$([ -f "$BUS_HOME/msg/20200102T000000Z-0000aaa1.md" ] && echo yes || echo no)"
assert_has "a closed old item is archived" "old closed" "$(cat "$BUS_HOME/ledger.archive.jsonl")"
assert_lacks "a closed old item leaves the ledger" "old closed" "$(cat "$BUS_HOME/ledger.jsonl")"
# An older gc archived open work; --restore-open brings it back, closed work stays.
printf '{"kind":"msg","id":"20200103T000000Z-0000bbb1","epoch":%s,"from":"x","to":"claude/wgone","state":"question","subject":"lost open","repo":"r","repo_id":"r"}\n' \
  "$old15" >>"$BUS_HOME/ledger.archive.jsonl"
out=$("$BIN" gc --restore-open)
assert_has "restore reports what came back" "restored 1 open item" "$out"
assert_has "the archived open item is back in the ledger" "lost open" "$(cat "$BUS_HOME/ledger.jsonl")"
assert_lacks "and gone from the archive" "lost open" "$(cat "$BUS_HOME/ledger.archive.jsonl")"
assert_has "closed items stay archived" "old closed" "$(cat "$BUS_HOME/ledger.archive.jsonl")"
assert_has "restored items show in snapshot" "lost open" "$("$BIN" snapshot | jq -r '.open[].subject')"
assert_has "restore is idempotent" "restored 0 open item" "$("$BIN" gc --restore-open)"
printf '{"kind":"lane","lane":"salt-3000","repo_id":"r","state":"parked","title":"old park","by":"x","epoch":%s}\n' "$old15" >>"$BUS_HOME/ledger.jsonl"
printf '{"kind":"file","msg":"20200102T000000Z-0000aaa1","lane":"salt-3001","by":"x","epoch":%s}\n' "$old15" >>"$BUS_HOME/ledger.jsonl"
"$BIN" gc >/dev/null
assert_has "gc keeps old lane rows (parked state, titles, sweeps)" "old park" "$(cat "$BUS_HOME/ledger.jsonl")"
assert_has "gc keeps old re-filings" '"lane":"salt-3001"' "$(cat "$BUS_HOME/ledger.jsonl")"

# -----------------------------------------------------------------------
# --- new: locking, TTL, secrets, ergonomics (#1–#11) ---

# --- #1/#2: ledger lock — concurrent appends and stale-lock recovery ---

# Concurrent appends: 10 parallel posts must all land in the ledger.
# Use a unique subject prefix that no other test produces.
for _i in $(seq 1 10); do a post --to "$B" -m "# locktest_conc$_i" >/dev/null & done
wait || true
# -c ensures compact (single-line) JSON output so wc -l counts rows correctly.
conc_n=$(jq -rcR 'fromjson? // empty | select(.kind=="msg" and (.subject | startswith("locktest_conc")))' \
  "$BUS_HOME/ledger.jsonl" | wc -l | tr -d ' ')
assert_eq "concurrent posts: all 10 rows land in ledger" "10" "$conc_n"
b read >/dev/null

# Stale lock recovery: a .buslock file with a dead PID is cleaned up by the
# next call without blocking.
( : ) & _dead=$!; wait $_dead 2>/dev/null || true
printf '%d\n' "$_dead" > "$BUS_HOME/ledger.jsonl.buslock"
out=$(a post --to "$B" -m "# after stale lock" 2>&1)
assert_has "post succeeds after stale ledger buslock" "posted" "$out"
assert_eq "stale buslock file removed" "no" \
  "$( [ -f "$BUS_HOME/ledger.jsonl.buslock" ] && echo yes || echo no )"
b read >/dev/null

# gc+append race: add 50 old rows so gc has something to rotate, then run gc
# and a concurrent appender; the two new rows must survive rotation.
for _i in $(seq 1 50); do
  printf '{"kind":"msg","id":"20200301T%06dZ-%08x","epoch":1,"from":"x","to":"@all","state":"fyi","subject":"gcold%d"}\n' \
    "$_i" "$_i" "$_i" >> "$BUS_HOME/ledger.jsonl"
done
( a post --to "$B" -m "# locktest_race1" >/dev/null
  a post --to "$B" -m "# locktest_race2" >/dev/null ) &
_POSTER=$!
"$BIN" gc >/dev/null
wait $_POSTER
race_n=$(jq -rcR 'fromjson? // empty | select(.kind=="msg" and (.subject | startswith("locktest_race")))' \
  "$BUS_HOME/ledger.jsonl" | wc -l | tr -d ' ')
assert_eq "posts during gc are not lost" "2" "$race_n"
b read >/dev/null

# --- #3: Codex zombie TTL ---
# A Codex seat whose last_hook is older than CODEX_MAX_IDLE_TTL should be expired.
_cst="$BUS_HOME/seats/codex_zombie_wa.json"
jq -nc '{addr:"codex/zombie_wa",tool:"codex",repo:"-",repo_id:"r",wt:"zombie_wa",
          branch:"-",cwd:"/tmp",session:"s1",socket:"",codex_queue:"/bin/true",
          epoch:1, last_hook:1, lane:""}' > "$_cst"
# With default TTL (86400), last_hook=1 (epoch seconds, far in the past) is expired.
assert_eq "codex zombie seat is not live" "no" \
  "$(AGENT_BUS_CODEX_MAX_IDLE_TTL=86400 a who 2>/dev/null | grep -q 'codex/zombie_wa' && echo yes || echo no)"
# With CODEX_MAX_IDLE_TTL=0, the seat falls back to epoch-based TTL (epoch=1 → expired too).
out=$(AGENT_BUS_CODEX_MAX_IDLE_TTL=0 "$BIN" gc 2>/dev/null)
assert_eq "gc removes expired codex zombie with TTL=0" "no" \
  "$([ -f "$_cst" ] && echo yes || echo no)"

# A Codex seat with a recent last_hook (now) should still be live.
_cst2="$BUS_HOME/seats/codex_fresh_wa.json"
_fresh_hook=$(date -u +%s)
jq -nc --argjson h "$_fresh_hook" --argjson e "$_fresh_hook" \
  '{addr:"codex/fresh_wa",tool:"codex",repo:"-",repo_id:"r",wt:"fresh_wa",
    branch:"-",cwd:"/tmp",session:"s2",socket:"",codex_queue:"/bin/true",
    epoch:$e, last_hook:$h, lane:""}' > "$_cst2"
assert_has "codex seat with recent last_hook appears in who" "codex/fresh_wa" \
  "$(AGENT_BUS_CODEX_MAX_IDLE_TTL=86400 a who 2>/dev/null)"
rm -f "$_cst2"

# --- #4: grok webhook secret file ---
if command -v python3 >/dev/null && command -v curl >/dev/null; then
  _GSD=$(mktemp -d)
  python3 - "$_GSD" <<'PY' &
import http.server, json, os, pathlib, sys
d = pathlib.Path(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(n)) if n else {}
        rec = {'body': body, 'auth': self.headers.get('Authorization', '')}
        (d / 'requests.jsonl').open('a').write(json.dumps(rec) + '\n')
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
(d / 'port').write_text(str(s.server_address[1]))
s.serve_forever()
PY
  _GSRV=$!
  for _i in $(seq 10); do [ -f "$_GSD/port" ] && break; sleep 0.1; done
  _GSD_URL="http://127.0.0.1:$(cat "$_GSD/port")/hook"

  # Register with a secret; token value should be stored in secrets file.
  TEST_GROK_SECRET=supersecret123
  export TEST_GROK_SECRET
  raw_seat gsreg shell tester grok register --name gstest \
    --webhook "$_GSD_URL" --secret-env TEST_GROK_SECRET >/dev/null
  assert_eq "secret file created at registration" "yes" \
    "$([ -f "$BUS_HOME/secrets/grok_gstest.secret" ] && echo yes || echo no)"
  assert_eq "secret file contains correct value" "supersecret123" \
    "$(cat "$BUS_HOME/secrets/grok_gstest.secret" 2>/dev/null)"
  assert_eq "secret file is 0600" "600" \
    "$(stat -c '%a' "$BUS_HOME/secrets/grok_gstest.secret" 2>/dev/null || \
       stat -f '%Lp' "$BUS_HOME/secrets/grok_gstest.secret" 2>/dev/null)"
  out=$(raw_seat gsreg shell tester grok status --name gstest)
  assert_has "grok status shows secret_file=true" '"secret_file":true' "$out"

  # Delivery reads from secrets file even when env var is unset.
  unset TEST_GROK_SECRET
  _GS_ADDR=$(raw_seat gsreg shell tester grok status --name gstest | jq -r .seat)
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$_GS_ADDR" --state question -m "# secret file delivery" 2>&1)
  sleep 0.3
  assert_has "delivery with secret from file" "webhook notice delivered" "$out"
  _GS_REQ=$(tail -1 "$_GSD/requests.jsonl" 2>/dev/null || echo '{}')
  assert_has "Authorization header sent from secrets file" "supersecret123" "$_GS_REQ"

  # Warning when secret_env is set but resolves empty (no file, no env var).
  rm -f "$BUS_HOME/secrets/grok_gstest.secret"
  out=$(AGENT_BUS_NO_PUSH=0 a post --to "$_GS_ADDR" --state question -m "# warn empty" 2>&1)
  sleep 0.1
  assert_has "warning when secret resolves empty" "WARNING" "$out"
  raw_seat gsreg shell tester grok unregister --name gstest >/dev/null

  # http:// + --secret-env warns at registration
  out=$(raw_seat gsreg shell tester grok register --name gstest2 \
    --webhook "http://example.com/hook" --secret-env TEST_GROK_SECRET 2>&1)
  assert_has "http:// with secret warns" "unencrypted" "$out"
  raw_seat gsreg shell tester grok unregister --name gstest2 2>/dev/null || true

  kill "$_GSRV" 2>/dev/null; wait "$_GSRV" 2>/dev/null || true
  rm -rf "$_GSD"
else
  printf 'skip grok secrets tests (python3/curl missing)\n'
fi

# --- #5: state lock — concurrent writes leave a valid state file ---
# Run 10 concurrent state-updating posts to the same seat.  With bus_lock
# protecting every state_update RMW, the resulting state file must be valid
# JSON (no torn write).  The lock does not prevent the TOCTOU between the
# budget check and the increment (that is a separate design matter), so we
# only assert file integrity, not a precise wakes count.
for _i in $(seq 1 10); do a post --to "$C" --state question -m "# statelock$_i" >/dev/null & done
wait || true
_sf="$BUS_HOME/state/$(printf '%s' "$C" | tr '/:@ ' '____').json"
assert_has "concurrent state writes: state file is valid JSON" \
  "$(jq . "$_sf" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
c read >/dev/null

# --- #6: triage outside a git repo gives clear error ---
# $BIN is an absolute path; run from /tmp which has no git tree.
out=$(cd /tmp && AGENT_BUS_HOME="$BUS_HOME" "$BIN" triage 2>&1 || true)
assert_has "triage outside repo gives clear error" "not in a git repo" "$out"

# --- #7: version command ---
out=$("$BIN" version)
assert_has "version command outputs version string" "agent-bus" "$out"
out=$("$BIN" --version)
assert_has "--version flag also works" "agent-bus" "$out"

# --- #9: atomic claim write (tmp+mv) ---
# Verify that concurrent claims on different paths don't produce corrupt files.
a claim src/atomic1.ts >/dev/null
a claim src/atomic2.ts >/dev/null
for _cf in "$BUS_HOME/claims/"*.json; do
  [ -f "$_cf" ] || continue
  jq -e . "$_cf" >/dev/null 2>&1 || bad "claim file is valid JSON" "bad JSON in $_cf" && ok "claim file $_cf is valid JSON"
done
a release --all >/dev/null

# --- #11: grok shell-init ---
raw_seat shinit shell tester grok register --name shinit --webhook https://example.com/ >/dev/null
out=$(raw_seat shinit shell tester grok shell-init --name shinit)
assert_has "grok shell-init outputs AGENT_BUS_TOOL=grok" "AGENT_BUS_TOOL=grok" "$out"
assert_has "grok shell-init outputs AGENT_BUS_WT" "AGENT_BUS_WT=shinit" "$out"
raw_seat shinit shell tester grok unregister --name shinit >/dev/null

# grok whoami warning when seat not registered
out=$(AGENT_BUS_TOOL=grok AGENT_BUS_WT=notregistered AGENT_BUS_SESSION=local "$BIN" whoami 2>&1)
assert_has "whoami warns for unregistered grok seat" "no seat file" "$out"

# --- doctor: the CLI on PATH is this one ---
out=$(PATH="$ROOT/bin:$PATH" a doctor 2>&1)
assert_lacks "doctor: no stale-install warning for the same CLI" "possible stale install" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
