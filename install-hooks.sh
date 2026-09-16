#!/usr/bin/env bash
# Wire agent-bus into Claude Code, Codex, Cursor, and OpenCode.
#
# Idempotent: every managed hook command carries the AGENT_BUS_MANAGED marker,
# and existing marked entries are stripped before re-adding. Config files are
# backed up next to themselves before any write (first install only — see
# ensure_backup).
#
# Usage: install-hooks.sh [--claude] [--codex] [--cursor] [--opencode] [--uninstall]
#   (default: all four)
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
OPENCODE_PLUGIN_DIR="${AGENT_BUS_OPENCODE_PLUGIN_DIR:-$ROOT/plugins/agent-bus}"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOOKS="$HOME/.codex/hooks.json"
CURSOR_HOOKS="$HOME/.cursor/hooks.json"
# OpenCode installs a plugin, not shell hooks: the plugin is copied into the
# global config dir and registered in the global opencode.json plugin array.
OPENCODE_PLUGINS="$HOME/.config/opencode/plugins"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
OPENCODE_PLUGIN_NAME="agent-bus"

do_claude=0 do_codex=0 do_cursor=0 do_opencode=0 uninstall=0
for a in "$@"; do
  case "$a" in
    --claude) do_claude=1 ;;
    --codex) do_codex=1 ;;
    --cursor) do_cursor=1 ;;
    --opencode) do_opencode=1 ;;
    --uninstall) uninstall=1 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done
((do_claude || do_codex || do_cursor || do_opencode)) || { do_claude=1; do_codex=1; do_cursor=1; do_opencode=1; }

# Back up once, not every run: re-copying would overwrite the pristine
# pre-agent-bus snapshot with the currently-installed file on repeat runs.
ensure_backup() {
  local f="$1" bak="$1.agent-bus.bak"
  [ -f "$bak" ] || cp "$f" "$bak"
}

# Hook payloads are wrapped so a bus failure can never break the host agent.
# AGENT_BUS_VIA=hook is what lets `agent-bus doctor` prove hooks are firing.
# Every hook pins AGENT_BUS_TOOL: env-sniffing can misread a hook subshell,
# and a digest that resolves to a different seat than the heartbeat splits one
# session into two identities (observed as codex-vs-shell on the same seat).
digest_cmd() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=%s %s digest 2>/dev/null || true %s' "$1" "$BIN" "$MARKER"; }
heartbeat_cmd() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=%s %s heartbeat 2>/dev/null || true %s' "$1" "$BIN" "$MARKER"; }
release_cmd() { printf '%s release --all >/dev/null 2>&1 || true %s' "$BIN" "$MARKER"; }
# Stop hook: always emit JSON ({} or decision:block). Heartbeat is inside stop-hook.
stop_cmd() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=%s %s stop-hook 2>/dev/null || echo "{}" %s' "$1" "$BIN" "$MARKER"; }
# Cursor does not document whether `command` runs through a shell, so this
# line must work both ways: no env prefix, no redirects, no `||`. The adapter
# pins AGENT_BUS_VIA/TOOL itself and always emits JSON; the trailing marker is
# a comment under a shell and an ignored extra argv otherwise.
cursor_cmd() { printf '%s %s %s' "$CURSOR_HOOK" "$1" "$MARKER"; }

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
  ensure_backup "$CLAUDE_SETTINGS"
  local out
  out=$(strip_marked <"$CLAUDE_SETTINGS")
  if ((!uninstall)); then
    # SessionStart / UserPromptSubmit stdout is injected into Claude's context,
    # so a silent-when-empty digest surfaces handoffs with zero noise.
    out=$(printf '%s' "$out" | add_group SessionStart "$(heartbeat_cmd claude)" "$(digest_cmd claude)")
    out=$(printf '%s' "$out" | add_group UserPromptSubmit "$(digest_cmd claude)")
    # Stop continues the agent when watch is on and supervisory mail is unread.
    out=$(printf '%s' "$out" | add_group Stop "$(stop_cmd claude)")
    out=$(printf '%s' "$out" | add_group SessionEnd "$(release_cmd)")
  fi
  printf '%s\n' "$out" | jq . >"$CLAUDE_SETTINGS.tmp" && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
  echo "claude: $( ((uninstall)) && echo removed || echo installed ) (backup: $CLAUDE_SETTINGS.agent-bus.bak)"
}

install_codex() {
  [ -f "$CODEX_HOOKS" ] || echo '{}' >"$CODEX_HOOKS"
  ensure_backup "$CODEX_HOOKS"
  local out
  out=$(strip_marked <"$CODEX_HOOKS")
  if ((!uninstall)); then
    out=$(printf '%s' "$out" | add_group SessionStart "$(heartbeat_cmd codex)" "$(digest_cmd codex)")
    out=$(printf '%s' "$out" | add_group UserPromptSubmit "$(digest_cmd codex)")
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
  ensure_backup "$CURSOR_HOOKS"
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
  ((uninstall)) || echo "cursor: hooks.json is read at launch — restart Cursor (or reload the window) before expecting wakes"
}

# OpenCode has no shell-command lifecycle hooks; integration is a TypeScript
# plugin. Install = copy the plugin into the global config dir + register it
# in the global opencode.json plugin array. The entry string doubles as the
# strip marker (any plugin path mentioning plugins/agent-bus is ours).
install_opencode() {
  mkdir -p "$OPENCODE_PLUGINS" "$(dirname "$OPENCODE_CONFIG")"
  [ -f "$OPENCODE_CONFIG" ] || printf '{}\n' >"$OPENCODE_CONFIG"
  ensure_backup "$OPENCODE_CONFIG"
  local plugin_src="$OPENCODE_PLUGIN_DIR/index.ts"
  [ -f "$plugin_src" ] || { echo "opencode: plugin source missing at $plugin_src — skipping" >&2; return 0; }
  if ((uninstall)); then
    rm -f "$OPENCODE_PLUGINS/$OPENCODE_PLUGIN_NAME.ts"
    jq --arg m "plugins/$OPENCODE_PLUGIN_NAME" '
      .plugin //= [] | .plugin |= map(select(contains($m) | not))
    ' "$OPENCODE_CONFIG" | jq . >"$OPENCODE_CONFIG.tmp" && mv "$OPENCODE_CONFIG.tmp" "$OPENCODE_CONFIG"
    echo "opencode: removed (backup: $OPENCODE_CONFIG.agent-bus.bak)"
    return 0
  fi
  cp "$plugin_src" "$OPENCODE_PLUGINS/$OPENCODE_PLUGIN_NAME.ts"
  jq --arg e "./plugins/$OPENCODE_PLUGIN_NAME.ts" '
    .plugin //= [] | .plugin |= (map(select(contains("plugins/agent-bus") | not)) + [$e] | unique)
  ' "$OPENCODE_CONFIG" | jq . >"$OPENCODE_CONFIG.tmp" && mv "$OPENCODE_CONFIG.tmp" "$OPENCODE_CONFIG"
  echo "opencode: installed (backup: $OPENCODE_CONFIG.agent-bus.bak)"
  echo "opencode: the plugin is copied as a snapshot — re-run this installer after upgrading agent-bus"
  echo "opencode: requires agent-bus on PATH (or AGENT_BUS_BIN) — restart OpenCode; config is read once at startup"
}

((do_claude)) && install_claude
((do_codex)) && install_codex
((do_cursor)) && install_cursor
((do_opencode)) && install_opencode
exit 0
