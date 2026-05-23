#!/usr/bin/env bash
#
# Bundle the SwiftPM MiniDumpTruck executable into a macOS .app and
# wrap it in a DMG suitable for ad-hoc sharing.
#
# Usage:
#   scripts/build-app.sh [VERSION]
#
# If VERSION is omitted, falls back to the value already in Info.plist
# (useful when iterating locally without a tag).
#
# Outputs under build/release/:
#   - MiniDumpTruck.app
#   - MiniDumpTruck-<version>-arm64.dmg
#
# Constraints / non-goals:
#   - Ad-hoc codesign only (`codesign --sign -`). Recipients will see
#     Gatekeeper's "cannot verify developer" prompt on first launch and
#     must right-click → Open. Full Developer ID + notarization is
#     issue #5.
#   - Apple Silicon (arm64) only. Universal binaries are a separate
#     concern, deferred until any actual Intel user reports a need.
#   - Sandbox entitlements are preserved from the committed file. The
#     `user-selected.read-only` grant covers NSOpenPanel +
#     drag-and-drop, which is the only file access pattern the app
#     actually uses.

set -euo pipefail

VERSION="${1:-}"
APP_NAME="MiniDumpTruck"
BUNDLE_ID="com.github.jloutsch.minidumptruck"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC_DIR="$REPO_ROOT/App"
INFO_PLIST_SRC="$APP_SRC_DIR/MiniDumpTruck/Info.plist"
ENTITLEMENTS="$APP_SRC_DIR/MiniDumpTruck/MiniDumpTruck.entitlements"
ICON_SRC="$APP_SRC_DIR/AppIcon.icns"

BUILD_DIR="$REPO_ROOT/build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "→ Cleaning previous build output"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "→ Building Swift package (release, arm64)"
(cd "$APP_SRC_DIR" && swift build -c release --arch arm64 --product "$APP_NAME")

BINARY="$APP_SRC_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: expected binary at $BINARY but it's missing or not executable" >&2
    exit 1
fi

echo "→ Assembling $APP_NAME.app bundle"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"

if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
    echo "WARN: $ICON_SRC missing; bundle will use the default icon"
fi

# Inject version from the tag (or first arg). Use PlistBuddy so we
# never need to know whether the key currently exists.
if [[ -n "$VERSION" ]]; then
    echo "→ Stamping bundle version $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        "$APP_BUNDLE/Contents/Info.plist"
    # CFBundleVersion is the build number — using the same string is
    # fine for ad-hoc distribution and avoids tracking a separate counter.
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
        "$APP_BUNDLE/Contents/Info.plist"
fi

echo "→ Ad-hoc codesigning"
# --timestamp=none: an ad-hoc signature can't be promoted to a
#   notarizable signature anyway, so skipping the Apple timestamp
#   server avoids a CI dependency that occasionally flakes.
# --options runtime: applies Hardened Runtime flags. Enforced by
#   macOS regardless of signing identity.
# --deep: deprecated by Apple but still functional for a single-
#   binary bundle with no embedded frameworks. Kept for now; revisit
#   if Apple removes it.
codesign --force \
    --sign - \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp=none \
    --deep \
    "$APP_BUNDLE"

# Verify the signature is at least internally consistent.
codesign --verify --verbose=2 "$APP_BUNDLE"

# Resolve the version stamped in the plist (in case the caller passed
# none and we're reading the committed default) for the DMG filename.
EFFECTIVE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$APP_BUNDLE/Contents/Info.plist")
DMG_PATH="$BUILD_DIR/${APP_NAME}-${EFFECTIVE_VERSION}-arm64.dmg"

echo "→ Creating DMG at $DMG_PATH"
# Stage the .app into a clean directory so the DMG's volume root
# contains only the app (not stray dotfiles). Include a symlink to
# /Applications so the recipient can drag-install with one motion
# inside the mounted DMG — the convention every signed Mac DMG uses.
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo
echo "✓ Built $DMG_PATH"
echo "  Recipients on first launch will need to right-click the app"
echo "  → Open (Gatekeeper bypass), then trust it once. Full"
echo "  notarization removes that step; see issue #5."
