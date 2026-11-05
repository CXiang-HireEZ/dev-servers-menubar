#!/bin/zsh
# Builds DevServers.app and installs it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"
APP=build/DevServers.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/DevServers" main.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.xiangchen.devservers</string>
  <key>CFBundleName</key><string>DevServers</string>
  <key>CFBundleExecutable</key><string>DevServers</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "${1:-}" == "--install" ]]; then
  pkill -x DevServers || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/DevServers.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/DevServers.app
  echo "Installed and launched ~/Applications/DevServers.app"
fi
