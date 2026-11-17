#!/usr/bin/env bash
# agent-bus watch: the supervisor's wake ladder, stale seats, PM roles that
# stick to a lane, fyi_wake and thread_reports. Every switch is off by default.
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
export AGENT_BUS_POLICY_OWNER=pm AGENT_BUS_POLICY_REVIEW=none AGENT_BUS_BRANCH=develop
mkdir -p "$AGENT_BUS_HOME"

# One repo, committed long ago, so its own history never looks like activity.
R="$T/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && echo a >a.txt && git add a.txt \
  && GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git commit -qm init )

# A fake Herdr: `ls --json` from a file, `send` appends to a log.
mkdir -p "$T/bin"
cat >"$T/bin/hc" <<SH
#!/bin/sh
case "\$1" in
  ls) cat "$T/hc.json" ;;
  send) echo "\$2 \$3" >>"$T/hc.sends" ;;
esac
SH
chmod +x "$T/bin/hc"
export AGENT_BUS_HC="$T/bin/hc"
hcs() { printf '{"terminals":[%s]}' "$1" >"$T/hc.json"; }
hcs ''

seat() { local s="$1" t="$2" w="$3"; shift 3; (cd "$R" && AGENT_BUS_SESSION="$s" AGENT_BUS_TOOL="$t" AGENT_BUS_WT="$w" "$BIN" "$@"); }
addr() { "$@" whoami | awk '/^seat/{print $2}'; }
idof() { sed -n 's/.*id=//p' | tail -1; }
L="$AGENT_BUS_HOME/ledger.jsonl"
SON=(env AGENT_BUS_POLICY_SUPERVISE=on AGENT_BUS_NO_PUSH=0)
watch() { (cd "$R" && "${SON[@]}" "$BIN" watch --here); }
# Age a packet, a seat or a ladder stage by N seconds.
age_msg() { jq -c --arg id "$1" --argjson d "$2" 'if .id == $id then .epoch -= $d else . end' "$L" >"$L.t" && mv "$L.t" "$L"; }
seatf() { printf '%s/seats/%s.json' "$AGENT_BUS_HOME" "$(printf '%s' "$1" | tr '/:@ ' '____')"; }
age_seat() { local f; f=$(seatf "$1"); jq -c --argjson d "$2" '.epoch -= $d' "$f" >"$f.t" && mv "$f.t" "$f"; }
WF="$AGENT_BUS_HOME/state/watch.json"
age_stage() { jq -c --arg id "$1" --argjson d "$2" '.items[$id].at -= $d' "$WF" >"$WF.t" && mv "$WF.t" "$WF"; }
alerts_to() { jq -c --arg t "$1" 'select(.kind == "msg" and (.alert // null) != null and .to == $t)' "$L"; }

# Fixtures: a lane PM, a worker in Herdr terminal t9, a sender.
lp() { AGENT_BUS_LANE=feat seat lp claude main "$@"; }
w() { AGENT_BUS_LANE=feat HC_TERMINAL_ID=t9 seat w opencode wkr "$@"; }
s() { AGENT_BUS_LANE=feat seat s claude snd "$@"; }
lp role pm --lane feat >/dev/null
w who >/dev/null; s who >/dev/null
LP=$(addr lp); W=$(addr w); S=$(addr s)
assert_eq "an OpenCode seat never claims a Herdr terminal (its daemon's env names another)" null "$(jq -r .hc_terminal "$(seatf "$W")")"
HC_TERMINAL_ID=t3 seat cl claude cl who >/dev/null
assert_eq "a Claude seat records its Herdr terminal" t3 "$(jq -r .hc_terminal "$(seatf "$(addr seat cl claude cl)")")"
assert_eq "a PM role file keeps the address on line 1" "$LP" "$(head -1 "$AGENT_BUS_HOME"/state/roles/*.lane.feat.pm)"
assert_eq "and what it is bound to on line 2" feat "$(sed -n 2p "$AGENT_BUS_HOME"/state/roles/*.lane.feat.pm | jq -r .lane)"

# --- off by default ---
i1=$(s post --to "$W" --state needs-review -m "# review one" | idof)
age_msg "$i1" 700
out=$(cd "$R" && AGENT_BUS_NO_PUSH=0 "$BIN" watch --here)
assert_eq "watch does nothing while supervise is off" "" "$out"
assert_eq "and keeps no state" no "$([ -f "$WF" ] && echo yes || echo no)"

# --- the wake ladder ---
hcs '{"address":"t9","agent":"opencode","status":"idle","state":"live","cwd":"'"$R"'"}'
out=$(watch)
assert_has "10m unread wakes the owner" "wake $W for $i1: herdr" "$out"
assert_eq "through its own Herdr terminal, fixed text only" "t9 agent-bus: packet $i1 [needs-review] waits for you. Run: agent-bus read" "$(cat "$T/hc.sends")"
out=$(watch)
assert_eq "a wake fires once per item" 1 "$(wc -l <"$T/hc.sends" | tr -d ' ')"
age_stage "$i1" 700
out=$(watch)
assert_has "still unread 10m later: the lane PM hears" "alert -> $LP" "$out"
a1=$(alerts_to "$LP" | jq -r .id | tail -1)
assert_eq "the alert names the item" "$i1" "$(alerts_to "$LP" | jq -r '.alert.items[0]')"
assert_eq "and is a work item the PM owns" blocked "$(alerts_to "$LP" | jq -r .state)"
age_stage "$i1" 700
out=$(watch)
assert_has "still unread after that: the lead hears" "alert -> @lead" "$out"
i2=$(s post --to "$W" --state question -m "# second" | idof)
age_msg "$i2" 700; watch >/dev/null; age_stage "$i2" 700; watch >/dev/null; age_stage "$i2" 700
out=$(watch)
assert_has "a second item in the lane folds into the open lead alert" "folded 1 item(s) into the open lead alert for feat" "$out"
assert_eq "so the lead has one alert for the lane" 1 "$(alerts_to @lead | grep -c .)"
w read >/dev/null
out=$(watch)
assert_has "once the owner reads, alerts close themselves" "closed alert $a1" "$out"
assert_eq "every PM and lead alert for them (two PM, one lead)" 3 "$(jq -c 'select(.kind == "resolve" and .reason == "superseded")' "$L" | grep -c .)"
assert_eq "and the items stop being tracked" 0 "$(jq '.items | length' "$WF")"

# Backlog older than max_age is triage's, not the ladder's.
old=$(s post --to "$W" --state needs-review -m "# last week" | idof); age_msg "$old" 200000
out=$(watch)
assert_lacks "an item older than max_age is not woken" "for $old" "$out"
s resolve "$old" --reason canceled >/dev/null

# Herdr safety: never type into a shell, never interrupt a turn.
: >"$T/hc.sends"
i3=$(s post --to "$W" --state needs-review -m "# three" | idof); age_msg "$i3" 700
hcs '{"address":"t9","agent":"fish","status":"idle","state":"live","cwd":"'"$R"'"}'
out=$(watch)
assert_eq "a terminal whose agent exited gets no text" "" "$(cat "$T/hc.sends")"
i4=$(s post --to "$W" --state needs-review -m "# four" | idof); age_msg "$i4" 700
hcs '{"address":"t9","agent":"opencode","status":"working","state":"live","cwd":"'"$R"'"}'
out=$(watch)
assert_has "a terminal mid-turn is left alone" "wake $W for $i4: busy" "$out"
w read >/dev/null; watch >/dev/null
s resolve "$i1" "$i2" "$i3" "$i4" --reason done >/dev/null

# A terminal a person types in is never typed into.
hcs '{"address":"t9","agent":"opencode","status":"idle","state":"live","cwd":"'"$R"'"}'
: >"$T/hc.sends"
i8=$(s post --to "$W" --state needs-review -m "# lead terminal" | idof); age_msg "$i8" 700
out=$(cd "$R" && AGENT_BUS_WATCH_NO_TYPE=t9 "${SON[@]}" "$BIN" watch --here)
assert_eq "watch.no_type: no text typed into that terminal" "" "$(cat "$T/hc.sends")"
assert_lacks "and it is not reported as a Herdr wake" "for $i8: herdr" "$out"
i9=$(s post --to "$W" --state needs-review -m "# lead seat" | idof); age_msg "$i9" 700
out=$(cd "$R" && AGENT_BUS_WATCH_LEAD="$W" "${SON[@]}" "$BIN" watch --here)
assert_eq "the lead's own seat is never typed into either" "" "$(cat "$T/hc.sends")"
w read >/dev/null; s resolve "$i8" "$i9" --reason done >/dev/null; watch >/dev/null

# Two OpenCode terminals in one worktree: neither is typed into.
: >"$T/hc.sends"
hcs '{"address":"t9","agent":"opencode","status":"idle","state":"live","cwd":"'"$R"'"},{"address":"t8","agent":"opencode","status":"idle","state":"live","cwd":"'"$R"'"}'
i10=$(s post --to "$W" --state needs-review -m "# ambiguous" | idof); age_msg "$i10" 700
out=$(watch)
assert_eq "an OpenCode seat with two terminals in its worktree gets no typed wake" "" "$(cat "$T/hc.sends")"
# A terminal recorded by a seat but now running another tool: not typed into.
hcs '{"address":"t3","agent":"opencode","status":"idle","state":"live","cwd":"/elsewhere"}'
CL=$(addr seat cl claude cl)
i11=$(s post --to "$CL" --state needs-review -m "# wrong tool" | idof); age_msg "$i11" 700
out=$(watch)
assert_eq "a terminal running a different tool than the seat is not typed into" "" "$(cat "$T/hc.sends")"
w read >/dev/null; seat cl claude cl read >/dev/null; s resolve "$i10" "$i11" --reason done >/dev/null; watch >/dev/null

# Gone owner: straight to the PM.
g() { AGENT_BUS_LANE=feat seat g claude gone "$@"; }
g who >/dev/null; G=$(addr g); age_seat "$G" 99999
i5=$(s post --to "$G" --state handoff -m "# to a gone seat" | idof); age_msg "$i5" 700
out=$(watch)
assert_lacks "a gone owner is not woken" "wake $G" "$out"
assert_has "its item goes to the PM" "alert -> $LP" "$out"
s resolve "$i5" --reason canceled >/dev/null; watch >/dev/null

# --- stale seats ---
i6=$(s post --to "$W" --state handoff -m "# long job" | idof)
w read >/dev/null
w claim a.txt >/dev/null
hcs '{"address":"t9","agent":"opencode","status":"idle","state":"live","cwd":"'"$R"'"}'
out=$(watch)
assert_lacks "a seat active just now is not stale" "is stale" "$out"
age_seat "$W" 1300; age_msg "$i6" 1300
jq -c '.epoch -= 1300' "$AGENT_BUS_HOME"/claims/*.json >"$T/c" && for f in "$AGENT_BUS_HOME"/claims/*.json; do cp "$T/c" "$f"; done
w wait --until 30m -m "CI" >/dev/null
age_seat "$LP" 1300
out=$(watch)
assert_lacks "a declared wait is not stale" "is stale" "$out"
assert_lacks "a PM idle between items it owns by role is not stale" "$LP is stale" "$out"
w wait --clear >/dev/null
age_seat "$W" 1300
echo dirty >>"$R/a.txt"; touch -t 202001010000 "$R/a.txt"
out=$(watch)
assert_has "20m quiet while holding work: stale, PM told" "alert -> $LP: watch: $W is stale" "$out"
assert_has "with uncommitted changes the claim stays" "a.txt" "$(cd "$R" && AGENT_BUS_SESSION=lp AGENT_BUS_TOOL=claude AGENT_BUS_WT=main "$BIN" claims)"
assert_has "who marks it" "STALE (watch)" "$(lp who)"
out=$(watch)
assert_lacks "a stale seat is reported once" "is stale" "$out"
w heartbeat >/dev/null 2>&1 || w who >/dev/null
out=$(watch)
assert_has "activity clears it and closes the alert" "closed alert" "$out"
# Clean worktree: claims move aside, never deleted.
(cd "$R" && git checkout -q a.txt)
age_seat "$W" 1300
out=$(watch)
assert_has "with a clean worktree the claims are moved aside" "claim(s) were moved aside" "$(alerts_to "$LP" | tail -1 | jq -r .subject; cat "$AGENT_BUS_HOME/msg/$(alerts_to "$LP" | tail -1 | jq -r .id).md")"
assert_eq "into archive/claims" 1 "$(find "$AGENT_BUS_HOME/archive/claims" -name '*.json' | grep -c .)"
s resolve "$i6" --reason done >/dev/null

# --- PM roles stick to the lane ---
age_seat "$LP" 99999
lp2() { AGENT_BUS_LANE=feat seat lp2 claude main "$@"; }
out=$(lp2 who 2>&1)
assert_eq "without the switch a restarted PM does not take the role" "$LP" "$(head -1 "$AGENT_BUS_HOME"/state/roles/*.lane.feat.pm)"
out=$(AGENT_BUS_POLICY_SUPERVISE=on lp2 who 2>&1)
LP2=$(addr lp2)
assert_has "the only live seat with the PM's tool, worktree and lane takes it back" "taken back by $LP2" "$out"
assert_eq "the role file now names it" "$LP2" "$(head -1 "$AGENT_BUS_HOME"/state/roles/*.lane.feat.pm)"
# Same Herdr terminal wins even without a lane match.
HC_TERMINAL_ID=t7 AGENT_BUS_POLICY_SUPERVISE=on lp2 role pm --lane feat >/dev/null
age_seat "$LP2" 99999
out=$(HC_TERMINAL_ID=t7 AGENT_BUS_POLICY_SUPERVISE=on seat lp3 claude elsewhere who 2>&1)
assert_has "a PM restarted in its Herdr terminal takes the role back" "taken back by" "$out"
# Ambiguous: two live candidates, neither takes it.
age_seat "$(head -1 "$AGENT_BUS_HOME"/state/roles/*.lane.feat.pm)" 99999
AGENT_BUS_LANE=feat seat c1 codex amb who >/dev/null; AGENT_BUS_LANE=feat seat c2 codex amb who >/dev/null
printf 'codex/amb.dead\n' >"$(ls "$AGENT_BUS_HOME"/state/roles/*.lane.feat.pm)"
out=$(AGENT_BUS_POLICY_SUPERVISE=on AGENT_BUS_LANE=feat seat c1 codex amb who 2>&1)
assert_lacks "two possible successors: nobody takes it" "taken back" "$out"
# A lane whose PM is gone: the lead hears once.
out=$(watch)
assert_has "a lane with no live PM alerts the lead" "has no live PM" "$out"
out=$(watch)
assert_lacks "once" "has no live PM" "$out"

# --- fyi_wake and thread_reports ---
lp2 role pm --lane feat --force >/dev/null
out=$(AGENT_BUS_POLICY_FYI_WAKE=off AGENT_BUS_NO_PUSH=0 s post --to "$W" -m "# just so you know")
assert_has "fyi_wake=off: an fyi wakes nobody" "wakes nobody (team rule fyi_wake=off)" "$out"
assert_has "but it is still in the digest" "just so you know" "$(w read --peek)"
out=$(AGENT_BUS_NO_PUSH=0 s post --to "$W" -m "# default")
assert_lacks "with the default an fyi still delivers" "wakes nobody" "$out"
w read >/dev/null
asg=$(s post --to "$W" --state handoff -m "# do the thing" | idof)
out=$(AGENT_BUS_POLICY_THREAD_REPORTS=on w post --to "$S" --state needs-review -m "# done the thing")
assert_has "thread_reports: a report rides on its assignment" "threaded on $asg" "$out"
r1=$(idof <<<"$out")
assert_eq "as re" "$asg" "$(jq -r --arg id "$r1" 'select(.id == $id) | .re' "$L")"
out=$(AGENT_BUS_POLICY_THREAD_REPORTS=on AGENT_BUS_NO_PUSH=0 w post --to "$S" --state needs-review -m "# done the thing (again)")
assert_has "a second report right behind an unread first folds into it" "folded into $r1" "$out"
out=$(w post --to "$S" --state needs-review -m "# no rule")
assert_lacks "without the switch posts stay as they were" "threaded on" "$out"
out=$(AGENT_BUS_POLICY_THREAD_REPORTS=on w post --to "$S" --new-thread -m "# fresh")
assert_lacks "--new-thread opts out" "threaded on" "$out"

# --- a packet from another repo: its owner is found where it sits ---
R2="$T/other"; mkdir -p "$R2"
( cd "$R2" && git init -q && git config user.email t@t && git config user.name t && echo b >b.txt && git add b.txt \
  && GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z git commit -qm init )
ld() { (cd "$R2" && AGENT_BUS_SESSION=ld AGENT_BUS_TOOL=claude AGENT_BUS_WT=main "$BIN" "$@"); }
hcs '{"address":"t9","agent":"opencode","status":"idle","state":"live","cwd":"'"$R"'"}'
: >"$T/hc.sends"; w read >/dev/null
x1=$(ld post --to "$W" --state handoff -m "# from the lead's repo" | idof); age_msg "$x1" 700
out=$(cd "$R2" && "${SON[@]}" "$BIN" watch --here)
assert_has "an owner in another repo is woken, not reported missing" "wake $W for $x1: herdr" "$out"
x2=$(ld post --to "$W" --state question -m "# answered, not read" | idof); age_msg "$x2" 700
w post --to "$(cd "$R2" && AGENT_BUS_SESSION=ld AGENT_BUS_TOOL=claude AGENT_BUS_WT=main "$BIN" whoami | awk '/^seat/{print $2}')" --re "$x2" -m "# my answer" >/dev/null
jq -c --arg a "$W" --arg id "$x2" 'if .read then .read -= [$id] else . end' "$AGENT_BUS_HOME/state/$(printf '%s' "$W" | tr '/' '_').json" >"$T/st" \
  && mv "$T/st" "$AGENT_BUS_HOME/state/$(printf '%s' "$W" | tr '/' '_').json"
out=$(cd "$R2" && "${SON[@]}" "$BIN" watch --here)
assert_lacks "an owner that replied to an item has read it" "$x2" "$out"
ld resolve "$x1" "$x2" --reason done >/dev/null

# --- launchd mode: from anywhere, every repo ---
: >"$T/hc.sends"
hcs '{"address":"t9","agent":"opencode","status":"idle","state":"live","cwd":"'"$R"'"}'
w read >/dev/null
i7=$(s post --to "$W" --state needs-review -m "# from launchd" | idof); age_msg "$i7" 700
out=$(cd "$T" && "${SON[@]}" "$BIN" watch)
assert_has "watch with no flags finds the repo from its seats" "wake $W for $i7: herdr" "$out"
mkdir "$AGENT_BUS_HOME/state/watch.lockd"
assert_has "two passes never overlap" "another pass is running" "$(cd "$T" && "${SON[@]}" "$BIN" watch)"
rmdir "$AGENT_BUS_HOME/state/watch.lockd"

# --- status and wait ---
assert_has "watch --status says it is off" "supervise: off" "$(cd "$R" && "$BIN" watch --status)"
assert_has "wait rejects nonsense" "takes 30m" "$(cd "$R" && "$BIN" wait --until soon 2>&1 || true)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
