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
# Identity isolation: the suite may run inside Claude Code / Codex / OpenCode,
# whose markers and session ids would otherwise leak into every fixture seat —
# one shared session id would make sender exclusion hide every fixture post.
# Fixtures pin identity explicitly via AGENT_BUS_TOOL / AGENT_BUS_SESSION.
unset CLAUDECODE CLAUDE_CODE_SESSION_ID \
  CODEX_SHELL CODEX_SANDBOX CODEX_APP_TITLE CODEX_SESSION_ID CODEX_THREAD_ID \
  CURSOR_TRACE_ID CURSOR_AGENT CURSOR_CONVERSATION_ID \
  OPENCODE OPENCODE_SESSION_ID OPENCODE_SESSION_TITLE \
  AGENT_BUS_SESSION AGENT_BUS_TOOL

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

# --- claims: flag-shaped arguments are not paths ---
# `agent-bus claim --all` once stored a claim on a file literally named "--all",
# which showed in `who` as a real hold and needed hand-editing to clear.
out=$("$BIN" claim --all 2>&1 || true)
assert_contains "claim rejects a flag as a path" "looks like a flag" "$out"
out=$("$BIN" claims)
assert_contains "no claim recorded for the flag" "no active claims" "$out"
out=$("$BIN" claim -x 2>&1 || true)
assert_contains "claim rejects any leading dash" "looks like a flag" "$out"
out=$("$BIN" release --force -x 2>&1 || true)
assert_contains "release rejects a flag as a path" "looks like a flag" "$out"

# --- claims: --force breaks a live foreign claim ---
# A seat can die without releasing (crashed host, plugin that stopped loading);
# its claims otherwise block the path until CLAIM_TTL with no CLI way out.
AGENT_BUS_TOOL=codex AGENT_BUS_SESSION=holder "$BIN" claim README.md >/dev/null
out=$("$BIN" release README.md 2>&1 || true)
assert_contains "foreign release names the force escape" "release --force README.md" "$out"
out=$("$BIN" claims)
assert_contains "claim survives an unforced release" "README.md" "$out"
out=$("$BIN" release --force README.md 2>&1)
assert_contains "force break announces itself" "BROKE claim on README.md" "$out"
assert_contains "force break names the holder" "codex/" "$out"
out=$("$BIN" claims)
assert_contains "claim gone after force" "no active claims" "$out"
# The break is auditable, not silent.
out=$(grep -c '"kind":"claim-break"' "$BUS_HOME/ledger.jsonl" || true)
assert_eq "force break is recorded in the ledger" "1" "$out"
# --force never means "everything".
out=$("$BIN" release --force 2>&1 || true)
assert_contains "force requires explicit paths" "needs one or more paths" "$out"
# A path nobody holds is still a plain release.
out=$("$BIN" release --force PROTOCOL.md 2>&1)
assert_contains "force on an unheld path is a no-op" "not held" "$out"

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
AGENT_BUS_TOOL=claude "$BIN" post --to @codex --state needs-review \
  -m $'# wake-target\n\nplease review' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex "$BIN" stop-hook)
assert_eq "stop-hook idle when watch off" "{}" "$(echo "$out" | jq -c .)"

# Watch on, but the packet is a broadcast (@codex): the seat sees it as digest
# context, yet is NOT woken — supervisory wake belongs to the packet's owner.
AGENT_BUS_TOOL=codex "$BIN" watch on >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex "$BIN" stop-hook)
assert_eq "broadcast supervisory does not wake bystander" "{}" "$(echo "$out" | jq -c .)"
out=$(AGENT_BUS_TOOL=codex "$BIN" read --peek)
assert_contains "bystander still sees broadcast in digest" "wake-target" "$out"
assert_contains "bystander copy labeled as not theirs" "act only if it names you" "$out"
AGENT_BUS_TOOL=codex "$BIN" read >/dev/null

# Directly addressed supervisory mail does wake.
WAKE_WT=$(awk '/^worktree/{print $2}' <<<"$(AGENT_BUS_TOOL=codex "$BIN" whoami)")
AGENT_BUS_TOOL=claude "$BIN" post --to "codex/$WAKE_WT" --state needs-review \
  -m $'# wake-target-direct\n\nplease review' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex "$BIN" stop-hook)
dec=$(echo "$out" | jq -r '.decision // empty')
assert_eq "stop-hook blocks when watch on" "block" "$dec"
assert_contains "stop-hook reason has subject" "wake-target-direct" "$(echo "$out" | jq -r '.reason')"

# A watching repo PM IS woken by @here supervisory traffic (owner via auto-CC).
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read >/dev/null
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=claude "$BIN" post --to @here --state needs-review \
  -m $'# pm-wake\n\nreview me' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" stop-hook)
assert_eq "@here supervisory wakes the PM" "block" "$(echo "$out" | jq -r '.decision // empty')"
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" read >/dev/null
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=pm-seat "$BIN" watch off >/dev/null

# Ack so fyi test starts clean
AGENT_BUS_TOOL=codex "$BIN" read >/dev/null

# fyi alone must not wake
AGENT_BUS_TOOL=claude "$BIN" post --to @here --state fyi -m $'# chatter-only\n\nhi' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex "$BIN" stop-hook)
assert_eq "stop-hook ignores fyi" "{}" "$(echo "$out" | jq -c .)"

# MAX_SHOWS cap: after three surfacings, further stop-hook is {}
# Use @repo so a different worktree seat receives the packet.
export AGENT_BUS_MAX_SHOWS=3
AGENT_BUS_TOOL=claude "$BIN" post --to cursor/wake-cap --state question \
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
AGENT_BUS_TOOL=claude "$BIN" post --to cursor/wake-map --state handoff \
  -m $'# cursor-wake\n\ntake it' >/dev/null
out=$(printf '{}' | AGENT_BUS_HOME="$BUS_HOME" AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-map \
  "$HOOK" stop)
assert_contains "cursor stop followup_message" "cursor-wake" \
  "$(echo "$out" | jq -r '.followup_message // empty')"

# --- cursor adapter: identity from the workspace, not the hook's cwd ---
# User-level Cursor hooks run from ~/.cursor. Without re-anchoring on the
# workspace the hook resolves to a foreign seat and every wake no-ops.
CURSOR_CWD=$(mktemp -d)
pushd "$ROOT" >/dev/null
CURSOR_WT=$(awk '/^worktree/{print $2}' <<<"$("$BIN" whoami)")
AGENT_BUS_TOOL=cursor "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_SESSION=cur-peer "$BIN" post --to "cursor/$CURSOR_WT" --state question \
  -m $'# cursor-cwd-wake\n\nfrom afar' >/dev/null
out=$(cd "$CURSOR_CWD" && printf '{"conversation_id":"c-1","status":"completed","loop_count":0}' \
  | CURSOR_PROJECT_DIR="$ROOT" AGENT_BUS_HOME="$BUS_HOME" "$HOOK" stop)
assert_contains "cursor stop re-anchors on CURSOR_PROJECT_DIR" "cursor-cwd-wake" \
  "$(echo "$out" | jq -r '.followup_message // empty')"
out=$(cd "$CURSOR_CWD" && printf '{"conversation_id":"c-1","status":"completed","loop_count":0,"workspace_roots":["%s"]}' "$ROOT" \
  | env -u CURSOR_PROJECT_DIR -u CLAUDE_PROJECT_DIR AGENT_BUS_HOME="$BUS_HOME" "$HOOK" stop)
assert_contains "cursor stop re-anchors on workspace_roots" "cursor-cwd-wake" \
  "$(echo "$out" | jq -r '.followup_message // empty')"
# An aborted turn (user pressed stop) is never auto-continued.
out=$(cd "$CURSOR_CWD" && printf '{"conversation_id":"c-1","status":"aborted","loop_count":0}' \
  | CURSOR_PROJECT_DIR="$ROOT" AGENT_BUS_HOME="$BUS_HOME" "$HOOK" stop)
assert_eq "cursor stop ignores aborted turns" "{}" "$(echo "$out" | jq -c .)"
# The hook must not leave a phantom seat named after its own cwd.
out=$("$BIN" who)
assert_not_contains "cursor hook registers no cwd-named seat" "cursor/$(basename "$CURSOR_CWD")" "$out"
AGENT_BUS_TOOL=cursor "$BIN" read >/dev/null
AGENT_BUS_TOOL=cursor "$BIN" watch off >/dev/null

# sessionStart pins identity for later hooks via env.
out=$(cd "$CURSOR_CWD" && printf '{"session_id":"conv-abc","composer_mode":"agent"}' \
  | CURSOR_PROJECT_DIR="$ROOT" AGENT_BUS_HOME="$BUS_HOME" "$HOOK" sessionStart)
assert_eq "cursor sessionStart pins AGENT_BUS_SESSION" "conv-abc" "$(echo "$out" | jq -r '.env.AGENT_BUS_SESSION // empty')"
assert_eq "cursor sessionStart pins AGENT_BUS_TOOL" "cursor" "$(echo "$out" | jq -r '.env.AGENT_BUS_TOOL // empty')"

# --- cursor adapter: scope delegation to the watching instance seat ---
# The agent's shell registered an instance seat (session id) and turned watch
# on there; the stop hook, which cannot see that session, arrives as the bare
# scope seat. It must wake on the instance's behalf.
AGENT_BUS_TOOL=cursor AGENT_BUS_SESSION=cursor-chat-1 "$BIN" watch on >/dev/null
INST=$(awk '/^seat/{print $2}' <<<"$(AGENT_BUS_TOOL=cursor AGENT_BUS_SESSION=cursor-chat-1 "$BIN" whoami)")
AGENT_BUS_TOOL=claude AGENT_BUS_SESSION=cur-peer "$BIN" post --to "$INST" --state needs-review \
  -m $'# delegated-wake\n\nfor the instance' >/dev/null
out=$(cd "$CURSOR_CWD" && printf '{"conversation_id":"unknown-to-shell","status":"completed","loop_count":0}' \
  | CURSOR_PROJECT_DIR="$ROOT" AGENT_BUS_HOME="$BUS_HOME" "$HOOK" stop)
assert_contains "cursor stop delegates to watching instance" "delegated-wake" \
  "$(echo "$out" | jq -r '.followup_message // empty')"
assert_contains "delegated wake names the instance seat" "$INST" \
  "$(echo "$out" | jq -r '.followup_message // empty')"
# Delegation is opt-in: a plain stop-hook for a non-watching seat stays quiet
# even with a watching sibling in scope (Claude/Codex hooks are exact).
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_SESSION=cursor-chat-2 "$BIN" stop-hook)
assert_eq "no delegation without AGENT_BUS_DELEGATE_SCOPE" "{}" "$(echo "$out" | jq -c .)"
# Once the instance turns watch off, the hook has nobody to act for.
AGENT_BUS_TOOL=cursor AGENT_BUS_SESSION=cursor-chat-1 "$BIN" watch off >/dev/null
out=$(cd "$CURSOR_CWD" && printf '{"conversation_id":"unknown-to-shell","status":"completed","loop_count":0}' \
  | CURSOR_PROJECT_DIR="$ROOT" AGENT_BUS_HOME="$BUS_HOME" "$HOOK" stop)
assert_eq "cursor stop quiet when no instance watches" "{}" "$(echo "$out" | jq -c .)"
AGENT_BUS_TOOL=cursor AGENT_BUS_SESSION=cursor-chat-1 "$BIN" read >/dev/null
popd >/dev/null
rm -rf "$CURSOR_CWD"

# --- BLOCKER 1: per-seat wake budget across distinct packets ---
export AGENT_BUS_WAKE_BUDGET=2
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=claude "$BIN" post --to cursor/wake-budget --state question -m $'# wb1\n\none' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget 1/2 blocks" "block" "$(echo "$out" | jq -r '.decision // empty')"
AGENT_BUS_TOOL=claude "$BIN" post --to cursor/wake-budget --state question -m $'# wb2\n\ntwo' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget 2/2 blocks" "block" "$(echo "$out" | jq -r '.decision // empty')"
AGENT_BUS_TOOL=claude "$BIN" post --to cursor/wake-budget --state question -m $'# wb3\n\nthree' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake budget exhausted ignores new packet" "{}" "$(echo "$out" | jq -c .)"

# read must NOT reset — well-behaved ping-pong would otherwise be unbounded
AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget "$BIN" read >/dev/null
AGENT_BUS_TOOL=claude "$BIN" post --to cursor/wake-budget --state question -m $'# wb4\n\nfour' >/dev/null
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
AGENT_BUS_TOOL=claude "$BIN" post --to cursor/wake-budget --state blocked -m $'# wb5\n\nfive' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wake-budget AGENT_BUS_WAKE_BUDGET=2 \
  "$BIN" stop-hook)
assert_eq "wake works again after resolve" "block" "$(echo "$out" | jq -r '.decision // empty')"

# Simulated well-behaved ping-pong: wake + read + reply, no resolve → exhausts
export AGENT_BUS_WAKE_BUDGET=2
AGENT_BUS_TOOL=codex AGENT_BUS_WT=pong-a "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pong-b "$BIN" watch on >/dev/null
for round in 1 2; do
  AGENT_BUS_TOOL=claude AGENT_BUS_WT=pong-b \
    "$BIN" post --to codex/pong-a --state question -m $'# pong-'$round$'\n\nping' >/dev/null
  out=$(printf '{}' | AGENT_BUS_TOOL=codex AGENT_BUS_WT=pong-a AGENT_BUS_WAKE_BUDGET=2 \
    "$BIN" stop-hook)
  assert_eq "ping-pong round $round wakes" "block" "$(echo "$out" | jq -r '.decision // empty')"
  AGENT_BUS_TOOL=codex AGENT_BUS_WT=pong-a "$BIN" read >/dev/null
done
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pong-b \
  "$BIN" post --to codex/pong-a --state question -m $'# pong-3\n\nping' >/dev/null
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
assert_contains "read carries peer-context banner" "from other agents, not your user" \
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

# --- supervisory ownership: post hint + named-role wake ---
# Posting a supervisory state to a broadcast scope prints an ownership note.
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=worker "$BIN" post --to @here \
  --state needs-review -m $'# hinted\n\nreview' 2>&1)
assert_contains "broadcast supervisory post hints at PM ownership" "note: [needs-review] on @here is broadcast context" "$out"
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=worker "$BIN" post --to claude/somewhere \
  --state needs-review -m $'# unhinted\n\nreview' 2>&1)
assert_not_contains "direct supervisory post gets no hint" "owns it" "$out"
AGENT_BUS_TOOL=claude "$BIN" read >/dev/null

# A named-role holder owns supervisory mail addressed to its name: it wakes.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=lane-wt "$BIN" role reviewer >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=lane-wt "$BIN" watch on >/dev/null
AGENT_BUS_TOOL=codex AGENT_BUS_WT=elsewhere "$BIN" post --to @reviewer \
  --state needs-review -m $'# for-reviewer\n\nlook' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=claude AGENT_BUS_WT=lane-wt "$BIN" stop-hook)
assert_eq "named-role supervisory mail wakes the holder" "block" "$(echo "$out" | jq -r '.decision // empty')"
AGENT_BUS_TOOL=claude AGENT_BUS_WT=lane-wt "$BIN" read >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=lane-wt "$BIN" watch off >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=lane-wt "$BIN" role reviewer --clear >/dev/null

# --- instance seats: tool detection, per-session identity, legacy compat ---
INST_HOME=$(mktemp -d)
export AGENT_BUS_HOME="$INST_HOME"

# Tool detection from host session markers (the codex-as-shell collision bug).
out=$(CODEX_SESSION_ID=cs-1 "$BIN" whoami)
assert_contains "CODEX_SESSION_ID detects codex" "seat     codex/" "$out"
out=$(CODEX_THREAD_ID=ct-1 "$BIN" whoami)
assert_contains "CODEX_THREAD_ID detects codex" "seat     codex/" "$out"
out=$(OPENCODE_SESSION_ID=oc-1 "$BIN" whoami)
assert_contains "OPENCODE_SESSION_ID detects opencode" "seat     opencode/" "$out"
out=$(OPENCODE=1 "$BIN" whoami)
assert_contains "OPENCODE marker detects opencode" "seat     opencode/" "$out"

# A session id gives the seat a unique instance suffix; two sessions of the
# same tool in the same worktree must never share an identity.
a=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-a "$BIN" whoami | awk '/^seat/{print $2}')
b=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-b "$BIN" whoami | awk '/^seat/{print $2}')
assert_contains "instance addr carries scope" "codex/shared." "$a"
[ "$a" != "$b" ]
assert_eq "two sessions same tool/wt get distinct seats" "0" "$?"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-a "$BIN" whoami)
assert_contains "whoami shows the bare scope" "scope    codex/shared" "$out"

# The a198 regression: a supervisory @here packet from one instance must be
# unread for the other instance in the same tool/worktree...
AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-a \
  "$BIN" post --to @here --state needs-review -m $'# pm feedback\n\nfix X' >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-b "$BIN" read --peek)
assert_contains "peer instance sees @here supervisory" "pm feedback" "$out"
# ...while true self-posts stay suppressed, both same-seat and same-session.
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-a "$BIN" read --peek)
assert_not_contains "own instance post still hidden" "pm feedback" "$out"
out=$(AGENT_BUS_TOOL=shell AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-a "$BIN" read --peek)
assert_not_contains "same session under another hat is still self" "pm feedback" "$out"

# Bare tool/wt addresses the scope: every instance in it receives.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=elsewhere AGENT_BUS_SESSION=sender-s \
  "$BIN" post --to codex/shared --state fyi -m $'# scoped mail\n\nhello both' >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-a "$BIN" read --peek)
assert_contains "scope post reaches instance a" "scoped mail" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-b "$BIN" read --peek)
assert_contains "scope post reaches instance b" "scoped mail" "$out"

# An exact instance addr reaches only that session.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=elsewhere AGENT_BUS_SESSION=sender-s \
  "$BIN" post --to "$a" --state fyi -m $'# direct mail\n\nonly a' >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-a "$BIN" read --peek)
assert_contains "instance post reaches its session" "direct mail" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=shared AGENT_BUS_SESSION=sess-b "$BIN" read --peek)
assert_not_contains "instance post skips sibling session" "direct mail" "$out"

# Legacy PM registration (bare scope addr) still matches an instance holder:
# supervisory auto-CC keeps flowing across the upgrade without re-registering.
INST_RID=$(awk '/^repo_id/{print $2}' <<<"$("$BIN" whoami)")
mkdir -p "$INST_HOME/state/roles"
printf 'claude/pm-wt' >"$INST_HOME/state/roles/${INST_RID}.pm"
AGENT_BUS_TOOL=codex AGENT_BUS_WT=worker AGENT_BUS_SESSION=w-s \
  "$BIN" post --to @here --state blocked -m $'# legacy pm cc\n\nstuck' >/dev/null
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=pm-wt AGENT_BUS_SESSION=pm-s "$BIN" read --peek)
assert_contains "legacy scope PM registration auto-CCs instance" "legacy pm cc" "$out"
# Re-registering over one's own legacy registration needs no --force.
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=pm-wt AGENT_BUS_SESSION=pm-s "$BIN" role pm 2>&1)
assert_contains "own legacy PM re-registration allowed" "PM for" "$out"
assert_not_contains "own legacy PM re-registration needs no force" "retry with --force" "$out"

# Legacy read cursor: packets read pre-upgrade (state keyed by bare scope)
# stay read for the instance seat.
AGENT_BUS_TOOL=codex AGENT_BUS_WT=worker AGENT_BUS_SESSION=w-s \
  "$BIN" post --to claude/migr --state fyi -m $'# old news\n\nseen already' >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=migr "$BIN" read >/dev/null   # pre-upgrade seat acks
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=migr AGENT_BUS_SESSION=m-s "$BIN" read --peek)
assert_contains "legacy cursor honored by instance seat" "nothing unread" "$out"

# Legacy watch flag: a scope-keyed watch keeps waking the instance seat, and
# instance `watch off` clears the legacy flag too.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wexpat "$BIN" watch on >/dev/null   # pre-upgrade flag
AGENT_BUS_TOOL=codex AGENT_BUS_WT=worker AGENT_BUS_SESSION=w-s \
  "$BIN" post --to claude/wexpat --state needs-review -m $'# legacy wake\n\nlook' >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=claude AGENT_BUS_WT=wexpat AGENT_BUS_SESSION=wx-s "$BIN" stop-hook)
assert_eq "legacy watch flag wakes instance seat" "block" "$(echo "$out" | jq -r '.decision // empty')"
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wexpat AGENT_BUS_SESSION=wx-s "$BIN" watch off >/dev/null
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=wexpat AGENT_BUS_SESSION=wx-s "$BIN" watch)
assert_contains "instance watch off clears legacy flag" "watch off" "$out"

# Legacy claim held under the bare scope: not a rival to its own instance,
# releasable by it, still contested for everyone else.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=cl-wt "$BIN" claim NOTES.md >/dev/null   # pre-upgrade claim
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=cl-wt AGENT_BUS_SESSION=cl-s "$BIN" claim NOTES.md 2>&1)
assert_contains "own legacy claim is not contested" "claimed NOTES.md" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=cl-wt AGENT_BUS_SESSION=rival-s "$BIN" claim NOTES.md 2>&1 || true)
assert_contains "instance claim contests rivals" "CONTESTED" "$out"
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=cl-wt AGENT_BUS_SESSION=cl-s "$BIN" release NOTES.md 2>&1)
assert_contains "instance releases its scope claim" "released NOTES.md" "$out"

# --- review hardening: tolerant who, flag-value guards ---
printf 'NOT JSON' >"$INST_HOME/seats/corrupt.json"
out=$("$BIN" who 2>&1)
assert_contains "who survives corrupt seat file" "seats active" "$out"
out=$("$BIN" post --to 2>&1 || true)
assert_contains "post --to without value dies cleanly" "--to needs a value" "$out"
out=$("$BIN" post --touched 2>&1 || true)
assert_contains "post --touched without value dies cleanly" "--touched needs a value" "$out"
out=$("$BIN" wait --timeout 2>&1 || true)
assert_contains "wait --timeout without value dies cleanly" "--timeout needs a value" "$out"

export AGENT_BUS_HOME="$SAVED_HOME"
rm -rf "$INST_HOME"

# --- opencode: builtin scope, endpoint seat registry, HTTP push wake ---
OC_HOME=$(mktemp -d)
export AGENT_BUS_HOME="$OC_HOME"

out=$(<"$ROOT/plugins/agent-bus/index.ts")
assert_contains "plugin CLI calls use host session identity" "OPENCODE_SESSION_ID: sessionID" "$out"
assert_contains "plugin polls already-idle sessions" "setInterval" "$out"
assert_contains "plugin wakes through injected SDK client" "client.session.promptAsync" "$out"

# --- opencode plugin: loads on both major versions ---
# OpenCode 2 reads the default export's id + setup(); OpenCode 1 calls server().
assert_contains "plugin declares a v2 id" 'id: "agent-bus"' "$out"
assert_contains "plugin exposes a v2 setup" "async setup(ctx" "$out"
assert_contains "plugin keeps the v1 server export" "async function server()" "$out"
assert_contains "plugin default-exports both halves" "export default { ...v2, server }" "$out"
# v2 bindings replace the v1 hook names, which do not exist in v2.
assert_contains "plugin registers the v2 shell hook" 'shell.hook("create.before"' "$out"
assert_contains "plugin registers the v2 prompt hook" 'session.hook("prompt"' "$out"
assert_contains "plugin wakes v2 through synthetic resume" "resume: wake" "$out"

# The installer copies this one file into a directory with no node_modules, so
# a VALUE import fails at load with "Cannot find package '@opencode/plugin'".
# Plugin.define is an identity function, so the object literal is equivalent.
bad_import=$(grep -nE '^\s*import[^;]*from ' "$ROOT/plugins/agent-bus/index.ts" | grep -v 'import type' || true)
assert_eq "plugin has no runtime imports" "" "$bad_import"

# Ownership: the v2 event stream is server-wide, so an unfiltered handler makes
# one chat register as several seats — the identity split, reintroduced.
assert_contains "plugin resolves event ownership by directory" "sameDir(info.location?.directory, ctx.location.directory)" "$out"
assert_contains "plugin ignores child sessions" "!info.parentID" "$out"

# The installer must lay the plugin out as a directory package: OpenCode 2
# rejects a bare .ts config entry with "configured plugin path must be a directory".
inst=$(<"$ROOT/install-hooks.sh")
assert_contains "installer registers a directory entry" 'plugins/$OPENCODE_PLUGIN_NAME"' "$inst"
assert_contains "installer removes the pre-v2 flat file" 'rm -f "$OPENCODE_PLUGINS/$OPENCODE_PLUGIN_NAME.ts"' "$inst"
# Host configs are often dotfiles symlinks; jq-to-tmp + mv would replace the
# link with a regular file and silently detach them.
assert_contains "installer writes through symlinks" "resolve_link" "$inst"

# @opencode is a builtin scope: postable before any opencode seat exists.
out=$(AGENT_BUS_TOOL=claude "$BIN" post --to @opencode --state fyi \
  -m $'# builtin opencode scope\n\nhi' 2>&1)
assert_contains "@opencode postable with no seat" "posted" "$out"

# 'opencode' is a reserved role name — can never shadow the tool scope.
out=$("$BIN" role opencode 2>&1 || true)
assert_contains "opencode reserved as role name" "invalid role name" "$out"

# A seat with a recorded endpoint (as the plugin writes it via
# AGENT_BUS_ENDPOINT) is push-wakeable: poke_endpoint curls prompt_async.
# Fake server: records the request body; response ignored (best-effort).
FAKE_PORT=18472
cat >"$OC_HOME/fake-server.py" <<PY
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        open("$OC_HOME/poke-body.txt", "ab").write(self.rfile.read(n))
        self.send_response(204)
        self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", $FAKE_PORT), H).serve_forever()
PY
python3 "$OC_HOME/fake-server.py" &
FAKE_PID=$!
# Preserve the suite's original BUS_HOME cleanup while adding ours.
trap 'kill "$FAKE_PID" 2>/dev/null || true; rm -rf "$OC_HOME" "$BUS_HOME"' EXIT

# Register an opencode seat with an endpoint, exactly as the plugin's
# shell.env-stamped children do.
AGENT_BUS_TOOL=opencode AGENT_BUS_WT=oc AGENT_BUS_SESSION=oc-sess \
  AGENT_BUS_ENDPOINT="http://127.0.0.1:$FAKE_PORT oc-sess" "$BIN" heartbeat >/dev/null
out=$(AGENT_BUS_TOOL=opencode AGENT_BUS_WT=oc AGENT_BUS_SESSION=oc-sess "$BIN" whoami)
assert_contains "endpoint seat session-unique" "opencode/oc." "$out"

# touch_seat persisted the endpoint field.
grep -Fq '"endpoint":"http://127.0.0.1:' "$OC_HOME/seats/"opencode_oc*.json
assert_eq "seat registry records endpoint" "0" "$?"

# A post wakes the endpoint seat: the fake server captures the prompt_async body.
sleep 0.3
AGENT_BUS_NO_PUSH=0 AGENT_BUS_TOOL=claude "$BIN" post --to opencode/oc --state needs-review \
  -m $'# poke me\n\nnow' >/dev/null 2>&1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$OC_HOME/poke-body.txt" ] && break
  sleep 0.2
done
out=$(cat "$OC_HOME/poke-body.txt" 2>/dev/null || true)
assert_contains "endpoint poke hits prompt_async" "from another agent, not your user" "$out"

# doctor reports endpoint reachability.
out=$("$BIN" doctor)
assert_contains "doctor shows endpoint reachability" "PUSH-reachable (endpoint)" "$out"

kill "$FAKE_PID" 2>/dev/null || true
export AGENT_BUS_HOME="$SAVED_HOME"
rm -rf "$OC_HOME"

# --- hook payload session_id (Codex hooks export no session env) ---
# A hook command fed the host's JSON payload must resolve to the same instance
# seat as a shell that carries the session id in env; otherwise one Codex
# session splits into a bare hook seat and an instance shell seat.
HP_HOME=$(mktemp -d); SAVED_HOME="$AGENT_BUS_HOME"; export AGENT_BUS_HOME="$HP_HOME"
HP_SESS="01a07d12-9eac-72f3-8482-cadcca741899"
want=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp AGENT_BUS_SESSION="$HP_SESS" "$BIN" whoami | awk '/^seat/{print $2}')
printf '{"session_id":"%s","cwd":"/x","hook_event_name":"SessionStart"}' "$HP_SESS" \
  | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp "$BIN" heartbeat
got=$(jq -r '.addr' "$HP_HOME/seats/$(tr '/' '_' <<<"$want").json" 2>/dev/null || echo missing)
assert_eq "hook payload session_id -> instance seat" "$want" "$got"
assert_eq "hook payload does not also register the bare scope" "" \
  "$(ls "$HP_HOME/seats/" | grep -x 'codex_hp.json' || true)"
# Env pin wins over the payload.
printf '{"session_id":"other-session"}' \
  | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp AGENT_BUS_SESSION="$HP_SESS" "$BIN" heartbeat
assert_eq "env session outranks payload session_id" "1" \
  "$(ls "$HP_HOME/seats/" | grep -c '^codex_hp\.' || true)"
# The payload outranks inherited host markers (a Codex CLI launched from inside
# another agent's shell inherits that agent's session id).
printf '{"session_id":"%s"}' "$HP_SESS" \
  | CLAUDE_CODE_SESSION_ID=parent-claude-session AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp "$BIN" heartbeat
assert_eq "payload session_id outranks inherited host marker" "1" \
  "$(ls "$HP_HOME/seats/" | grep -c '^codex_hp\.' || true)"
# A payload without session_id (or unparseable) keeps the bare scope.
printf 'not json' | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp2 "$BIN" heartbeat
assert_eq "unparseable payload -> bare scope" "codex/hp2" \
  "$(jq -r '.addr' "$HP_HOME/seats/codex_hp2.json" 2>/dev/null || echo missing)"
# Non-hook commands ignore stdin entirely (post reads a body from it).
out=$(printf '{"session_id":"%s"}' "$HP_SESS" | AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp3 "$BIN" whoami)
assert_contains "whoami ignores piped payload" "seat     codex/hp3" "$out"
# stop-hook still parses the payload and drains stdin.
out=$(printf '{"session_id":"%s"}' "$HP_SESS" | AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp "$BIN" stop-hook)
assert_eq "stop-hook with payload emits json" "{}" "$(jq -c . <<<"$out")"

# Hook payloads are captured per tool/event for later inspection.
printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","cwd":"/x"}' "$HP_SESS" \
  | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex AGENT_BUS_WT=hp "$BIN" digest >/dev/null
assert_eq "hook payload captured per tool/event" "UserPromptSubmit" \
  "$(jq -r '.payload.hook_event_name' "$HP_HOME/state/capture/codex-UserPromptSubmit.json" 2>/dev/null || echo missing)"
assert_contains "capture records hook env markers" '"AGENT_BUS_TOOL":"codex"' "$(jq -c '.env' "$HP_HOME/state/capture/codex-UserPromptSubmit.json")"
printf '{"conversation_id":"c-1","workspace_roots":["/nowhere"],"hook_event_name":"stop","status":"completed"}' \
  | AGENT_BUS_HOME="$HP_HOME" "$ROOT/bin/agent-bus-cursor-hook" stop >/dev/null 2>&1 || true
assert_eq "cursor adapter captures payload" "c-1" \
  "$(jq -r '.payload.conversation_id' "$HP_HOME/state/capture/cursor-stop.json" 2>/dev/null || echo missing)"

# Cursor: the agent's tool shell (CURSOR_AGENT + CURSOR_CONVERSATION_ID) and the
# adapter-run hooks (payload session_id) must resolve to one instance seat.
CUR_CONV="337a04c0-fc3c-4f74-baa1-4631088b66e8"
shell_seat=$(CURSOR_AGENT=1 CURSOR_CONVERSATION_ID="$CUR_CONV" AGENT_BUS_WT=cw "$BIN" whoami | awk '/^seat/{print $2}')
assert_contains "cursor shell markers -> cursor instance seat" "cursor/cw." "$shell_seat"
printf '{"conversation_id":"%s","session_id":"%s","hook_event_name":"sessionStart","workspace_roots":["%s"]}' \
  "$CUR_CONV" "$CUR_CONV" "$ROOT" | AGENT_BUS_HOME="$HP_HOME" AGENT_BUS_WT=cw "$ROOT/bin/agent-bus-cursor-hook" sessionStart >/dev/null 2>&1 || true
assert_eq "cursor sessionStart hook lands on the shell's seat" "1" \
  "$(ls "$HP_HOME/seats/" | grep -c "^$(tr '/' '_' <<<"$shell_seat")\.json$" || true)"
assert_eq "cursor sessionStart does not create a bare seat" "" "$(ls "$HP_HOME/seats/" | grep -x 'cursor_cw.json' || true)"

# Cursor executing Claude-format hooks: recognizable payload, must stand down.
COMPAT='{"conversation_id":"c-9","session_id":"c-9","cursor_version":"3.20.21","hook_event_name":"sessionStart","workspace_roots":["/x"]}'
out=$(printf '%s' "$COMPAT" | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=claude AGENT_BUS_WT=compat "$BIN" digest)
assert_eq "cursor-compat digest is silent" "" "$out"
assert_eq "cursor-compat hook registers no seat" "" "$(ls "$HP_HOME/seats/" | grep 'compat' || true)"
out=$(printf '%s' "$COMPAT" | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=claude AGENT_BUS_WT=compat "$BIN" stop-hook)
assert_eq "cursor-compat stop-hook emits {}" "{}" "$(jq -c . <<<"$out")"
out=$(printf '%s' "$COMPAT" | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=cursor AGENT_BUS_WT=compat "$BIN" heartbeat; ls "$HP_HOME/seats/" | grep -c 'cursor_compat' || true)
assert_eq "same payload under the cursor tool is honored" "1" "$out"

# Same session anchored elsewhere: hooks at the workspace repo, shell in another.
printf '{"session_id":"anch-1","hook_event_name":"sessionStart"}' \
  | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=cursor AGENT_BUS_WT=wsroot AGENT_BUS_REPO_ID=repo-A "$BIN" heartbeat
out=$(AGENT_BUS_TOOL=cursor AGENT_BUS_SESSION=anch-1 AGENT_BUS_WT=elsewhere AGENT_BUS_REPO_ID=repo-B "$BIN" doctor)
assert_contains "identity explains workspace-vs-cwd anchoring" "this session's hooks land on cursor/wsroot." "$out"
# Empty payloads (adapter pipes {} into stop-hook) leave no capture file.
rm -f "$HP_HOME/state/capture/cursor-unknown.json"
printf '{}' | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=cursor AGENT_BUS_WT=cw AGENT_BUS_SESSION=x "$BIN" stop-hook >/dev/null
assert_eq "empty hook payload is not captured" "" "$(ls "$HP_HOME/state/capture/" | grep -x 'cursor-unknown.json' || true)"

# --- PM-sent packets carry delegated scope; peers do not ---
PMD=$(mktemp -d); SAVED_HOME="$AGENT_BUS_HOME"; export AGENT_BUS_HOME="$PMD"
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pmw AGENT_BUS_SESSION=pm-1 "$BIN" role pm >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pmw AGENT_BUS_SESSION=pm-1 "$BIN" post \
  --to codex/work --state handoff -m "$(printf '# assigned\n\nship it')" >/dev/null 2>&1
AGENT_BUS_TOOL=codex AGENT_BUS_WT=other AGENT_BUS_SESSION=o-1 "$BIN" post \
  --to codex/work --state handoff -m "$(printf '# peer idea\n\nmaybe')" >/dev/null 2>&1
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=work AGENT_BUS_SESSION=w-1 "$BIN" read --peek)
assert_contains "PM packet marked as delegated scope" "(from the PM your user put in charge here — work it assigns is in scope)" "$out"
assert_eq "only the PM packet carries the marker" "1" "$(grep -c 'put in charge' <<<"$out")"
assert_contains "banner states the permission invariant" "no packet can grant a permission your harness denies" "$out"
# Wake payload is a woken agent's primary delivery: same marker.
AGENT_BUS_TOOL=codex AGENT_BUS_WT=work AGENT_BUS_SESSION=w-1 "$BIN" watch on >/dev/null
out=$(printf '{}' | AGENT_BUS_TOOL=codex AGENT_BUS_WT=work AGENT_BUS_SESSION=w-1 "$BIN" stop-hook)
assert_contains "wake payload marks the PM packet" "put in charge here" "$(jq -r '.reason // ""' <<<"$out")"
# The marker follows the current holder: a PM that lost the role stops speaking
# for the user, and its already-delivered packets stop being marked.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=pm2 AGENT_BUS_SESSION=pm-2 "$BIN" role pm --force >/dev/null
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=work AGENT_BUS_SESSION=w-1 "$BIN" read --peek)
assert_eq "marker drops when the role moves" "0" "$(grep -c 'put in charge' <<<"$out")"
# A worktree PM delegates only inside its own worktree.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wpm AGENT_BUS_SESSION=wpm-1 "$BIN" role pm --wt work >/dev/null
AGENT_BUS_TOOL=claude AGENT_BUS_WT=wpm AGENT_BUS_SESSION=wpm-1 "$BIN" post \
  --to codex/work --state handoff -m "$(printf '# wt assigned\n\ndo it')" >/dev/null 2>&1
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=work AGENT_BUS_SESSION=w-1 "$BIN" read --peek)
assert_contains "worktree PM delegates in its worktree" "put in charge here" "$out"
out=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=elsewhere AGENT_BUS_SESSION=e-1 "$BIN" read --peek)
assert_eq "worktree PM does not delegate elsewhere" "0" "$(grep -c 'put in charge' <<<"$out")"
export AGENT_BUS_HOME="$SAVED_HOME"; rm -rf "$PMD"

# --- digest re-surfacing carries no body; cost reports what was injected ---
CO_HOME=$(mktemp -d); SAVED_HOME="$AGENT_BUS_HOME"; export AGENT_BUS_HOME="$CO_HOME"
co() { AGENT_BUS_TOOL=codex AGENT_BUS_WT=co AGENT_BUS_SESSION=co-sess "$BIN" "$@"; }
AGENT_BUS_TOOL=claude AGENT_BUS_WT=cosend AGENT_BUS_SESSION=cosend-sess "$BIN" post \
  --to codex/co --state needs-review -m "$(printf '# cost probe\n\nBODYMARKER line one\nBODYMARKER line two')" >/dev/null
out=$(co read --digest)
assert_contains "first digest renders the body" "BODYMARKER" "$out"
out=$(co read --digest)
assert_not_contains "repeat digest omits the body" "BODYMARKER" "$out"
assert_contains "repeat digest points at show" "body shown earlier" "$out"
out=$(co read)
assert_contains "an explicit read still renders the body" "BODYMARKER" "$out"
out=$("$BIN" cost)
assert_contains "cost names the seat" "$(co whoami | awk '/^seat/{print $2}' | tr '/' '_')" "$out"
assert_contains "cost reports a token total" "agent-bus has injected ~" "$out"
assert_contains "cost states its method" "Tokens are bytes/4" "$out"
export AGENT_BUS_HOME="$SAVED_HOME"; rm -rf "$CO_HOME"

# --- doctor: stale/missing host hook installs ---
HK=$(mktemp -d)
# Current-shape install: tool pinned everywhere, Stop runs stop-hook.
jq -n '{hooks:{SessionStart:[{hooks:[{command:"AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex /b/agent-bus heartbeat"}]}],
                Stop:[{hooks:[{command:"AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex /b/agent-bus stop-hook"}]}]}}' >"$HK/codex-ok.json"
# Stale: Stop runs heartbeat (no wake) and the digest line has no tool pin.
jq -n '{hooks:{SessionStart:[{hooks:[{command:"AGENT_BUS_VIA=hook /b/agent-bus digest"}]}],
                Stop:[{hooks:[{command:"AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex /b/agent-bus heartbeat"}]}]}}' >"$HK/codex-stale.json"
jq -n '{hooks:{sessionStart:[{command:"/b/agent-bus-cursor-hook sessionStart"}]}}' >"$HK/cursor.json"
jq -n '{hooks:{SessionStart:[{hooks:[{command:"/other/tool run"}]}]}}' >"$HK/none.json"
out=$(AGENT_BUS_CODEX_HOOKS="$HK/codex-ok.json" AGENT_BUS_CURSOR_HOOKS="$HK/cursor.json" \
  AGENT_BUS_CLAUDE_SETTINGS="$HK/none.json" "$BIN" doctor)
assert_contains "doctor: current codex install is ok" "codex   ok (2 line(s), stop-hook present)" "$out"
assert_contains "doctor: cursor adapter counted" "cursor  ok (1 line(s), adapter)" "$out"
assert_contains "doctor: config without agent-bus lines is not installed" "claude  not installed — run ./install-hooks.sh --claude" "$out"
out=$(AGENT_BUS_CODEX_HOOKS="$HK/codex-stale.json" AGENT_BUS_CURSOR_HOOKS="$HK/cursor.json" \
  AGENT_BUS_CLAUDE_SETTINGS="$HK/codex-ok.json" "$BIN" doctor)
assert_contains "doctor: stale install names the missing stop-hook" "no stop-hook line (this host can never be woken)" "$out"
assert_contains "doctor: stale install counts unpinned lines" "1 of 2 line(s) missing the AGENT_BUS_TOOL pin" "$out"
out=$(AGENT_BUS_CODEX_HOOKS="$HK/absent.json" "$BIN" doctor)
assert_contains "doctor: absent config reported" "codex   not installed — no $HK/absent.json" "$out"
rm -rf "$HK"

# --- doctor: unacked-after-MAX_SHOWS lists live seats and unacked packets only ---
DT_SEAT=$(AGENT_BUS_TOOL=codex AGENT_BUS_WT=dt AGENT_BUS_SESSION=dt-sess "$BIN" whoami | awk '/^seat/{print $2}' | tr '/' '_')
AGENT_BUS_TOOL=codex AGENT_BUS_WT=dt AGENT_BUS_SESSION=dt-sess "$BIN" heartbeat </dev/null
mkdir -p "$HP_HOME/state"
# Two capped packets, one later acked: only the unacked one counts.
jq -n '{read:["p-acked"], shown:{"p-acked":3,"p-unacked":3,"p-once":1}}' >"$HP_HOME/state/$DT_SEAT.json"
# Dead seat (no seats/ file) with capped packets: history, not reported.
jq -n '{shown:{"p-old":5}}' >"$HP_HOME/state/codex_deadseat.json"
out=$("$BIN" doctor)
assert_contains "doctor lists live seat with unacked capped packet" "$DT_SEAT" "$out"
assert_contains "doctor counts only unacked capped packets" "1 packet(s)" "$out"
assert_not_contains "doctor skips dead seats" "codex_deadseat" "$out"
export AGENT_BUS_HOME="$SAVED_HOME"
rm -rf "$HP_HOME"

# --- selftest: end-to-end delivery probe ---
ST_HOME=$(mktemp -d); SAVED_HOME="$AGENT_BUS_HOME"; export AGENT_BUS_HOME="$ST_HOME"
st() { AGENT_BUS_TOOL=codex AGENT_BUS_WT=st AGENT_BUS_SESSION=st-sess "$BIN" "$@"; }
st_hook() { printf '{"session_id":"st-sess"}' | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex AGENT_BUS_WT=st "$BIN" "$@"; }
ST_ADDR=$(st whoami | awk '/^seat/{print $2}')
st watch on >/dev/null
out=$(st selftest)
assert_contains "selftest arms a probe" "selftest armed for $ST_ADDR" "$out"
assert_eq "selftest arm output never leaks the nonce" "" "$(grep -oE 'selftest check [0-9a-f]{6}' <<<"$out" || true)"
assert_contains "probe row is flagged" '"probe":true' "$(grep -F '"from":"selftest/probe"' "$ST_HOME/ledger.jsonl")"
# A PM is never CC'd on a probe, and triage never lists one.
AGENT_BUS_TOOL=claude AGENT_BUS_WT=stpm AGENT_BUS_SESSION=stpm-sess "$BIN" role pm >/dev/null
out=$(AGENT_BUS_TOOL=claude AGENT_BUS_WT=stpm AGENT_BUS_SESSION=stpm-sess "$BIN" read --peek)
assert_contains "PM not auto-CC'd on probe" "nothing unread" "$out"
assert_contains "triage ignores probes" "no unresolved supervisory" "$(st triage)"
# Digest surfaces the probe with the check instruction; the nonce comes only
# from the body, so this must be the probe's FIRST surfacing — a later one
# carries a pointer instead (see the re-surfacing tests above).
out=$(st_hook digest)
assert_contains "digest surfaces the probe" "agent-bus selftest" "$out"
ST_NONCE=$(grep -oE 'selftest check [0-9a-f]{6}' <<<"$out" | head -1 | awk '{print $3}')
assert_eq "digest carries a 6-hex nonce" "6" "${#ST_NONCE}"
# Stop hook (watch on, owned supervisory unread) continues the seat = wake check.
# The wake payload always renders the body: it is that agent's primary delivery.
out=$(st_hook stop-hook)
assert_eq "probe wakes the seat via stop-hook" "block" "$(jq -r '.decision // empty' <<<"$out")"
assert_contains "wake payload carries the body even on a repeat surfacing" "selftest check $ST_NONCE" "$out"
out=$(st selftest check "$ST_NONCE"); rc=$?
assert_eq "selftest check passes end to end" "0" "$rc"
assert_contains "check: identity shared" "PASS  identity: hooks and shell share seat $ST_ADDR" "$out"
assert_contains "check: hooks fired" "PASS  hooks fire" "$out"
assert_contains "check: digest surfaced" "PASS  digest surfaced" "$out"
assert_contains "check: injection proven by nonce" "PASS  injection: nonce matches" "$out"
assert_contains "check: stop-hook wake" "PASS  stop-hook wake" "$out"
assert_contains "check: probe resolved" "probe acked and resolved" "$out"
assert_contains "probe gone after check" "nothing unread" "$(st read --peek)"
assert_eq "check resets the wake budget" "0" "$(jq -r '.wake_count // 0' "$ST_HOME/state/$(tr '/' '_' <<<"$ST_ADDR").json")"
out=$(st selftest check 2>&1 || true)
assert_contains "check without a probe refuses" "no probe armed" "$out"
# Without the nonce, injection is unproven (not failed); wake is skipped when watch was off.
st watch off >/dev/null
st selftest >/dev/null; st_hook digest >/dev/null
out=$(st selftest check); rc=$?
assert_eq "check without nonce is not a failure" "0" "$rc"
assert_contains "check: injection unproven without nonce" "UNPROVEN  injection" "$out"
assert_contains "check: wake skipped when watch off" "SKIP  stop-hook wake" "$out"
# Wrong nonce fails.
st selftest >/dev/null; st_hook digest >/dev/null
out=$(st selftest check deadbe || true)
assert_contains "check: wrong nonce fails" "FAIL  injection: wrong nonce" "$out"
# Identity split: a bare-scope seat with hook touches while the shell is an instance.
AGENT_BUS_VIA=hook AGENT_BUS_TOOL=codex AGENT_BUS_WT=st "$BIN" heartbeat </dev/null
out=$(st selftest)
assert_contains "selftest flags identity split" "FAIL  identity split: hooks register as codex/st" "$out"
assert_contains "doctor flags identity split" "identity split" "$(st doctor)"
st selftest check >/dev/null 2>&1 || true
# Once hooks land on the instance seat again, the lingering bare seat is history.
sleep 1; st_hook heartbeat
out=$(st doctor)
assert_contains "fixed split downgrades to info" "INFO  a bare seat codex/st" "$out"
assert_contains "fixed split passes identity" "PASS  identity: hooks and shell share seat $ST_ADDR" "$out"
# Cross-tool split: a markerless shell (tool=shell) inside a host whose hooks
# register under the host's tool name — the Cursor-panel signature.
printf '{"session_id":"cur-1"}' | AGENT_BUS_VIA=hook AGENT_BUS_TOOL=cursor AGENT_BUS_WT=xt "$BIN" heartbeat
out=$(AGENT_BUS_TOOL=shell AGENT_BUS_WT=xt "$BIN" selftest)
assert_contains "selftest flags markerless shell beside hook seat" "FAIL  identity split: this shell carries no host markers, so it is the bare seat shell/xt" "$out"
assert_contains "markerless split lists hook-touched candidates" "Hook-touched seats in this worktree: cursor/xt." "$out"
AGENT_BUS_TOOL=shell AGENT_BUS_WT=xt "$BIN" selftest check >/dev/null 2>&1 || true
out=$(AGENT_BUS_TOOL=shell AGENT_BUS_WT=lonely "$BIN" self-test)
assert_contains "self-test alias works; lone markerless shell is a warning" "WARN  identity: no host markers in this shell" "$out"
AGENT_BUS_TOOL=shell AGENT_BUS_WT=lonely "$BIN" selftest check >/dev/null 2>&1 || true
export AGENT_BUS_HOME="$SAVED_HOME"; rm -rf "$ST_HOME"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
