#!/usr/bin/env bash
# Wire agent-bus into Claude Code and Codex lifecycle hooks.
#
# Idempotent: every managed hook command carries the AGENT_BUS_MANAGED marker,
# and existing marked entries are stripped before re-adding. Both config files
# are backed up next to themselves before any write.
#
# Usage: install-hooks.sh [--claude] [--codex] [--uninstall]   (default: both)
set -euo pipefail

MARKER='# agent-bus-managed'
BIN="$HOME/.local/bin/agent-bus"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"

do_claude=0 do_codex=0 uninstall=0
for a in "$@"; do
  case "$a" in
    --claude) do_claude=1 ;;
    --codex) do_codex=1 ;;
    --uninstall) uninstall=1 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done
((do_claude || do_codex)) || { do_claude=1; do_codex=1; }

# Hook payloads are wrapped so a bus failure can never break the host agent.
# AGENT_BUS_VIA=hook is what lets `agent-bus doctor` prove hooks are firing.
digest_cmd() { printf 'AGENT_BUS_VIA=hook %s digest 2>/dev/null || true %s' "$BIN" "$MARKER"; }
heartbeat_cmd() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=%s %s heartbeat 2>/dev/null || true %s' "$1" "$BIN" "$MARKER"; }
release_cmd() { printf '%s release --all >/dev/null 2>&1 || true %s' "$BIN" "$MARKER"; }

strip_marked() { jq --arg m "$MARKER" '
  def clean_groups:
    map(.hooks |= map(select((.command // "") | contains($m) | not)))
    | map(select((.hooks | length) > 0));
  if .hooks then .hooks |= with_entries(.value |= clean_groups) else . end
  | if .hooks then .hooks |= with_entries(select((.value | length) > 0)) else . end
'; }

add_group() { # <event> <command...>  — appends one group holding the given commands
  local event="$1"; shift
  local cmds='[]'
  for c in "$@"; do cmds=$(jq -c --arg c "$c" '. + [{type:"command",command:$c}]' <<<"$cmds"); done
  jq --arg e "$event" --argjson g "$(jq -c --argjson h "$cmds" '{hooks:$h}' <<<'{}')" \
    '.hooks //= {} | .hooks[$e] //= [] | .hooks[$e] += [$g]'
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
    out=$(printf '%s' "$out" | add_group Stop "$(heartbeat_cmd codex)")
  fi
  printf '%s\n' "$out" | jq . >"$CODEX_HOOKS.tmp" && mv "$CODEX_HOOKS.tmp" "$CODEX_HOOKS"
  echo "codex:  $( ((uninstall)) && echo removed || echo installed ) (backup: $CODEX_HOOKS.agent-bus.bak)"
  ((uninstall)) || echo "codex:  new hooks are untrusted — Codex will ask you to approve them on next launch"
}

((do_claude)) && install_claude
((do_codex)) && install_codex
exit 0
