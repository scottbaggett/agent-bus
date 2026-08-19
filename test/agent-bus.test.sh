#!/usr/bin/env bash
# Smoke tests for agent-bus addressing, PM auto-CC, claims, and release ownership.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agent-bus"
pass=0 fail=0

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local name="$1" needle="$2" hay="$3"
  if grep -Fq -- "$needle" <<<"$hay"; then
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n  missing: %s\n  in: %s\n' "$name" "$needle" "$hay"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2" hay="$3"
  if grep -Fq -- "$needle" <<<"$hay"; then
    printf 'FAIL %s\n  unexpectedly found: %s\n' "$name" "$needle"
    fail=$((fail + 1))
  else
    printf 'ok   %s\n' "$name"
    pass=$((pass + 1))
  fi
}

BUS_HOME=$(mktemp -d)
trap 'rm -rf "$BUS_HOME"' EXIT
export AGENT_BUS_HOME="$BUS_HOME"
# Isolate from live sessions: without these, fixture seats inherit the invoking
# session's inbox socket and every test post pokes the real Claude session that
# ran the suite. Belt and suspenders: no pokes, and no socket to record.
export AGENT_BUS_NO_PUSH=1
# Opportunistic gc off by default so fixtures stay deterministic; the PM
# hygiene section re-enables it explicitly.
export AGENT_BUS_NO_AUTO_GC=1
unset CLAUDE_CODE_MESSAGING_SOCKET

# --- identity ---
out=$("$BIN" whoami)
assert_contains "whoami has repo_id" "repo_id" "$out"
REPO_ID=$(printf '%s\n' "$out" | awk '/^repo_id/{print $2}')

# --- self-post is never unread ---
"$BIN" post --to @here --state fyi -m $'# self\n\nbody' >/dev/null
out=$("$BIN" read --peek)
assert_contains "own posts hidden" "nothing unread" "$out"

# --- @here delivery across tools, same worktree ---
id=$("$BIN" post --to @here --state needs-review -m $'# review me\n\n## Left\n- look' | awk -F= '/id=/{print $2}')
out=$(AGENT_BUS_TOOL=codex "$BIN" read --peek)
assert_contains "codex sees @here needs-review" "review me" "$out"
assert_contains "codex sees packet id" "$id" "$out"

# --- PM auto-CC across worktrees ---
# Pin distinct worktrees so @here cannot reach the PM; only auto-CC should.
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" role pm >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=worker \
  "$BIN" post --to @here --state blocked -m $'# stuck\n\nwaiting' >/dev/null
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read --peek)
assert_contains "PM auto-CC blocked" "stuck" "$out"

# fyi must NOT auto-CC (and @here cannot reach a different worktree)
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=worker \
  "$BIN" post --to @here --state fyi -m $'# chatter\n\nhi' >/dev/null
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read --peek)
assert_not_contains "PM skips fyi auto-CC" "chatter" "$out"

# --- worktree-scoped PM ---
# codex/wt-pm-seat supervises only worktree wt-a; supervisory traffic from
# wt-b must not reach it, and the repo PM (cursor/pm-seat) still sees both.
AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" role pm --wt wt-a >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" role --wt wt-a)
assert_contains "wt PM registered" "codex/wt-pm-seat" "$out"
out=$("$BIN" role)
assert_contains "role status lists wt PM" "wt:wt-a: codex/wt-pm-seat" "$out"
out=$("$BIN" who)
assert_contains "who lists wt PM" "codex/wt-pm-seat -> wt:wt-a" "$out"

# Live takeover of a wt PM needs --force, same as the repo PM.
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=usurper "$BIN" role pm --wt wt-a 2>&1 || true)
assert_contains "live wt PM takeover needs --force" "retry with --force" "$out"

AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-a \
  "$BIN" post --to @here --state blocked -m $'# wt-a stuck\n\nhelp' >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-b \
  "$BIN" post --to @here --state blocked -m $'# wt-b stuck\n\nhelp' >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" read --peek)
assert_contains "wt PM auto-CC from scoped worktree" "wt-a stuck" "$out"
assert_not_contains "wt PM skips other worktrees" "wt-b stuck" "$out"
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read --peek)
assert_contains "repo PM still sees scoped worktree traffic" "wt-a stuck" "$out"
assert_contains "repo PM still sees other worktree traffic" "wt-b stuck" "$out"

# @pm from the scoped worktree reaches the wt PM; from elsewhere it does not.
AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" read >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-a \
  "$BIN" post --to @pm --state fyi -m $'# for-wt-pm\n\nfyi' >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-b \
  "$BIN" post --to @pm --state fyi -m $'# for-repo-pm\n\nfyi' >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" read --peek)
assert_contains "@pm from scoped wt reaches wt PM" "for-wt-pm" "$out"
assert_not_contains "@pm from other wt skips wt PM" "for-repo-pm" "$out"
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read --peek)
assert_contains "@pm still reaches repo PM" "for-repo-pm" "$out"

# Resolve standing: a wt PM covers only its scoped worktree's packets.
rid=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-b "$BIN" post --to claude/wt-b-peer \
  --state question -m $'# wt-b q\n\nwhy?' | awk -F= '/id=/{print $2}')
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" resolve "$rid" 2>&1 || true)
assert_contains "wt PM cannot resolve unscoped packet" "skipped" "$out"
rid=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-a "$BIN" post --to claude/wt-a-peer \
  --state question -m $'# wt-a q\n\nwhy?' | awk -F= '/id=/{print $2}')
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" resolve "$rid" 2>&1)
assert_contains "wt PM can resolve scoped packet" "resolved $rid" "$out"

# Clear releases only that worktree's role.
AGENT_BUS_TOOL=codex AGENT_BUS_WT=wt-pm-seat "$BIN" role --wt wt-a --clear >/dev/null
out=$("$BIN" role --wt wt-a)
assert_contains "wt PM cleared" "no PM registered" "$out"
out=$("$BIN" role)
assert_contains "repo PM survives wt PM clear" "cursor/pm-seat" "$out"
# Ack leftover @pm mail so later assertions start clean.
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read >/dev/null

# --- named role aliases ---
AGENT_BUS_TOOL=claude AGENT_BUS_WT=research-wt "$BIN" role research >/dev/null
out=$("$BIN" role)
assert_contains "role lists named alias" "@research: claude/research-wt" "$out"
out=$("$BIN" who)
assert_contains "who shows named alias" "@research" "$out"
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=research-wt "$BIN" whoami)
assert_contains "whoami shows held names" "@research" "$out"

# Invalid and reserved names are refused at registration.
out=$("$BIN" role Bad_Name 2>&1 || true)
assert_contains "invalid name refused" "invalid role name" "$out"
out=$("$BIN" role here 2>&1 || true)
assert_contains "reserved name refused" "invalid role name" "$out"

# Targeted delivery: only the holder receives @research.
id=$(AGENT_BUS_TOOL=codex "$BIN" post --to @research --state handoff \
  -m $'# research task\n\ndig in' | awk -F= '/id=/{print $2}')
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=research-wt "$BIN" read --peek)
assert_contains "name holder receives @research" "research task" "$out"
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=elsewhere "$BIN" read --peek 2>&1)
assert_not_contains "non-holder does not receive @research" "research task" "$out"

# The holder is an addressee, so it has resolve standing.
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=research-wt "$BIN" resolve "$id" 2>&1)
assert_contains "name holder can resolve @research packet" "resolved $id" "$out"

# Unregistered names are refused at post time; tool scopes still pass —
# builtins always, custom tools once a seat exists.
out=$(AGENT_BUS_TOOL=codex "$BIN" post --to @nosuch --state fyi -m hi 2>&1 || true)
assert_contains "unregistered name refused" "nothing answers to @nosuch" "$out"
out=$(AGENT_BUS_TOOL=codex "$BIN" post --to @claude --state fyi -m $'# builtin tool ok\n\nhi' 2>&1)
assert_contains "builtin tool scope still postable" "posted" "$out"
AGENT_BUS_TOOL=mytool AGENT_BUS_WT=custom "$BIN" heartbeat
out=$(AGENT_BUS_TOOL=codex "$BIN" post --to @mytool --state fyi -m $'# custom tool ok\n\nhi' 2>&1)
assert_contains "custom tool scope postable once seated" "posted" "$out"

# Live takeover requires --force; clear releases and post is refused again.
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=impostor "$BIN" role research 2>&1 || true)
assert_contains "live name takeover needs --force" "retry with --force" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=impostor "$BIN" role research --force 2>&1)
assert_contains "forced name takeover succeeds" "took over from claude/research-wt" "$out"
AGENT_BUS_TOOL=codex AGENT_BUS_WT=impostor "$BIN" role research --clear >/dev/null
out=$("$BIN" role)
assert_not_contains "cleared name gone from role listing" "@research" "$out"
out=$(AGENT_BUS_TOOL=codex "$BIN" post --to @research --state fyi -m hi 2>&1 || true)
assert_contains "post to cleared name refused" "nothing answers" "$out"

# --- claims: contest + release ownership ---
"$BIN" claim README.md >/dev/null
out=$(AGENT_BUS_TOOL=codex "$BIN" claim README.md 2>&1 || true)
assert_contains "contested claim warns" "CONTESTED" "$out"

out=$(AGENT_BUS_TOOL=codex "$BIN" release README.md 2>&1 || true)
assert_contains "foreign release refused" "not releasing" "$out"
out=$("$BIN" claims)
assert_contains "claim still held after foreign release" "README.md" "$out"

"$BIN" release README.md >/dev/null
out=$("$BIN" claims)
assert_contains "owner can release" "no active claims" "$out"

# --- resolve closes for everyone ---
rid=$("$BIN" post --to @repo --state question -m $'# q\n\nwhy?' | awk -F= '/id=/{print $2}')
AGENT_BUS_TOOL=codex "$BIN" resolve "$rid" >/dev/null
out=$(AGENT_BUS_TOOL=codex "$BIN" read --peek)
assert_not_contains "resolved packet hidden" "$rid" "$out"

# --- gc runs ---
out=$("$BIN" gc)
assert_contains "gc reports counts" "gc: removed" "$out"

# --- cursor hook wrapper emits JSON ---
HOOK="$ROOT/bin/agent-bus-cursor-hook"
chmod +x "$HOOK"
out=$(printf '{}' | AGENT_BUS_HOME="$BUS_HOME" "$HOOK" sessionStart)
assert_contains "cursor hook JSON object" "{" "$out"
echo "$out" | jq -e 'type == "object"' >/dev/null
assert_eq "cursor hook valid json" "0" "$?"

# --- watch / stop-hook wake ---
out=$("$BIN" watch)
assert_contains "watch defaults off" "watch off" "$out"

# Supervisory unread while watch off → no wake
AGENT_BUS_TOOL=claude "$BIN" post --to @here --state needs-review \
  -m $'# wake-target\n\nplease review' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex "$BIN" stop-hook)
assert_eq "stop-hook idle when watch off" "{}" "$(echo "$out" | jq -c .)"

AGENT_BUS_TOOL=codex "$BIN" watch on >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex "$BIN" stop-hook)
dec=$(echo "$out" | jq -r '.decision // empty')
assert_eq "stop-hook blocks when watch on" "block" "$dec"
assert_contains "stop-hook reason has subject" "wake-target" "$(echo "$out" | jq -r '.reason')"

# Ack so fyi test starts clean
AGENT_BUS_TOOL=codex "$BIN" read >/dev/null

# fyi alone must not wake
AGENT_BUS_TOOL=claude "$BIN" post --to @here --state fyi -m $'# chatter-only\n\nhi' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex "$BIN" stop-hook)
assert_eq "stop-hook ignores fyi" "{}" "$(echo "$out" | jq -c .)"

# MAX_SHOWS cap: after three surfacings, further stop-hook is {}
# Use @repo so a different worktree seat receives the packet.
export AGENT_BUS_MAX_SHOWS=3
AGENT_BUS_TOOL=claude "$BIN" post --to @repo --state question \
  -m $'# cap-me\n\nwhy?' >/dev/null
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-cap "$BIN" watch on >/dev/null
for i in 1 2 3; do
  out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-cap AGENT_BUS_MAX_SHOWS=3 \
    "$BIN" stop-hook)
  assert_eq "stop-hook surfacing $i blocks" "block" "$(echo "$out" | jq -r '.decision // empty')"
done
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-cap AGENT_BUS_MAX_SHOWS=3 \
  "$BIN" stop-hook)
assert_eq "stop-hook silent after MAX_SHOWS" "{}" "$(echo "$out" | jq -c .)"

# Cursor stop adapter maps block → followup_message
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-map "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=claude "$BIN" post --to @cursor --state handoff \
  -m $'# cursor-wake\n\ntake it' >/dev/null
out=$(printf '{}' | AGENT_BUS_HOME="$BUS_HOME" AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-map \
  "$HOOK" stop)
assert_contains "cursor stop followup_message" "cursor-wake" \
  "$(echo "$out" | jq -r '.followup_message // empty')"

# --- BLOCKER 1: per-seat wake budget across distinct packets ---
export AGENT_BUS_WAKE_BUDGET=2
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=claude "$BIN" post --to @repo --state question -m $'# wb1\n\none' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget 1/2 blocks" "block" "$(echo "$out" | jq -r '.decision // empty')"
AGENT_BUS_TOOL=claude "$BIN" post --to @repo --state question -m $'# wb2\n\ntwo' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget 2/2 blocks" "block" "$(echo "$out" | jq -r '.decision // empty')"
AGENT_BUS_TOOL=claude "$BIN" post --to @repo --state question -m $'# wb3\n\nthree' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget exhausted ignores new packet" "{}" "$(echo "$out" | jq -c .)"

# read must NOT reset — well-behaved ping-pong would otherwise be unbounded
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget "$BIN" read >/dev/null
AGENT_BUS_TOOL=claude "$BIN" post --to @repo --state question -m $'# wb4\n\nfour' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget NOT reset by read" "{}" "$(echo "$out" | jq -c .)"

# watch off/on must NOT bypass
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget "$BIN" watch off >/dev/null
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget "$BIN" watch on >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget NOT reset by watch toggle" "{}" "$(echo "$out" | jq -c .)"

# exhaustion visible with pending
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 "$BIN" watch)
assert_contains "watch status shows EXHAUSTED" "EXHAUSTED" "$out"
assert_contains "watch status shows pending" "pending" "$out"
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 "$BIN" doctor)
assert_contains "doctor flags wake exhaustion" "wake budget exhausted" "$out"

# resolve resets budget
rid=$(jq -r 'select(.kind=="msg") | .id' "$BUS_HOME/ledger.jsonl" | tail -1)
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget "$BIN" resolve "$rid" >/dev/null
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 "$BIN" watch)
assert_contains "resolve resets wake budget" "wake 0/2" "$out"
AGENT_BUS_TOOL=claude "$BIN" post --to @repo --state blocked -m $'# wb5\n\nfive' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake works again after resolve" "block" "$(echo "$out" | jq -r '.decision // empty')"

# Simulated well-behaved ping-pong: wake + read + reply, no resolve → exhausts
export AGENT_BUS_WAKE_BUDGET=2
AGENT_BUS_TOOL=codex AGENT_BUS_WT=pong-a "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pong-b "$BIN" watch on >/dev/null
for round in 1 2; do
  AGENT_BUS_TOOL=claude AGENT_BUS_WT=pong-b \
    "$BIN" post --to @repo --state question -m $'# pong-'$round$'\n\nping' >/dev/null
  out=$(printf '{}' | AGENT_BUS_TOOL=codex AGENT_BUS_WT=pong-a AGENT_BUS_WAKE_BUDGET=2 \
    "$BIN" stop-hook)
  assert_eq "ping-pong round $round wakes" "block" "$(echo "$out" | jq -r '.decision // empty')"
  AGENT_BUS_TOOL=codex AGENT_BUS_WT=pong-a "$BIN" read >/dev/null
done
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pong-b \
  "$BIN" post --to @repo --state question -m $'# pong-3\n\nping' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex AGENT_BUS_WT=pong-a AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "ping-pong exhausts despite read" "{}" "$(echo "$out" | jq -c .)"
unset AGENT_BUS_WAKE_BUDGET

# --- BLOCKER 2: legacy claim key still contests / releases ---
REPO_NAME=$(awk '/^repo /{print $2}' <<<"$("$BIN" whoami)")
legacy_key=$(printf '%s' "$REPO_NAME:LEGACY.md" | shasum -a 256 | cut -c1-16)
jq -n -c --arg addr "codex/other" --arg repo "$REPO_NAME" --arg path "LEGACY.md" \
  --argjson epoch "$(date -u +%s)" \
  '{addr:$addr,repo:$repo,path:$path,branch:"main",epoch:$epoch}' \
  >"$BUS_HOME/claims/$legacy_key.json"
out=$(AGENT_BUS_TOOL=claude "$BIN" claim LEGACY.md 2>&1 || true)
assert_contains "legacy claim contested" "CONTESTED" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=other "$BIN" release LEGACY.md 2>&1)
assert_contains "legacy holder can release" "released LEGACY.md" "$out"
out=$("$BIN" claims)
assert_contains "legacy claim cleared" "no active claims" "$out"

# Dual-key hazard: foreign on legacy + self on new must still contest
legacy_key=$(printf '%s' "$REPO_NAME:DUAL.md" | shasum -a 256 | cut -c1-16)
jq -n -c --arg addr "codex/other" --arg repo "$REPO_NAME" --arg path "DUAL.md" \
  --argjson epoch "$(date -u +%s)" \
  '{addr:$addr,repo:$repo,path:$path,branch:"main",epoch:$epoch}' \
  >"$BUS_HOME/claims/$legacy_key.json"
AGENT_BUS_TOOL=claude "$BIN" claim DUAL.md >/dev/null 2>&1 || true
# If claim succeeded despite legacy, that is the bug — force dual by writing new too
# After fix, claim should have been CONTESTED; verify foreign still wins:
out=$(AGENT_BUS_TOOL=claude "$BIN" claim DUAL.md 2>&1 || true)
assert_contains "dual-key still contested" "CONTESTED" "$out"
AGENT_BUS_TOOL=codex AGENT_BUS_WT=other "$BIN" release DUAL.md >/dev/null

# --- BLOCKER 3: role status migrates legacy PM file ---
REPO_SLUG=$(printf '%s' "$REPO_NAME" | tr '/:@ ' '____')
rm -f "$BUS_HOME/state/roles/"*.pm
printf 'claude/main' >"$BUS_HOME/state/roles/${REPO_SLUG}.pm"
out=$("$BIN" role)
assert_contains "role status migrates legacy PM" "PM for $REPO_NAME: claude/main" "$out"
# Migration should have written the repo_id file
REPO_ID=$(awk '/^repo_id/{print $2}' <<<"$("$BIN" whoami)")
[ -f "$BUS_HOME/state/roles/${REPO_ID}.pm" ]
assert_eq "legacy PM migrated to repo_id file" "0" "$?"

# --- wait + stop-hook shapes (isolated bus home; the shared ledger above would
#     bleed earlier supervisory packets into these seats) ---
WAIT_HOME=$(mktemp -d)
SAVED_HOME="$AGENT_BUS_HOME"
export AGENT_BUS_HOME="$WAIT_HOME"

# Timeout path returns with a re-arm hint and no packets.
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=waiter "$BIN" wait --timeout 1 --interval 1 2>&1)
assert_contains "wait times out with re-arm hint" "Re-arm: agent-bus wait" "$out"
assert_not_contains "wait timeout surfaces no packet" "packet(s) waiting" "$out"

# Arrival path: a supervisory packet posted mid-wait is surfaced and wait returns.
( sleep 1; AGENT_BUS_TOOL=claude AGENT_BUS_WT=poster "$BIN" post \
    --to codex/waiter --state needs-review -m "wake the waiter" >/dev/null 2>&1 ) &
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=waiter "$BIN" wait --timeout 10 --interval 1 2>&1)
wait
assert_contains "wait returns on supervisory arrival" "packet(s) waiting for codex/waiter" "$out"
assert_contains "wait surfaces the packet subject" "wake the waiter" "$out"

# --any surfaces a non-supervisory packet; supervisory-only wait skips it.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=poster "$BIN" post \
  --to codex/quiet --state fyi -m "just an fyi" >/dev/null 2>&1
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=quiet "$BIN" wait --any --timeout 1 --interval 1 2>&1)
assert_contains "wait --any surfaces fyi" "just an fyi" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=quiet "$BIN" wait --timeout 1 --interval 1 2>&1)
assert_not_contains "supervisory wait skips fyi" "packet(s) waiting" "$out"

# codex Stop-hook continuation carries the `prompt` field codex requires;
# claude's does not (jq without -e prints a single true/false line).
AGENT_BUS_TOOL=claude AGENT_BUS_WT=poster "$BIN" post \
  --to codex/stoptest --state needs-review -m "continue me" >/dev/null 2>&1
AGENT_BUS_TOOL=codex AGENT_BUS_WT=stoptest "$BIN" watch on >/dev/null 2>&1
out=$(echo '{}' | AGENT_BUS_TOOL=codex AGENT_BUS_WT=stoptest "$BIN" stop-hook 2>/dev/null)
assert_eq "codex stop-hook emits prompt for continuation" "true" \
  "$(jq -r 'has("prompt") and .decision=="block"' <<<"$out" 2>/dev/null)"

AGENT_BUS_TOOL=claude AGENT_BUS_WT=poster "$BIN" post \
  --to claude/stoptest --state needs-review -m "continue me" >/dev/null 2>&1
AGENT_BUS_TOOL=claude AGENT_BUS_WT=stoptest "$BIN" watch on >/dev/null 2>&1
out=$(echo '{}' | AGENT_BUS_TOOL=claude AGENT_BUS_WT=stoptest "$BIN" stop-hook 2>/dev/null)
assert_eq "claude stop-hook omits prompt field" "false" \
  "$(jq -r 'has("prompt")' <<<"$out" 2>/dev/null)"

export AGENT_BUS_HOME="$SAVED_HOME"
rm -rf "$WAIT_HOME"

# --- hardening: tolerant ledger, caps, sanitize, id validation, resolve
#     standing, gc rotation, PM --force (fresh bus home for independence) ---
HARD_HOME=$(mktemp -d)
export AGENT_BUS_HOME="$HARD_HOME"

# Tolerant ledger parsing: a garbage line must not break any reader.
echo 'THIS IS NOT JSON {' >>"$HARD_HOME/ledger.jsonl"
id=$(AGENT_BUS_TOOL=codex "$BIN" post --to @here --state needs-review \
  -m $'# after-garbage\n\nstill works' | awk -F= '/id=/{print $2}')
out=$(AGENT_BUS_TOOL=claude "$BIN" read --peek 2>&1)
assert_contains "read survives garbage ledger line" "after-garbage" "$out"
out=$(AGENT_BUS_TOOL=claude "$BIN" log 2>&1)
assert_contains "log survives garbage ledger line" "after-garbage" "$out"
out=$(AGENT_BUS_TOOL=claude "$BIN" doctor 2>&1)
assert_contains "doctor counts unparseable lines" "1 unparseable" "$out"
AGENT_BUS_TOOL=claude "$BIN" read >/dev/null

# Peer-context banner travels in the delivery channel.
assert_contains "read carries peer-context banner" "peer context from other agents" \
  "$(AGENT_BUS_TOOL=codex "$BIN" post --to @claude --state fyi -m $'# banner\n\nhi' >/dev/null; \
     AGENT_BUS_TOOL=claude "$BIN" read --peek)"
AGENT_BUS_TOOL=claude "$BIN" read >/dev/null

# Body cap at post time.
big=$(head -c 70000 /dev/zero | tr '\0' 'a')
out=$(AGENT_BUS_TOOL=codex "$BIN" post --to @here --state fyi -m "$big" 2>&1 || true)
assert_contains "oversized body refused" "max 65536" "$out"

# Inline render cap: >2KB body is truncated with a show hint.
long="$(printf '# big\n\n')$(head -c 4000 /dev/zero | tr '\0' 'b')"
AGENT_BUS_TOOL=codex "$BIN" post --to @claude --state fyi -m "$long" >/dev/null
out=$(AGENT_BUS_TOOL=claude "$BIN" read --peek)
assert_contains "inline body truncated" "truncated — agent-bus show" "$out"
AGENT_BUS_TOOL=claude "$BIN" read >/dev/null

# Control characters are stripped at render time (body and subject).
esc="$(printf '# esc\n\nred \033[31mtext\033[0m and \007bell')"
AGENT_BUS_TOOL=codex "$BIN" post --to @claude --state fyi -m "$esc" >/dev/null
out=$(AGENT_BUS_TOOL=claude "$BIN" read --peek)
assert_not_contains "ESC stripped from read output" "$(printf '\033')" "$out"
assert_not_contains "BEL stripped from read output" "$(printf '\007')" "$out"
assert_contains "markdown body survives sanitize" "red" "$out"
AGENT_BUS_TOOL=claude "$BIN" read >/dev/null

# Id validation: traversal ids never become paths.
out=$("$BIN" show "../../etc/hosts" 2>&1 || true)
assert_contains "show rejects traversal id" "not a packet id" "$out"
out=$(AGENT_BUS_TOOL=codex "$BIN" post --re "not-an-id" --to @here --state fyi -m hi 2>&1 || true)
assert_contains "--re rejects malformed id" "--re expects a packet id" "$out"

# A crafted ledger row must not read arbitrary files into a digest.
printf 'TOPSECRET\n' >"$HARD_HOME/secret.md"
RID=$(awk '/^repo_id/{print $2}' <<<"$(AGENT_BUS_TOOL=claude "$BIN" whoami)")
RWT=$(awk '/^worktree/{print $2}' <<<"$(AGENT_BUS_TOOL=claude "$BIN" whoami)")
jq -n -c --arg rid "$RID" --arg wt "$RWT" --argjson epoch "$(date -u +%s)" \
  '{kind:"msg",id:"../secret",ts:"now",epoch:$epoch,from:"codex/evil",session:"x",
    to:"@here",state:"needs-review",repo:"agent-bus",repo_id:$rid,wt:$wt,branch:"main",
    cwd:"/",subject:"crafted",touched:[],re:null}' >>"$HARD_HOME/ledger.jsonl"
out=$(AGENT_BUS_TOOL=claude "$BIN" read --peek 2>&1)
assert_not_contains "crafted id cannot exfiltrate files" "TOPSECRET" "$out"
assert_contains "crafted id flagged" "malformed id" "$out"
AGENT_BUS_TOOL=claude "$BIN" read >/dev/null

# Resolve standing: only sender, addressee, or PM.
rid=$(AGENT_BUS_TOOL=codex "$BIN" post --to claude/"$RWT" --state question \
  -m $'# rq\n\nwhy?' | awk -F= '/id=/{print $2}')
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=elsewhere AGENT_BUS_REPO_ID=deadbeefdeadbeef \
  "$BIN" resolve "$rid" 2>&1 || true)
assert_contains "unrelated seat cannot resolve" "skipped" "$out"
out=$(AGENT_BUS_TOOL=claude "$BIN" resolve "$rid" 2>&1)
assert_contains "addressee can resolve" "resolved $rid" "$out"
out=$(AGENT_BUS_TOOL=claude "$BIN" resolve 20250101T000000Z-aaaaaaaa 2>&1 || true)
assert_contains "resolve of unknown id skipped" "no such packet" "$out"
out=$(AGENT_BUS_TOOL=claude "$BIN" resolve "not/even/an/id" 2>&1 || true)
assert_contains "resolve of malformed id skipped" "not a packet id" "$out"

# Failed resolve must NOT reset the wake budget.
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=budget2 "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=codex "$BIN" post --to cursor/budget2 --state question -m $'# b\n\n?' >/dev/null
printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=budget2 "$BIN" stop-hook >/dev/null
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=budget2 "$BIN" watch)
assert_contains "wake counted before failed resolve" "wake 1/" "$out"
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=budget2 "$BIN" resolve 20250101T000000Z-ffffffff >/dev/null 2>&1 || true
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_WT=budget2 "$BIN" watch)
assert_contains "failed resolve keeps wake budget" "wake 1/" "$out"

# gc: rotate old rows to archive, keep fresh ones, prune dead-seat state.
old_epoch=$(( $(date -u +%s) - 20 * 86400 ))
jq -n -c --argjson epoch "$old_epoch" \
  '{kind:"msg",id:"20250101T000000Z-01234567",epoch:$epoch,from:"x/y",to:"@here",
    state:"fyi",subject:"ancient",repo:"r",repo_id:"i",wt:"w",branch:"b"}' \
  >>"$HARD_HOME/ledger.jsonl"
printf '{}' >"$HARD_HOME/state/ghost_seat.json"
touch -t 202501010000 "$HARD_HOME/state/ghost_seat.json"
out=$("$BIN" gc)
assert_contains "gc rotates old ledger rows" "rotated 1 ledger rows" "$out"
assert_not_contains "old row gone from ledger" "01234567" "$(cat "$HARD_HOME/ledger.jsonl")"
assert_contains "old row archived" "01234567" "$(cat "$HARD_HOME/ledger.archive.jsonl")"
assert_contains "fresh rows survive rotation" "$rid" "$(cat "$HARD_HOME/ledger.jsonl")"
assert_contains "unparseable line survives rotation" "THIS IS NOT JSON" "$(cat "$HARD_HOME/ledger.jsonl")"
[ ! -f "$HARD_HOME/state/ghost_seat.json" ]
assert_eq "dead-seat state pruned" "0" "$?"

# PM takeover of a live holder requires --force.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pmhold "$BIN" role pm >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=usurper "$BIN" role pm 2>&1 || true)
assert_contains "live PM takeover needs --force" "retry with --force" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=usurper "$BIN" role pm --force 2>&1)
assert_contains "forced takeover succeeds" "took over from claude/pmhold" "$out"

export AGENT_BUS_HOME="$SAVED_HOME"
rm -rf "$HARD_HOME"

# --- PM hygiene: triage, doctor staleness, stop-hook nag, opportunistic gc ---
HYG_HOME=$(mktemp -d)
export AGENT_BUS_HOME="$HYG_HOME"

out=$("$BIN" triage)
assert_contains "triage empty when nothing unresolved" "no unresolved supervisory packets" "$out"

HRID=$(awk '/^repo_id/{print $2}' <<<"$("$BIN" whoami)")
HREPO=$(awk '/^repo /{print $2}' <<<"$("$BIN" whoami)")
stale_row() { # args: id wt — a supervisory packet 2 days old
  jq -n -c --arg id "$1" --arg wt "$2" --arg repo "$HREPO" --arg rid "$HRID" \
    --argjson epoch "$(( $(date -u +%s) - 2 * 86400 ))" \
    '{kind:"msg",id:$id,ts:"x",epoch:$epoch,from:("codex/" + $wt),session:"s",
      to:"@repo",state:"needs-review",repo:$repo,repo_id:$rid,wt:$wt,branch:"b",
      cwd:"/",subject:"old review","touched":[],re:null}' >>"$HYG_HOME/ledger.jsonl"
}
stale_row 20260101T000000Z-0000aaaa lane-a
AGENT_BUS_TOOL=claude AGENT_BUS_WT=lane-b "$BIN" post --to @repo --state question \
  -m $'# fresh q\n\nwhy?' >/dev/null

out=$("$BIN" triage)
assert_contains "triage counts stale" "(1 stale, unresolved > 24h)" "$out"
assert_contains "triage groups by worktree" "worktree lane-a:" "$out"
assert_contains "triage flags the stale packet" "STALE" "$out"
assert_contains "triage lists fresh packets too" "fresh q" "$out"
assert_contains "triage states the no-auto-resolve rule" "PM decision" "$out"
assert_eq "only the old packet is flagged STALE" "1" "$(grep -c 'STALE' <<<"$out" || true)"

out=$("$BIN" doctor)
assert_contains "doctor warns on stale supervisory" "stale supervisory packets (unresolved > 24h): 1" "$out"
assert_contains "doctor points at triage" "agent-bus triage" "$out"

# PM stop-hook reminder: compact systemMessage, never a block, rate-limited.
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=hygiene-pm "$BIN" role pm >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=hygiene-pm "$BIN" stop-hook)
assert_contains "PM stop-hook nags on stale threads" "run: agent-bus triage" \
  "$(jq -r '.systemMessage // empty' <<<"$out")"
assert_eq "nag never blocks the stop" "" "$(jq -r '.decision // empty' <<<"$out")"
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=hygiene-pm "$BIN" stop-hook)
assert_eq "nag is rate-limited per seat" "{}" "$(jq -c . <<<"$out")"
out=$(printf '{}' | AGENT_BUS_TOOL=codex AGENT_BUS_WT=bystander "$BIN" stop-hook)
assert_eq "non-PM seat is never nagged" "{}" "$(jq -c . <<<"$out")"

# A worktree PM is nagged only about its own scope.
stale_row 20260101T000000Z-0000bbbb lane-a
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-sup "$BIN" role pm --wt lane-b >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-sup "$BIN" stop-hook)
assert_eq "wt PM not nagged for other worktrees" "{}" "$(jq -c . <<<"$out")"
stale_row 20260101T000000Z-0000cccc lane-b
out=$(printf '{}' | AGENT_BUS_TOOL=claude AGENT_BUS_WT=wt-sup "$BIN" stop-hook)
assert_contains "wt PM nagged for its scoped worktree" "agent-bus triage" \
  "$(jq -r '.systemMessage // empty' <<<"$out")"

# resolve — and only resolve — clears a thread out of triage.
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=hygiene-pm "$BIN" resolve \
  20260101T000000Z-0000aaaa 20260101T000000Z-0000bbbb 20260101T000000Z-0000cccc >/dev/null
out=$("$BIN" triage)
assert_not_contains "resolved threads leave triage" "old review" "$out"
assert_contains "unresolved fresh packet remains" "fresh q" "$out"

# Opportunistic gc: a hook entry point prunes an expired claim once per
# interval; a second run inside the interval is a no-op.
expired_claim() { # args: filename
  jq -n -c --arg repo "$HREPO" --arg rid "$HRID" \
    --argjson epoch "$(( $(date -u +%s) - 100000 ))" \
    '{addr:"x/y",repo:$repo,repo_id:$rid,path:"GONE.md",branch:"b",epoch:$epoch}' \
    >"$HYG_HOME/claims/$1"
}
expired_claim expired1.json
AGENT_BUS_NO_AUTO_GC=0 AGENT_BUS_TOOL=codex "$BIN" heartbeat
[ ! -f "$HYG_HOME/claims/expired1.json" ]
assert_eq "auto-gc pruned expired claim via heartbeat" "0" "$?"
[ -f "$HYG_HOME/.last-gc" ]
assert_eq "auto-gc marker written" "0" "$?"
expired_claim expired2.json
AGENT_BUS_NO_AUTO_GC=0 AGENT_BUS_TOOL=codex "$BIN" heartbeat
[ -f "$HYG_HOME/claims/expired2.json" ]
assert_eq "auto-gc rate-limited within the interval" "0" "$?"

export AGENT_BUS_HOME="$SAVED_HOME"
rm -rf "$HYG_HOME"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
