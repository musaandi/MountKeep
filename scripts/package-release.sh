#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="MountKeep"

cd "$PROJECT_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
DIST_DIR="$PROJECT_DIR/dist"
ZIP_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}.zip"

echo "==> Building $APP_NAME v$VERSION (release)..."
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: release binary not found at $BIN_PATH" >&2
    exit 1
fi

STAGE_TMP="$(mktemp -d)"
trap 'rm -rf "$STAGE_TMP"' EXIT
STAGED_APP="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

cp "$BIN_PATH" "$STAGED_APP/Contents/MacOS/$APP_NAME"
chmod +x "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/CHANGELOG.md" "$STAGED_APP/Contents/Resources/CHANGELOG.md"

if [[ -f "$HOME/Applications/$APP_NAME.app/Contents/Resources/AppIcon.icns" ]]; then
    cp "$HOME/Applications/$APP_NAME.app/Contents/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Ad-hoc code signing $STAGED_APP (public release archive — no personal cert)..."
codesign --force --deep --sign - "$STAGED_APP"

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" "$ZIP_PATH"
echo "==> Packaged release archive: $ZIP_PATH"
