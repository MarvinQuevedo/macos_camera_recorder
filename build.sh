#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CameraRecorder"
APP_DIR="$APP_NAME.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"

# Ad-hoc sign so TCC remembers camera/mic permissions across launches.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
echo "Run with: open $APP_DIR"
