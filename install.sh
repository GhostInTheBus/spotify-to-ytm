#!/bin/bash
# Builds the menu bar app into /Applications and starts it at login.
set -e
cd "$(dirname "$0")"
APP="/Applications/Spotify to YTM.app"
PLIST="$HOME/Library/LaunchAgents/com.ghostinthebus.spotify-to-ytm.plist"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O SpotifyToYTM.swift -o "$APP/Contents/MacOS/SpotifyToYTM"
codesign --force --deep --sign - "$APP"
mkdir -p "$HOME/Library/LaunchAgents"
cp com.ghostinthebus.spotify-to-ytm.plist "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
echo "Installed. Copy a Spotify link to try it."
