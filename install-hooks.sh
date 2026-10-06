#!/usr/bin/env bash
# Wire agent-bus into Claude Code (hooks) and OpenCode (plugin).
#
# Idempotent: every managed hook command carries the agent-bus-managed marker
# and is stripped before re-adding. Each config is backed up once, next to
# itself, before the first write.
#
# Usage: install-hooks.sh [--claude] [--opencode] [--uninstall] [--remove-legacy]
#   default: --claude --opencode
#   --remove-legacy strips hooks a v1 install left in Codex and Cursor configs.
set -euo pipefail

MARKER='# agent-bus-managed'
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ -n "${AGENT_BUS_BIN:-}" ]; then BIN="$AGENT_BUS_BIN"
elif [ -x "$ROOT/bin/agent-bus" ]; then BIN="$ROOT/bin/agent-bus"
else BIN="$(command -v agent-bus || echo "$HOME/.local/bin/agent-bus")"; fi
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
OPENCODE_DIR="$HOME/.config/opencode"
PLUGIN_SRC="$ROOT/plugins/agent-bus"

do_claude=0 do_opencode=0 uninstall=0 legacy=0
for a in "$@"; do
  case "$a" in
    --claude) do_claude=1 ;;
    --opencode) do_opencode=1 ;;
    --uninstall) uninstall=1 ;;
    --remove-legacy) legacy=1 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done
((do_claude || do_opencode || legacy)) || { do_claude=1; do_opencode=1; }

# Configs are often symlinks into a dotfiles repo; write through the link.
real() { [ -L "$1" ] && python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" || printf '%s' "$1"; }
backup() { [ -f "$1.agent-bus.bak" ] || cp "$1" "$1.agent-bus.bak"; }
write_json() { jq . >"$1.tmp" && mv "$1.tmp" "$1"; }

# Wrapped so a bus failure can never break the host turn. VIA=hook lets
# `doctor` see that hooks fire; the tool pin keeps hooks and shell on one seat.
# The marker goes last: anywhere earlier it would comment out the fallback.
hook() { printf 'AGENT_BUS_VIA=hook AGENT_BUS_TOOL=claude %s %s %s' "$BIN" "$1" "$MARKER"; }

strip_marked() { jq --arg m "$MARKER" '
  if .hooks then .hooks |= with_entries(
      .value |= (map(if .hooks then .hooks |= map(select((.command // "") | contains($m) | not)) else . end)
                 | map(select(((.command // "") | contains($m) | not) and ((.hooks // [1]) | length > 0)))))
    | .hooks |= with_entries(select(.value | length > 0))
  else . end'; }

add_group() { # <event> <command>
  jq --arg e "$1" --arg c "$2" '.hooks //= {} | .hooks[$e] = ((.hooks[$e] // []) + [{hooks: [{type: "command", command: $c}]}])'
}

install_claude() {
  local f; [ -f "$CLAUDE_SETTINGS" ] || echo '{}' >"$CLAUDE_SETTINGS"
  f=$(real "$CLAUDE_SETTINGS"); backup "$f"
  local out; out=$(strip_marked <"$f")
  if ((!uninstall)); then
    # SessionStart and UserPromptSubmit stdout is injected into the model, so
    # the digest delivers; Stop continues the seat on work it owns.
    out=$(add_group SessionStart "$(hook "digest 2>/dev/null || true")" <<<"$out")
    out=$(add_group UserPromptSubmit "$(hook "digest 2>/dev/null || true")" <<<"$out")
    out=$(add_group Stop "$(hook "stop-hook 2>/dev/null || echo '{}'")" <<<"$out")
    out=$(add_group SessionEnd "$(hook "offboard >/dev/null 2>&1 || true")" <<<"$out")
  fi
  write_json "$f" <<<"$out"
  echo "claude:   $( ((uninstall)) && echo removed || echo installed ) ($f)"
}

# OpenCode has no shell hooks; the plugin shells out to the same CLI. It is
# copied as a snapshot, so re-run after upgrading agent-bus.
install_opencode() {
  local cfg="$OPENCODE_DIR/opencode.json" dest="$OPENCODE_DIR/plugins/agent-bus"
  mkdir -p "$OPENCODE_DIR/plugins"
  [ -f "$cfg" ] || echo '{}' >"$cfg"
  cfg=$(real "$cfg"); backup "$cfg"
  rm -rf "$dest" "$OPENCODE_DIR/plugins/agent-bus.ts"
  if ((uninstall)); then
    jq '.plugin = ((.plugin // []) | map(select(contains("plugins/agent-bus") | not)))' "$cfg" | write_json "$cfg"
    echo "opencode: removed ($cfg)"; return 0
  fi
  mkdir -p "$dest"
  cp "$PLUGIN_SRC/index.ts" "$PLUGIN_SRC/package.json" "$dest/"
  jq '.plugin = (((.plugin // []) | map(select(contains("plugins/agent-bus") | not))) + ["./plugins/agent-bus"])' "$cfg" | write_json "$cfg"
  echo "opencode: installed ($dest) — restart OpenCode; config is read once at startup"
}

remove_legacy() {
  local f
  for f in "$HOME/.codex/hooks.json" "$HOME/.cursor/hooks.json"; do
    [ -f "$f" ] || continue
    f=$(real "$f")
    grep -q 'agent-bus' "$f" || continue
    backup "$f"
    strip_marked <"$f" | write_json "$f"
    echo "legacy:   removed agent-bus hooks from $f"
  done
}

((do_claude)) && install_claude
((do_opencode)) && install_opencode
((legacy)) && remove_legacy
exit 0
