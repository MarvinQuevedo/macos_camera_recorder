# Camera Recorder

A native macOS camera app built with SwiftUI and AVFoundation. Lets you preview any connected camera, take photos (JPEG/PNG), and record video (MP4/MOV) with selectable resolution and frame rate.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+ (bundled with recent Xcode / CLT)

## Build

From the project root:

```bash
./build.sh           # build + sign .app
./build.sh release   # build + sign .app + produce a DMG (CameraRecorder-<version>.dmg)
./build.sh clean     # wipe .build/, .app, and dist artifacts
```

`build.sh` will:
1. Compile a release binary with `swift build -c release`.
2. Assemble `CameraRecorder.app` (binary + `Info.plist` + `AppIcon.icns`).
3. Codesign it (see [Signing](#signing) below).
4. In `release` mode, also build a DMG with an `/Applications` shortcut.

The script kills any running `CameraRecorder` process before rebuilding so the next launch picks up the new binary (`open` would otherwise just refocus the old one).

## Signing

The script auto-detects what's available in your keychain and falls back gracefully:

| Setup | What you get | Gatekeeper behavior on download |
| --- | --- | --- |
| Nothing (default) | Ad-hoc signature | Blocked — needs `xattr -dr com.apple.quarantine ...` or "Open Anyway" |
| Developer ID cert installed | Hardened-runtime signature | Warning the first time; user can right-click → Open |
| Developer ID + `NOTARY_PROFILE` env var | Signed + notarized + stapled | Opens with no warning, even from internet |

### Using your own Developer ID certificate

Once you have an Apple Developer Program membership ($99/yr) and a **Developer ID Application** certificate installed in your keychain, the script picks it up automatically:

```bash
./build.sh release
# ==> Signing identity: Developer ID Application: Your Name (TEAMID) (developer-id)
```

Override which identity is used (e.g. you have multiple) with:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh release
```

### Adding notarization

Notarization is what makes Gatekeeper open the app silently. Store your Apple ID credentials **once** in the keychain:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "app-specific-password-from-appleid.apple.com"
```

Then build with notarization enabled:

```bash
NOTARY_PROFILE=AC_PASSWORD ./build.sh release
```

The script will:
1. Sign the `.app` with hardened runtime + timestamp.
2. Submit the `.app` (zipped) to Apple's notary service and wait for the verdict.
3. Staple the notarization ticket to `CameraRecorder.app`.
4. Build the DMG with the stapled `.app` inside.
5. Sign and notarize the DMG itself, then staple it.

Result: `CameraRecorder-<version>.dmg` opens on any Mac with no Gatekeeper warning.

## Open / Run

After building:

```bash
open CameraRecorder.app
```

Or use the helper:

```bash
./open_app.sh
```

The first launch will prompt for **Camera** and **Microphone** access (see the usage strings in [Info.plist](Info.plist)). Grant both — the app needs them to preview, take photos, and record audio with video.

## Install

Drag the freshly built bundle into Applications:

```bash
cp -R CameraRecorder.app /Applications/
```

Then launch it from Spotlight, Launchpad, or:

```bash
open -a "Camera Recorder"
```

> Note: the bundle is **ad-hoc signed**, not notarized. On the first launch from `/Applications`, macOS Gatekeeper may show a warning — right-click the app and choose **Open** once to whitelist it.

## Publish a release

`release.sh` wraps `build.sh release` with the GitHub side: it tags the commit, pushes, and creates (or updates) the release with the DMG attached.

```bash
./release.sh                  # use the version already in Info.plist
./release.sh 1.0.2            # bump Info.plist to 1.0.2, commit, then release
NOTARY_PROFILE=AC_PASSWORD ./release.sh   # also notarize the artifact
```

Behavior:
- If a release for `v<version>` exists on GitHub, the DMG asset is replaced (`--clobber`), title/notes left untouched.
- Otherwise a new release is created. Notes come from `RELEASE_NOTES.md` if present; otherwise from `git log` since the previous `v*` tag.
- The build number (`CFBundleVersion`) auto-increments on every bump.

## Reset camera/mic permissions

If permissions get stuck or you want to test the prompt flow again:

```bash
tccutil reset Camera com.example.CameraRecorder
tccutil reset Microphone com.example.CameraRecorder
```

## Project layout

- [Package.swift](Package.swift) — SwiftPM manifest (executable target, macOS 13+).
- [Sources/CameraRecorder/](Sources/CameraRecorder/) — app source (SwiftUI views, `CameraManager`, settings).
- [Info.plist](Info.plist) — bundle metadata and TCC usage strings.
- [Resources/AppIcon.icns](Resources/AppIcon.icns) — app icon.
- [build.sh](build.sh) — build + bundle + sign script.
- [release.sh](release.sh) — bump version, build, and publish a GitHub release.
- [open_app.sh](open_app.sh) — launches the built `.app`.
