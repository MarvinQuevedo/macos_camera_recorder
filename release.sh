#!/usr/bin/env bash
#
# Builds, signs, (optionally) notarizes, and publishes a GitHub release
# from the version declared in Info.plist.
#
# Usage:
#     ./release.sh                  # use version from Info.plist, no bump
#     ./release.sh 1.0.2            # update Info.plist to 1.0.2 first
#     NOTARY_PROFILE=AC_PASSWORD ./release.sh   # also notarize
#
# Behavior:
#   - If a release for v<version> already exists on GitHub: replaces the DMG
#     asset (--clobber), leaves title/notes intact.
#   - Otherwise: creates the tag, pushes it, and creates a new release with
#     notes pulled from RELEASE_NOTES.md (if present) or git log since the
#     previous v* tag.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

NEW_VERSION="${1:-}"

# --- Optional version bump -----------------------------------------------------
if [[ -n "$NEW_VERSION" ]]; then
    if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: version must look like X.Y.Z (got: $NEW_VERSION)" >&2
        exit 1
    fi
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
    NEXT_BUILD=$((CURRENT_BUILD + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" Info.plist
    echo "==> Bumped Info.plist to $NEW_VERSION (build $NEXT_BUILD)"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v$VERSION"
DMG="CameraRecorder-${VERSION}.dmg"

# --- Sanity: must be on a clean branch with origin reachable ------------------
if [[ -n "$(git status --porcelain --untracked-files=no | grep -v '^?? Info.plist$' || true)" ]]; then
    if [[ -n "$NEW_VERSION" ]]; then
        # We just modified Info.plist — commit it.
        git add Info.plist
        git commit -m "Bump version to $VERSION"
        echo "==> Committed version bump"
    else
        echo "WARN: working tree has uncommitted changes; release will reflect HEAD, not your local edits"
    fi
fi

# --- Build + sign + (optional) notarize ---------------------------------------
./build.sh release
[[ -f "$DMG" ]] || { echo "ERROR: $DMG not produced by build.sh" >&2; exit 1; }

# --- Resolve release notes -----------------------------------------------------
NOTES_ARGS=()
if [[ -f "RELEASE_NOTES.md" ]]; then
    NOTES_ARGS=(--notes-file "RELEASE_NOTES.md")
else
    PREV_TAG=$(git tag --list 'v*' --sort=-version:refname | grep -vx "$TAG" | head -1 || true)
    if [[ -n "$PREV_TAG" ]]; then
        RANGE="${PREV_TAG}..HEAD"
        HEADER="## Changes since $PREV_TAG"
    else
        RANGE=""
        HEADER="## Changes"
    fi
    LOG=$(git log --pretty='- %s' ${RANGE:+$RANGE} | grep -v '^- Merge' || true)
    [[ -z "$LOG" ]] && LOG="- No commits since previous tag."
    NOTES=$(printf '%s\n\n%s\n' "$HEADER" "$LOG")
    NOTES_ARGS=(--notes "$NOTES")
fi

# --- Tag + push ---------------------------------------------------------------
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
    git tag -a "$TAG" -m "$TAG"
    echo "==> Created local tag $TAG"
fi
if ! git ls-remote --tags origin "refs/tags/$TAG" | grep -q .; then
    git push origin "$TAG"
    echo "==> Pushed $TAG to origin"
fi

# --- Create or update the GitHub release --------------------------------------
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "==> Release $TAG exists; replacing DMG asset"
    gh release upload "$TAG" "$DMG" --clobber
else
    echo "==> Creating release $TAG"
    gh release create "$TAG" "$DMG" --title "$TAG" "${NOTES_ARGS[@]}"
fi

URL=$(gh release view "$TAG" --json url -q .url)
echo "==> Done: $URL"

# --- Clean local artifacts now that they're published --------------------------
rm -rf CameraRecorder.app CameraRecorder-*.dmg
echo "==> Cleaned local .app and .dmg"
