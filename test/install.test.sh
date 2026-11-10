#!/usr/bin/env bash
# install.sh, update, uninstall: against a local tarball and a throwaway HOME.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "  want: $2
  got:  $3"; fi; }
assert_has() { if grep -Fq -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "  missing: $2
  in: $3"; fi; }
assert_lacks() { if grep -Fq -- "$2" <<<"$3"; then bad "$1" "  unexpected: $2"; else ok "$1"; fi; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for _v in $(env | sed -n 's/^\(AGENT_BUS_[A-Z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
export HOME="$T/home" CODEX_HOME="$T/home/.codex"
export AGENT_BUS_HOME="$T/bus"
export AGENT_BUS_TUI_URL="file://$T/no-such-tui"   # no network: no TUI asset unless a test makes one
mkdir -p "$HOME/.claude" "$AGENT_BUS_HOME"
echo keep >"$AGENT_BUS_HOME/ledger.jsonl"
SHARE="$HOME/.local/share/agent-bus" BINDIR="$HOME/.local/bin"
# Only Claude is "on this machine": hide opencode and codex binaries.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)")"

# A release tarball of this working tree, laid out like GitHub's archives.
tarball() { # name
  mkdir -p "$T/pkg"
  rm -rf "$T/pkg/agent-bus-$1"
  rsync -a --exclude .git --exclude 'agent-bus-tui' "$ROOT/" "$T/pkg/agent-bus-$1/"
  tar -czf "$T/$1.tar.gz" -C "$T/pkg" "agent-bus-$1"
}
tarball 9.9.1; tarball 9.9.2

inst() { AGENT_BUS_DOWNLOAD_URL="file://$T/$1.tar.gz" "$ROOT/install.sh" --version "v$1" "${@:2}"; }

out=$(inst 9.9.1 2>&1)
assert_has "installs the release" "installed agent-bus v9.9.1" "$out"
assert_eq "cli link points at current" "$SHARE/current/bin/agent-bus" "$(readlink "$BINDIR/agent-bus")"
assert_eq "current points at the version" "$SHARE/versions/v9.9.1" "$(readlink "$SHARE/current")"
assert_has "version names the release" "(v9.9.1)" "$("$BINDIR/agent-bus" version)"
hooks=$(jq -r '[.hooks[][].hooks[].command] | join("\n")' "$HOME/.claude/settings.json")
assert_has "claude hooks use the stable path" "$SHARE/current/bin/agent-bus digest" "$hooks"
assert_lacks "claude hooks never pin a version" "versions/" "$hooks"
assert_eq "skill links through current" "$SHARE/current/skills/agent-bus" "$(readlink "$HOME/.claude/skills/agent-bus")"
assert_lacks "opencode not wired when absent" "opencode:" "$out"
assert_has "PATH hint when bin dir is missing from PATH" "fish_add_path" "$out"
assert_eq "no TUI asset, nothing installed for it" "no" "$([ -e "$SHARE/current/bin/agent-bus-tui" ] && echo yes || echo no)"

printf '#!/bin/sh\necho fake-tui\n' >"$T/tui-asset"
out=$(AGENT_BUS_TUI_URL="file://$T/tui-asset" AGENT_BUS_INSTALLER="$ROOT/install.sh" AGENT_BUS_DOWNLOAD_URL="file://$T/9.9.2.tar.gz" \
  "$BINDIR/agent-bus" update --version v9.9.2 2>&1)
assert_has "update installs the new release" "installed agent-bus v9.9.2" "$out"
assert_eq "update flips current" "$SHARE/versions/v9.9.2" "$(readlink "$SHARE/current")"
assert_eq "the release's TUI binary is installed beside the CLI" "fake-tui" "$("$SHARE/current/bin/agent-bus-tui" 2>&1)"
assert_eq "hooks unchanged by update" "$hooks" "$(jq -r '[.hooks[][].hooks[].command] | join("\n")' "$HOME/.claude/settings.json")"
n=$(jq '[.hooks[][].hooks[].command | select(contains("agent-bus-managed"))] | length' "$HOME/.claude/settings.json")
assert_eq "re-install does not duplicate hooks" 6 "$n"

"$BINDIR/agent-bus" hooks --claude >/dev/null
assert_eq "agent-bus hooks keeps the stable path" "$hooks" "$(jq -r '[.hooks[][].hooks[].command] | join("\n")' "$HOME/.claude/settings.json")"
assert_eq "agent-bus hooks keeps the skill on current" "$SHARE/current/skills/agent-bus" "$(readlink "$HOME/.claude/skills/agent-bus")"

tarball 9.9.3; inst 9.9.3 >/dev/null 2>&1
assert_eq "keeps only the two newest versions" "v9.9.2 v9.9.3" "$(ls "$SHARE/versions" | sort | tr '\n' ' ' | sed 's/ $//')"

out=$("$ROOT/bin/agent-bus" update 2>&1 || true)
assert_has "a checkout refuses update" "git pull" "$out"

out=$(PATH="$BINDIR:$PATH" "$BINDIR/agent-bus" uninstall 2>&1)
assert_has "uninstall removes the install" "removed $SHARE" "$out"
[ ! -e "$BINDIR/agent-bus" ] && ok "uninstall removes the cli link" || bad "uninstall removes the cli link" "still there"
[ ! -e "$SHARE" ] && ok "uninstall removes the install dir" || bad "uninstall removes the install dir" "still there"
assert_eq "uninstall removes claude hooks" 0 "$(jq '[.hooks // {} | .. | .command? // empty | select(contains("agent-bus"))] | length' "$HOME/.claude/settings.json")"
[ ! -e "$HOME/.claude/skills/agent-bus" ] && ok "uninstall removes the skill" || bad "uninstall removes the skill" "still there"
assert_eq "uninstall never touches the bus" keep "$(cat "$AGENT_BUS_HOME/ledger.jsonl")"

out=$("$ROOT/install.sh" --from "$ROOT" --no-hooks 2>&1)
assert_has "--from uses a checkout in place" "(local checkout)" "$out"
assert_eq "--from points current at the checkout" "$ROOT" "$(readlink "$SHARE/current")"

out=$(AGENT_BUS_DOWNLOAD_URL="file://$T/missing.tar.gz" "$ROOT/install.sh" --version v0 2>&1 || true)
assert_has "a failed download says so" "download failed" "$out"

# A fresh machine: claude is on PATH but has never run (no ~/.claude yet).
H2="$T/home2"; mkdir -p "$H2" "$T/fakebin"; printf '#!/bin/sh\n' >"$T/fakebin/claude"; chmod +x "$T/fakebin/claude"
out=$(HOME="$H2" PATH="$T/fakebin:$PATH" AGENT_BUS_DOWNLOAD_URL="file://$T/9.9.1.tar.gz" "$ROOT/install.sh" --version v9.9.1 2>&1) \
  && ok "installs before claude has ever run" || bad "installs before claude has ever run" "$out"
assert_eq "creates claude settings with hooks" 6 "$(jq '[.hooks[][].hooks[].command] | length' "$H2/.claude/settings.json" 2>/dev/null || echo 0)"

# Homebrew: the keg path changes every upgrade; hooks must use opt/.
B="$(cd "$T" && pwd -P)/brew"
mkdir -p "$B/Cellar/agent-bus/1.0" "$B/bin" "$B/opt"
rsync -a --exclude .git "$ROOT/" "$B/Cellar/agent-bus/1.0/libexec/"
ln -s ../Cellar/agent-bus/1.0 "$B/opt/agent-bus"
ln -s ../Cellar/agent-bus/1.0/libexec/bin/agent-bus "$B/bin/agent-bus"
"$B/bin/agent-bus" hooks --claude >/dev/null
assert_has "brew hooks use the opt path" "$B/opt/agent-bus/libexec/bin/agent-bus digest" \
  "$(jq -r '[.hooks[][].hooks[].command] | join("\n")' "$HOME/.claude/settings.json")"
assert_eq "brew skill uses the opt path" "$B/opt/agent-bus/libexec/skills/agent-bus" "$(readlink "$HOME/.claude/skills/agent-bus")"
assert_has "brew refuses update" "brew upgrade agent-bus" "$("$B/bin/agent-bus" update 2>&1 || true)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
