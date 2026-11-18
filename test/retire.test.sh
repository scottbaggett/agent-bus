#!/usr/bin/env bash
# The reaper (policy retire): finished, idle builders get their Herdr terminal
# ended and their compose test stacks taken down; sessions stay resumable and
# nothing is deleted. Dirty or unpushed worktrees are never retired.
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
export AGENT_BUS_HOME="$T/bus" AGENT_BUS_NO_PUSH=1 AGENT_BUS_NO_AUTO_GC=1 AGENT_BUS_NO_PEERS=1
export AGENT_BUS_POLICY_OWNER=pm AGENT_BUS_POLICY_REVIEW=none
mkdir -p "$AGENT_BUS_HOME" "$T/bin"
export GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z

# A repo with a remote, and one worktree per builder.
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
( cd "$T/repo" && git config user.email t@t && git config user.name t && echo a >a && git add a && git commit -qm init && git push -q origin HEAD:main 2>/dev/null )
wt() { # name branch: a pushed worktree on its own branch
  (cd "$T/repo" && git worktree add -q -b "$2" "$T/$1" 2>/dev/null && cd "$T/$1" && git push -q -u origin "$2" 2>/dev/null)
}
wt w1 feat-merged; wt w2 feat-closed-work; wt w3 feat-dirty; wt w4 feat-unpushed; wt w5 feat-pm
wt w6 feat-exempt; wt w7 feat-busy; wt w8 feat-open
echo dirty >>"$T/w3/a"; touch -t 202001010000 "$T/w3/a"
(cd "$T/w4" && echo b >b && git add b && git commit -qm local)

# Fakes: Herdr, docker, glab.
terms=''; for i in 1 2 3 4 5 6 7 8; do terms="$terms${terms:+,}{\"address\":\"t$i\",\"agent\":\"opencode\",\"status\":\"idle\",\"state\":\"live\",\"cwd\":\"$T/w$i\"}"; done
printf '{"terminals":[%s]}' "$terms" >"$T/hc.json"
cat >"$T/bin/hc" <<SH
#!/bin/sh
case "\$1" in ls) cat "$T/hc.json" ;; kill|rm) echo "\$1 \$2" >>"$T/hc.log" ;; esac
SH
cat >"$T/bin/docker" <<SH
#!/bin/sh
case "\$1" in
  ps) printf 'salt-backend-tests-w1\t$T/w1\npreview-db\t$T/w1\nsalt-local\t$T/w1\nkeep1\t$T/w1/sub\nother\t/elsewhere\nsalt-backend-tests-w2\t$T/w2\n' ;;
  compose) echo "\$*" >>"$T/docker.log" ;;
esac
SH
cat >"$T/bin/glab" <<SH
#!/bin/sh
# glab mr list --source-branch <b> --all --output json
case "\$4" in feat-merged|feat-dirty|feat-unpushed|feat-pm|feat-exempt|feat-busy) echo '[{"state":"merged"}]' ;; *) echo '[{"state":"opened"}]' ;; esac
SH
chmod +x "$T/bin/"*
export AGENT_BUS_HC="$T/bin/hc" AGENT_BUS_DOCKER="$T/bin/docker" AGENT_BUS_GLAB="$T/bin/glab"

seat() { local n="$1" w="$2"; shift 2; (cd "$T/$w" && AGENT_BUS_SESSION="$n" AGENT_BUS_TOOL=opencode "$BIN" "$@"); }
addr() { seat "$1" "$2" whoami | awk '/^seat/{print $2}'; }
pm() { (cd "$T/repo" && AGENT_BUS_SESSION=pm AGENT_BUS_TOOL=claude "$BIN" "$@"); }
idof() { sed -n 's/.*id=//p' | tail -1; }
L="$AGENT_BUS_HOME/ledger.jsonl"
pm role pm >/dev/null; PM=$(pm whoami | awk '/^seat/{print $2}')
for i in 1 2 3 4 5 6 7 8; do seat b$i w$i stop-hook </dev/null >/dev/null; done      # idle, as the plugin reports
seat b5 w5 role pm --lane side >/dev/null
# b2: its one assignment is closed; b8: its assignment is still open.
a2=$(pm post --to "$(addr b2 w2)" --state handoff -m "# job" | idof); pm resolve "$a2" --reason done >/dev/null
a8=$(pm post --to "$(addr b8 w8)" --state handoff -m "# open job" | idof)
age_all() { # everything older than the idle window, except b7
  for f in "$AGENT_BUS_HOME"/seats/opencode_*.json; do
    case "$f" in *feat-busy*|*w7*) continue ;; esac
    jq -c '.epoch -= 4000 | .activity_at -= 4000' "$f" >"$f.t" && mv "$f.t" "$f"
  done
  jq -c '.epoch -= 4000' "$L" >"$L.t" && mv "$L.t" "$L"
}
age_all
R() { (cd "$T/repo" && AGENT_BUS_WATCH_EXEMPT="$(addr b6 w6)" AGENT_BUS_WATCH_KEEP_STACKS=keep1 "$@"); }

# --- off by default ---
out=$(R env AGENT_BUS_POLICY_SUPERVISE=on AGENT_BUS_WATCH_SINCE=1 "$BIN" watch --here)
assert_lacks "retire is off by default" "retire" "$out"

# --- dry run ---
out=$(R "$BIN" watch --retire-dry-run --here)
assert_has "dry run lists a builder whose branch is merged" "would retire $(addr b1 w1) (its branch feat-merged is merged" "$out"
assert_has "and one whose every work item is closed" "would retire $(addr b2 w2) (every work item sent to it is closed" "$out"
assert_has "with the throwaway test stacks it would take down" "stacks down: salt-backend-tests-w1" "$out"
assert_has "and any other stack named, left running" "left running: preview-db" "$out"
assert_has "and how to resume it" "opencode -s b1" "$out"
assert_lacks "never salt-local" "salt-local" "$out"
assert_lacks "never a kept stack" "keep1" "$out"
assert_has "a dirty worktree is not retired" "$(addr b3 w3): finished" "$out"
assert_has "nor an unpushed one" "$(addr b4 w4): finished" "$out"
assert_lacks "never a PM" "$(addr b5 w5)" "$out"
assert_lacks "never an exempt seat" "$(addr b6 w6)" "$out"
assert_lacks "never a seat active inside the window" "$(addr b7 w7)" "$out"
assert_lacks "never one with open work and an open branch" "$(addr b8 w8)" "$out"
assert_eq "a dry run touches nothing" "no no" "$([ -f "$T/hc.log" ] && echo yes || echo no) $([ -f "$T/docker.log" ] && echo yes || echo no)"

# watch.retire_stacks opts other names in.
out=$(R env AGENT_BUS_WATCH_RETIRE_STACKS='salt-backend-tests-*,preview-*' "$BIN" watch --retire-dry-run --here)
assert_has "watch.retire_stacks opts more names in" "stacks down: preview-db salt-backend-tests-w1" "$out"

# --- on ---
out=$(R env AGENT_BUS_POLICY_SUPERVISE=on AGENT_BUS_WATCH_SINCE=1 AGENT_BUS_POLICY_RETIRE=on "$BIN" watch --here)
assert_has "retire=on ends the finished builder's terminal" "retired $(addr b1 w1)" "$out"
assert_eq "kill, then rm, for exactly the two finished builders" "kill t1 rm t1 kill t2 rm t2" "$(tr '\n' ' ' <"$T/hc.log" | sed 's/ $//')"
assert_eq "and takes down only their own throwaway test stacks" "compose -p salt-backend-tests-w1 down -v compose -p salt-backend-tests-w2 down -v" "$(tr '\n' ' ' <"$T/docker.log" | sed 's/ $//')"
pmmsg=$(jq -r --arg pm "$PM" 'select(.kind == "msg" and .to == $pm and ((.subject // "") | startswith("watch: retired"))) | .id' "$L" | head -1)
assert_has "its PM is told how to resume it" "resume with: cd $T/w1 && opencode -s b1" "$(cat "$AGENT_BUS_HOME/msg/$pmmsg.md")"
assert_has "and which stacks were left running" "Left running (not in watch.retire_stacks; take them down yourself if they are done): preview-db" "$(cat "$AGENT_BUS_HOME/msg/$pmmsg.md")"
assert_has "the PM hears about the unsaved worktree instead" "holds unsaved work" "$(jq -r --arg pm "$PM" 'select(.kind == "msg" and .to == $pm) | .subject' "$L")"
assert_eq "the seat, its worktree and its session are kept" "yes yes" \
  "$([ -f "$AGENT_BUS_HOME/seats/$(addr b1 w1 | tr '/' '_').json" ] && echo yes) $([ -d "$T/w1/.git" ] || [ -f "$T/w1/.git" ] && echo yes)"
: >"$T/hc.log"
out=$(R env AGENT_BUS_POLICY_SUPERVISE=on AGENT_BUS_WATCH_SINCE=1 AGENT_BUS_POLICY_RETIRE=on "$BIN" watch --here)
assert_eq "a retired seat is not retired again" "" "$(cat "$T/hc.log")"
assert_lacks "nor is the unsaved one reported twice" "holds unsaved" "$(R env AGENT_BUS_POLICY_SUPERVISE=on AGENT_BUS_WATCH_SINCE=1 AGENT_BUS_POLICY_RETIRE=on "$BIN" watch --here)"
assert_has "retire takes off, dry or on" "not a valid retire" "$(cd "$T/repo" && "$BIN" init --set retire=maybe 2>&1 || true)"
# --- work for a retired seat: never resumed out of sight; its sender hears ---
SON=(env AGENT_BUS_POLICY_SUPERVISE=on AGENT_BUS_WATCH_SINCE=1 AGENT_BUS_NO_PUSH=0)
B1=$(addr b1 w1)
nw=$(pm post --to "$B1" --state handoff -m "# new work for a retired seat" | idof)
jq -c --arg id "$nw" 'if .id == $id then .epoch -= 700 else . end' "$L" >"$L.t" && mv "$L.t" "$L"
out=$(R "${SON[@]}" "$BIN" watch --here)
assert_has "work for a retired seat is not delivered to it" "wake $B1 for $nw: retired" "$out"
assert_has "its sender hears how to resume it" "resume it to hand it this work: cd $T/w1 && opencode -s b1" \
  "$(cat "$AGENT_BUS_HOME/msg/$(jq -r --arg id "$nw" 'select(.kind == "msg" and .re == $id) | .id' "$L" | head -1).md" | tr 'R' 'r')"
f="$AGENT_BUS_HOME/seats/$(printf '%s' "$B1" | tr '/' '_').json"
jq -c '.activity = "working"' "$f" >"$f.t" && mv "$f.t" "$f"
nw2=$(pm post --to "$B1" --state question -m "# after a resume" | idof)
jq -c --arg id "$nw2" 'if .id == $id then .epoch -= 700 else . end' "$L" >"$L.t" && mv "$L.t" "$L"
out=$(R "${SON[@]}" "$BIN" watch --here)
assert_lacks "once it works again it is no longer retired" "for $nw2: retired" "$out"

# --- the resume wake never holds a pass ---
printf '#!/bin/sh\necho "$*" >>"%s/oc.log"\nsleep 30\n' "$T" >"$T/bin/opencode"; chmod +x "$T/bin/opencode"
jq -c '.terminals |= map(select(.address != "t8"))' "$T/hc.json" >"$T/hc.t" && mv "$T/hc.t" "$T/hc.json"
B8=$(addr b8 w8)
nw3=$(pm post --to "$B8" --state question -m "# resume me" | idof)
jq -c --arg id "$nw3" 'if .id == $id then .epoch -= 700 else . end' "$L" >"$L.t" && mv "$L.t" "$L"
t0=$(date +%s)
out=$(R "${SON[@]}" AGENT_BUS_OPENCODE_BIN="$T/bin/opencode" "$BIN" watch --here)
t1=$(date +%s)
assert_has "an OpenCode seat with no terminal is resumed" "wake $B8 for $nw3: resumed" "$out"
assert_eq "and the pass does not wait for the resumed turn" yes "$( (( t1 - t0 < 15 )) && echo yes || echo "no ($((t1 - t0))s)")"
sleep 1; assert_has "the resumed run got the packet" "$nw3" "$(cat "$T/oc.log" 2>/dev/null)"
pkill -f "$T/bin/opencode" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
