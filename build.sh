#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CameraRecorder"
APP_DIR="$APP_NAME.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT"

# Optional: ./build.sh clean → wipe SwiftPM cache for a fully fresh build.
if [[ "${1-}" == "clean" ]]; then
    rm -rf .build "$APP_DIR"
fi

# Always kill any running instance so the next `open` loads the new binary
# (`open` on macOS just focuses the existing process otherwise).
killall "$APP_NAME" 2>/dev/null || true

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so TCC remembers camera/mic permissions across launches.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
echo "Run with: open $APP_DIR"
