#!/usr/bin/env bash
# Build AgentBusBar.app (menu bar only). Usage: app/build.sh [--install] [--open]
#   --install  copy the app to ~/Applications
#   --open     launch it afterwards
set -euo pipefail

cd "$(dirname "$0")"
install=0 open_app=0
for a in "$@"; do
  case "$a" in
    --install) install=1 ;;
    --open) open_app=1 ;;
    *) echo "unknown flag: $a" >&2; exit 1 ;;
  esac
done

swift build -c release
app=build/AgentBusBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/AgentBusBar" "$app/Contents/MacOS/AgentBusBar"
cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentBusBar</string>
  <key>CFBundleDisplayName</key><string>Agent Bus</string>
  <key>CFBundleIdentifier</key><string>com.scottbaggett.agentbusbar</string>
  <key>CFBundleExecutable</key><string>AgentBusBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null
echo "built $(pwd)/$app"

if ((install)); then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/AgentBusBar.app"
  cp -R "$app" "$HOME/Applications/"
  app="$HOME/Applications/AgentBusBar.app"
  echo "installed $app"
fi
((open_app)) && open "$app"
exit 0
