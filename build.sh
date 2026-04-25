#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CameraRecorder"
APP_DIR="$APP_NAME.app"
ROOT="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT"

MODE="${1:-build}"

case "$MODE" in
    clean)
        rm -rf .build "$APP_DIR" CameraRecorder-*.dmg CameraRecorder-*.zip
        echo "Cleaned build artifacts."
        exit 0
        ;;
    build|release) ;;
    *)
        echo "Usage: $0 [build|clean|release]" >&2
        echo "  build   (default) compile, bundle, sign .app" >&2
        echo "  release          build + create signed/notarized DMG" >&2
        echo "  clean            remove .build, .app, and dist artifacts" >&2
        exit 1
        ;;
esac

# --- Resolve signing identity --------------------------------------------------
# Honor SIGN_IDENTITY if set (e.g. "Developer ID Application: Name (TEAMID)").
# Otherwise auto-detect a Developer ID cert in the keychain; fall back to ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    DETECTED=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F\" '/Developer ID Application/ {print $2; exit}' || true)
    if [[ -n "$DETECTED" ]]; then
        SIGN_IDENTITY="$DETECTED"
    else
        SIGN_IDENTITY="-"
    fi
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_KIND="ad-hoc"
    APP_CODESIGN_FLAGS=(--force --deep --sign -)
    DMG_CODESIGN_FLAGS=(--force --sign -)
else
    SIGN_KIND="developer-id"
    APP_CODESIGN_FLAGS=(--force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY")
    DMG_CODESIGN_FLAGS=(--force --timestamp --sign "$SIGN_IDENTITY")
fi

echo "==> Signing identity: $SIGN_IDENTITY ($SIGN_KIND)"

# Always kill any running instance so the next `open` loads the new binary.
killall "$APP_NAME" 2>/dev/null || true

# --- Build ---------------------------------------------------------------------
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign "${APP_CODESIGN_FLAGS[@]}" "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"
echo "==> Built and signed $APP_DIR"

# --- Notarize the .app (only if Developer ID + NOTARY_PROFILE set) -------------
# To enable: store credentials once with
#   xcrun notarytool store-credentials "AC_PASSWORD" \
#       --apple-id "you@example.com" --team-id "TEAMID" \
#       --password "<app-specific-password>"
# Then invoke this script with: NOTARY_PROFILE=AC_PASSWORD ./build.sh release
notarize_bundle() {
    local target="$1"  # path to .app or .dmg
    local kind="$2"    # "app" or "dmg"
    local submit_path="$target"
    local cleanup=""

    if [[ "$kind" == "app" ]]; then
        # notarytool needs a flat archive for .app submissions
        submit_path="${target%.app}-notarize.zip"
        ditto -c -k --keepParent "$target" "$submit_path"
        cleanup="$submit_path"
    fi

    echo "==> Submitting $target for notarization"
    xcrun notarytool submit "$submit_path" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling $target"
    xcrun stapler staple "$target"

    [[ -n "$cleanup" ]] && rm -f "$cleanup"
}

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "$SIGN_KIND" != "developer-id" ]]; then
        echo "WARN: NOTARY_PROFILE is set but app is ad-hoc signed; notarization requires a Developer ID certificate. Skipping."
    else
        notarize_bundle "$APP_DIR" "app"
    fi
fi

if [[ "$MODE" != "release" ]]; then
    echo "Run with: open $APP_DIR"
    exit 0
fi

# --- Build DMG -----------------------------------------------------------------
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="CameraRecorder-${VERSION}.dmg"

echo "==> Building $DMG"
STAGING=$(mktemp -d)
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Camera Recorder" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

codesign "${DMG_CODESIGN_FLAGS[@]}" "$DMG" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_KIND" == "developer-id" ]]; then
    notarize_bundle "$DMG" "dmg"
fi

echo "==> Release artifact: $DMG"
