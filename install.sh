#!/usr/bin/env bash
# agent-bus installer.
#
#   curl -fsSL https://raw.githubusercontent.com/scottbaggett/agent-bus/main/install.sh | bash
#
# Downloads a release into ~/.local/share/agent-bus/versions/<tag>, points
# `current` at it, links ~/.local/bin/agent-bus, and wires the agents it finds
# (Claude Code, OpenCode, Codex) to `current`. Re-running it is an update.
#
# Options (after `bash -s --` when piped):
#   --version <tag>   install this release instead of the latest
#   --ref <branch>    install a branch (unreleased; for testing)
#   --from <dir>      use a local checkout in place (developing agent-bus)
#   --no-hooks        install the CLI only
#   --uninstall       remove hooks, skills, the link and the install dir
#                     (the bus itself, ~/.agents/bus, is never touched)
set -euo pipefail

REPO="${AGENT_BUS_REPO:-scottbaggett/agent-bus}"
SHARE="${AGENT_BUS_INSTALL_DIR:-$HOME/.local/share/agent-bus}"
BINDIR="${AGENT_BUS_BIN_DIR:-$HOME/.local/bin}"

say() { printf '%s\n' "$*"; }
die() { printf 'agent-bus install: %s\n' "$*" >&2; exit 1; }

version='' ref='' from='' hooks=1 uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a tag"; version="$2"; shift ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a branch"; ref="$2"; shift ;;
    --from) [ $# -ge 2 ] || die "--from needs a directory"; from="$2"; shift ;;
    --no-hooks) hooks=0 ;;
    --uninstall) uninstall=1 ;;
    -h|--help) sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

# Hosts on this machine, as install-hooks.sh flags.
host_flags() {
  local f=''
  { [ -d "$HOME/.claude" ] || command -v claude >/dev/null 2>&1; } && f="$f --claude"
  { [ -d "$HOME/.config/opencode" ] || command -v opencode >/dev/null 2>&1; } && f="$f --opencode"
  { [ -d "${CODEX_HOME:-$HOME/.codex}" ] && command -v python3 >/dev/null 2>&1; } && f="$f --codex"
  printf '%s' "$f"
}

if ((uninstall)); then
  if [ -x "$SHARE/current/install-hooks.sh" ]; then
    # shellcheck disable=SC2046
    "$SHARE/current/install-hooks.sh" --uninstall $(host_flags) || true
  fi
  link="$BINDIR/agent-bus"
  if [ -L "$link" ] && case "$(readlink "$link")" in "$SHARE"/*) true ;; *) false ;; esac; then
    rm -f "$link"; say "removed $link"
  fi
  rm -rf "$SHARE"; say "removed $SHARE"
  say "the bus itself (${AGENT_BUS_HOME:-$HOME/.agents/bus}) was left alone; delete it to drop all history"
  exit 0
fi

for dep in jq curl tar; do
  command -v "$dep" >/dev/null 2>&1 || die "$dep is required (macOS: brew install $dep)"
done

mkdir -p "$SHARE/versions" "$BINDIR"
if [ -n "$from" ]; then
  target=$(cd "$from" && pwd) || die "no such directory: $from"
  [ -x "$target/bin/agent-bus" ] || die "$target is not an agent-bus checkout"
  label="$target (local checkout)"
else
  if [ -n "$ref" ]; then
    tag="$ref"; url="https://github.com/$REPO/archive/refs/heads/$ref.tar.gz"
  else
    tag="$version"
    if [ -z "$tag" ]; then
      tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name // empty') \
        || die "could not look up the latest release (pass --version <tag>)"
      [ -n "$tag" ] || die "no releases found for $REPO (pass --version <tag> or --ref main)"
    fi
    url="https://github.com/$REPO/archive/refs/tags/$tag.tar.gz"
  fi
  url="${AGENT_BUS_DOWNLOAD_URL:-$url}"
  target="$SHARE/versions/${tag//\//-}"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  say "downloading agent-bus $tag"
  curl -fsSL "$url" -o "$tmp/src.tar.gz" || die "download failed: $url"
  mkdir -p "$tmp/src"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp/src" --strip-components=1 || die "could not unpack $url"
  [ -x "$tmp/src/bin/agent-bus" ] || die "$url does not contain bin/agent-bus"
  printf '%s\n' "$tag" >"$tmp/src/.installed-version"
  # The TUI is a prebuilt binary attached to the release; without one (a
  # branch, an older tag, an unlisted platform) everything else still works.
  os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
  case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
  tui_url="${AGENT_BUS_TUI_URL:-https://github.com/$REPO/releases/download/$tag/agent-bus-tui-$os-$arch}"
  if [ -z "$ref" ] && curl -fsSL "$tui_url" -o "$tmp/src/bin/agent-bus-tui" 2>/dev/null; then
    chmod +x "$tmp/src/bin/agent-bus-tui"
  else
    rm -f "$tmp/src/bin/agent-bus-tui"
  fi
  rm -rf "$target"; mv "$tmp/src" "$target"
  label="$tag"
fi

ln -sfn "$target" "$SHARE/current"
ln -sfn "$SHARE/current/bin/agent-bus" "$BINDIR/agent-bus"
say "installed agent-bus $label"
say "  cli: $BINDIR/agent-bus -> $SHARE/current"

# Older versions, beyond the two most recent, are removed.
if [ -z "$from" ]; then
  # shellcheck disable=SC2012
  ls -1t "$SHARE/versions" | tail -n +3 | while read -r old; do
    [ "$SHARE/versions/$old" = "$target" ] || rm -rf "${SHARE:?}/versions/$old"
  done
fi

if ((hooks)); then
  flags=$(host_flags)
  if [ -n "$flags" ]; then
    say ""
    # shellcheck disable=SC2086
    "$SHARE/current/install-hooks.sh" $flags
  else
    say "no Claude Code, OpenCode or Codex found; install one, then run: agent-bus hooks"
  fi
  command -v python3 >/dev/null 2>&1 || say "note: Codex support needs python3"
fi

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) say ""
     say "$BINDIR is not on your PATH. Add it:"
     say "  fish:     fish_add_path $BINDIR"
     say "  zsh/bash: echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.zshrc" ;;
esac

say ""
say "next: in each repo, run 'agent-bus init' to set the team's rules,"
say "      then type /agent-bus in any agent session."
