#!/usr/bin/env bash
# Wire agent-bus into Claude Code, Codex, and Cursor lifecycle hooks.
#
# Idempotent: every managed hook command carries the AGENT_BUS_MANAGED marker,
# and existing marked entries are stripped before re-adding. Config files are
# backed up next to themselves before any write.
#
# Usage: install-hooks.sh [--claude] [--codex] [--cursor] [--uninstall]
#   (default: all three)
set -euo pipefail

MARKER='# agent-bus-managed'
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${AGENT_BUS_BIN:-}" ]; then
  BIN="$AGENT_BUS_BIN"
elif [ -x "$ROOT/bin/agent-bus" ]; then
  BIN="$ROOT/bin/agent-bus"
elif command -v agent-bus >/dev/null 2>&1; then
  BIN="$(command -v agent-bus)"
else
  BIN="$HOME/.local/bin/agent-bus"
fi
CURSOR_HOOK="${AGENT_BUS_CURSOR_HOOK:-$ROOT/bin/agent-bus-cursor-hook}"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"

do_claude=0 do_codex=0 do_cursor=0 uninstall=0
for a in "$@"; do
  case "$a" in
    --claude) do_claude=1 ;;
    --codex) do_codex=1 ;;
    --cursor) do_cursor=1 ;;
    --uninstall) uninstall=1 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done
((do_claude || do_codex || do_cursor)) || { do_claude=1; do_codex=1; do_cursor=1; }

# Hook payloads are wrapped so a bus failure can never break the host agent.
# AGENT_BUS_VIA=hook is what lets `agent-bus doctor` prove hooks are firing.
digest_cmd() { printf 'AGENT_BUS_VIA=hook %s digest 2>/dev/null || true %s' "$BIN" "$MARKER"; }
heartbeat_cmd() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=%s %s heartbeat 2>/dev/null || true %s' "$1" "$BIN" "$MARKER"; }
release_cmd() { printf '%s release --all >/dev/null 2>&1 || true %s' "$BIN" "$MARKER"; }
# Stop hook: always emit JSON ({} or decision:block). Heartbeat is inside stop-hook.
stop_cmd() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=%s %s stop-hook 2>/dev/null || echo "{}" %s' "$1" "$BIN" "$MARKER"; }
cursor_cmd() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=cursor %s %s 2>/dev/null || echo "{}" %s' "$CURSOR_HOOK" "$1" "$MARKER"; }

strip_marked() { jq --arg m "$MARKER" '
  def clean_groups:
    map(.hooks |= map(select((.command // "") | contains($m) | not)))
    | map(select((.hooks | length) > 0));
  if .hooks then .hooks |= with_entries(.value |= clean_groups) else . end
  | if .hooks then .hooks |= with_entries(select((.value | length) > 0)) else . end
'; }

# Cursor hooks.json is a flat array of {command} objects per event (version 1).
strip_marked_cursor() { jq --arg m "$MARKER" '
  .hooks //= {}
  | .hooks |= with_entries(
      .value |= map(select((.command // "") | contains($m) | not))
    )
  | .hooks |= with_entries(select((.value | length) > 0))
'; }

add_group() { # <event> <command...>  — appends one group holding the given commands
  local event="$1"; shift
  local cmds='[]'
  for c in "$@"; do cmds=$(jq -c --arg c "$c" '. + [{type:"command",command:$c}]' <<<"$cmds"); done
  jq --arg e "$event" --argjson g "$(jq -c --argjson h "$cmds" '{hooks:$h}' <<<'{}')" \
    '.hooks //= {} | .hooks[$e] //= [] | .hooks[$e] += [$g]'
}

add_cursor_hook() { # <event> <command>
  local event="$1" cmd="$2"
  jq --arg e "$event" --arg c "$cmd" \
    '.version //= 1 | .hooks //= {} | .hooks[$e] //= [] | .hooks[$e] += [{command:$c}]'
}

install_claude() {
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' >"$CLAUDE_SETTINGS"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.agent-bus.bak"
  local out
  out=$(strip_marked <"$CLAUDE_SETTINGS")
  if ((!uninstall)); then
    # SessionStart / UserPromptSubmit stdout is injected into Claude's context,
    # so a silent-when-empty digest surfaces handoffs with zero noise.
    out=$(printf '%s' "$out" | add_group SessionStart "$(heartbeat_cmd claude)" "$(digest_cmd)")
    out=$(printf '%s' "$out" | add_group UserPromptSubmit "$(digest_cmd)")
    # Stop continues the agent when watch is on and supervisory mail is unread.
    out=$(printf '%s' "$out" | add_group Stop "$(stop_cmd claude)")
    out=$(printf '%s' "$out" | add_group SessionEnd "$(release_cmd)")
  fi
  printf '%s\n' "$out" | jq . >"$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
  echo "claude: $( ((uninstall)) && echo removed || echo installed ) (backup: $CLAUDE_SETTINGS.agent-bus.bak)"
}

install_codex() {
  [ -f "$CODEX_HOOKS" ] || echo '{}' >"$CODEX_HOOKS"
  cp "$CODEX_HOOKS" "$CODEX_HOOKS.agent-bus.bak"
  local out
  out=$(strip_marked <"$CODEX_HOOKS")
  if ((!uninstall)); then
    out=$(printf '%s' "$out" | add_group SessionStart "$(heartbeat_cmd codex)" "$(digest_cmd)")
    out=$(printf '%s' "$out" | add_group UserPromptSubmit "$(digest_cmd)")
    # Codex Stop requires JSON on stdout; stop-hook emits {} or decision:block.
    out=$(printf '%s' "$out" | add_group Stop "$(stop_cmd codex)")
  fi
  printf '%s\n' "$out" | jq . >"$CODEX_HOOKS.tmp" && mv "$CODEX_HOOKS.tmp" "$CODEX_HOOKS"
  echo "codex:  $( ((uninstall)) && echo removed || echo installed ) (backup: $CODEX_HOOKS.agent-bus.bak)"
  ((uninstall)) || echo "codex:  new hooks are untrusted — Codex will ask you to approve them on next launch"
}

install_cursor() {
  mkdir -p "$(dirname "$CURSOR_HOOKS")"
  [ -f "$CURSOR_HOOKS" ] || printf '%s\n' '{"version":1,"hooks":{}}' >"$CURSOR_HOOKS"
  cp "$CURSOR_HOOKS" "$CURSOR_HOOKS.agent-bus.bak"
  chmod +x "$CURSOR_HOOK" 2>/dev/null || true
  local out
  out=$(strip_marked_cursor <"$CURSOR_HOOKS")
  if ((!uninstall)); then
    # sessionStart best-effort injects digests; sessionEnd drops claims;
    # stop maps watch wake to followup_message.
    out=$(printf '%s' "$out" | add_cursor_hook sessionStart "$(cursor_cmd sessionStart)")
    out=$(printf '%s' "$out" | add_cursor_hook sessionEnd "$(cursor_cmd sessionEnd)")
    out=$(printf '%s' "$out" | add_cursor_hook stop "$(cursor_cmd stop)")
  fi
  printf '%s\n' "$out" | jq . >"$CURSOR_HOOKS.tmp" && mv "$CURSOR_HOOKS.tmp" "$CURSOR_HOOKS"
  echo "cursor: $( ((uninstall)) && echo removed || echo installed ) (backup: $CURSOR_HOOKS.agent-bus.bak)"
  ((uninstall)) || echo "cursor: delivery still rests on the skill/AGENTS.md layer — sessionStart additional_context is unreliable in the IDE; enable agent-bus watch on for Stop-hook wake"
}

((do_claude)) && install_claude
((do_codex)) && install_codex
((do_cursor)) && install_cursor
exit 0
