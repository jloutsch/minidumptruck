#!/usr/bin/env bash
#
# Build every macOS release artifact: bundle the SwiftPM MiniDumpTruck
# executable into a .app, wrap it in a DMG, package the CLI as a
# tarball, and write a SHA-256 file beside each.
#
# Usage:
#   scripts/build-app.sh [VERSION]
#
# If VERSION is omitted, falls back to the value already in Info.plist
# (useful when iterating locally without a tag).
#
# Outputs under build/release/:
#   - MiniDumpTruck.app
#   - MiniDumpTruck-<version>-arm64.dmg               + .sha256
#   - minidumptruck-cli-<version>-macos-arm64.tar.gz  + .sha256
#
# The release workflow uploads all four files. Packaging lives here
# rather than inline in .github/workflows/release.yml so it can be run
# and verified locally — that workflow has never executed, so shell
# living only inside it would ship unproven.
#
# Constraints / non-goals:
#   - Ad-hoc codesign only (`codesign --sign -`). Recipients will see
#     Gatekeeper's "cannot verify developer" prompt on first launch and
#     must right-click → Open. Full Developer ID + notarization is
#     issue #5. The CLI binary carries only the ad-hoc signature the
#     toolchain applies automatically (arm64 macOS refuses to run an
#     entirely unsigned Mach-O); it is not signed here either.
#   - Apple Silicon (arm64) only, for both artifacts. Universal
#     binaries are a separate concern, deferred until any actual Intel
#     user reports a need.
#   - Per-artifact .sha256 files, not one aggregate SHA256SUMS. The
#     Linux assets are produced by a different job on a different
#     runner, so a combined manifest would need cross-job coordination.
#     This matches what the Linux job already publishes.
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
# Both staging dirs are declared here and cleaned by a single trap. A
# second `trap ... EXIT` further down would REPLACE this one rather
# than add to it, silently leaking whichever directory it displaced.
CLI_STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR" "$CLI_STAGE_DIR"' EXIT
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

CLI_NAME="minidumptruck-cli"
CLI_ARCHIVE="$BUILD_DIR/${CLI_NAME}-${EFFECTIVE_VERSION}-macos-arm64.tar.gz"

echo "→ Building $CLI_NAME (release, arm64)"
(cd "$APP_SRC_DIR" && swift build -c release --arch arm64 --product "$CLI_NAME")

CLI_BINARY="$APP_SRC_DIR/.build/arm64-apple-macosx/release/$CLI_NAME"
# Same guard the .app binary gets above. Without it a failed or
# relocated build would package nothing and still exit 0, shipping an
# empty asset that nobody notices until a user downloads it.
if [[ ! -x "$CLI_BINARY" ]]; then
    echo "ERROR: expected binary at $CLI_BINARY but it's missing or not executable" >&2
    exit 1
fi

echo "→ Packaging $CLI_ARCHIVE"
# `install` rather than `cp`: it sets the mode explicitly, so the
# extracted binary is 0755 for whoever unpacks it regardless of the
# builder's umask. Staged into its own directory so the tarball's root
# holds the binary alone.
install -m 0755 "$CLI_BINARY" "$CLI_STAGE_DIR/$CLI_NAME"
tar -czf "$CLI_ARCHIVE" -C "$CLI_STAGE_DIR" "$CLI_NAME"

echo "→ Writing SHA-256 checksums"
# `shasum -a 256`, not `sha256sum`: shasum is part of the macOS base
# system, while sha256sum comes from Homebrew coreutils and is not
# something we can count on being present on the release runner. The
# output format is identical, so a user can verify a macOS asset with
# `sha256sum -c` on Linux and vice versa.
#
# Generated from inside BUILD_DIR so each file records a bare
# basename. A checksum file naming a build-machine path verifies fine
# here and fails for every user who downloads it into their own
# directory.
(
    cd "$BUILD_DIR"
    for artifact in "$(basename "$DMG_PATH")" "$(basename "$CLI_ARCHIVE")"; do
        shasum -a 256 "$artifact" > "$artifact.sha256"
        cat "$artifact.sha256"
    done
)

echo
echo "✓ Built $DMG_PATH"
echo "✓ Built $CLI_ARCHIVE"
echo "  Both have a .sha256 beside them; verify with"
echo "  \`shasum -a 256 -c <file>.sha256\`."
echo "  Recipients on first launch will need to right-click the app"
echo "  → Open (Gatekeeper bypass), then trust it once. Full"
echo "  notarization removes that step; see issue #5."
