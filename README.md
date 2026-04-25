# Camera Recorder

A native macOS camera app built with SwiftUI and AVFoundation. Lets you preview any connected camera, take photos (JPEG/PNG), and record video (MP4/MOV) with selectable resolution and frame rate.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.9+ (bundled with recent Xcode / CLT)

## Build

From the project root:

```bash
./build.sh
```

This will:
1. Compile a release binary with `swift build -c release`.
2. Assemble `CameraRecorder.app` (binary + `Info.plist` + `AppIcon.icns`).
3. Ad-hoc codesign it so macOS keeps your camera/microphone permission across launches.

For a fully clean rebuild (wipes `.build/` and the existing `.app`):

```bash
./build.sh clean
```

The script kills any running `CameraRecorder` process before rebuilding so the next launch picks up the new binary (`open` would otherwise just refocus the old one).

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
- [open_app.sh](open_app.sh) — launches the built `.app`.
