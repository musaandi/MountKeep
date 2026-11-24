#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="MountKeep"
BUNDLE_ID="com.mountkeep.app"
INSTALL_DIR="$HOME/Applications"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$BUNDLE_ID.plist"
LOGS_DIR="$HOME/Library/Logs"
UID_NUM="$(id -u)"

echo "==> Building $APP_NAME (release)..."
cd "$PROJECT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: release binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Stopping any running $APP_NAME instance..."
launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "==> Creating app bundle at $APP_BUNDLE..."
mkdir -p "$INSTALL_DIR" "$LAUNCH_AGENTS_DIR" "$LOGS_DIR"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/CHANGELOG.md" "$APP_BUNDLE/Contents/Resources/CHANGELOG.md"

echo "==> Generating AppIcon.icns..."
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

swift - "$ICONSET" <<'SWIFT'
import AppKit

let outDir = CommandLine.arguments[1]
let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func renderIcon(pixelSize: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize),
        pixelsHigh: Int(pixelSize),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let inset = pixelSize * 0.08
    let cardRect = rect.insetBy(dx: inset, dy: inset)
    let cornerRadius = cardRect.width * 0.22
    let path = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.14, green: 0.45, blue: 0.86, alpha: 1.0),
        NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.56, alpha: 1.0)
    ])
    gradient?.draw(in: path, angle: -90)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    path.lineWidth = max(1, pixelSize * 0.012)
    path.stroke()

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: pixelSize * 0.42, weight: .medium)
    if let sym = NSImage(systemSymbolName: "externaldrive.connected.to.line.below.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.set()
        let symBounds = NSRect(origin: .zero, size: sym.size)
        sym.draw(in: symBounds)
        symBounds.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let drawRect = NSRect(
            x: (pixelSize - sym.size.width) / 2,
            y: (pixelSize - sym.size.height) / 2,
            width: sym.size.width,
            height: sym.size.height
        )
        tinted.draw(in: drawRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (name, size) in sizes {
    if let data = renderIcon(pixelSize: size) {
        try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    }
}
SWIFT

if iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    AppIcon.icns created."
else
    echo "    Warning: iconutil failed, continuing without custom icon."
fi

DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ {print $2; exit}')"
if [[ -n "$DEV_IDENTITY" ]] && codesign --force --deep --sign "$DEV_IDENTITY" "$APP_BUNDLE" 2>/dev/null; then
    echo "==> Code signed $APP_BUNDLE with '$DEV_IDENTITY'."
else
    echo "==> Ad-hoc code signing $APP_BUNDLE..."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Removing any legacy LaunchAgent plist..."
rm -f "$PLIST_PATH"
launchctl disable "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true

echo "==> Registering app bundle with LaunchServices and starting $APP_NAME..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true
open -n "$APP_BUNDLE" --args --enable-login-item

sleep 1.5
if pgrep -x "$APP_NAME" >/dev/null; then
    echo "==> $APP_NAME is installed and running (PID $(pgrep -x "$APP_NAME" | tr '\n' ' '))."
else
    echo "Warning: $APP_NAME did not appear running yet; check $LOGS_DIR/MountKeep.log" >&2
    exit 1
fi
