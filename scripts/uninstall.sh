#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MountKeep"
BUNDLE_ID="com.mountkeep.app"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
PLIST_PATH="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
UID_NUM="$(id -u)"

echo "==> Unregistering Login Item and stopping $APP_NAME..."
if [[ -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME" --unregister-login-item 2>/dev/null || true
fi
launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Removing app bundle and any legacy LaunchAgent plist..."
rm -f "$PLIST_PATH"
rm -rf "$APP_BUNDLE"

echo "==> Uninstalled $APP_NAME. (Config preserved at ~/Library/Application Support/MountKeep/config.json)"
