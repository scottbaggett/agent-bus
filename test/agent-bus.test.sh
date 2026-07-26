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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
