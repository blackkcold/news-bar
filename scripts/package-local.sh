#!/bin/bash
set -euo pipefail

# Local verification build — canonical output only:
#   release/<version>/NewsBar.app
#
# This helper intentionally does NOT create a DMG and does NOT update
# release/latest, release/versions.json or any published release artifact.
# Do not add an output/ directory: ad-hoc package paths are deprecated.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="$(tr -d '[:space:]' < version.txt)"
RELEASE_DIR="${PROJECT_DIR}/release/${VERSION}"
BUNDLE="${RELEASE_DIR}/NewsBar.app"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help)
            echo "Usage: bash scripts/package-local.sh [--force]"
            echo "Output: release/${VERSION}/NewsBar.app"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Local packages must use release/${VERSION}/NewsBar.app." >&2
            exit 2
            ;;
    esac
done

if [ -e "$BUNDLE" ] && [ "$FORCE" -ne 1 ]; then
    echo "Refusing to overwrite existing bundle: $BUNDLE" >&2
    echo "Re-run with --force after confirming it is a local build." >&2
    exit 1
fi

if [ -e "$BUNDLE" ]; then
    echo "Replacing existing local bundle: $BUNDLE"
    rm -rf "$BUNDLE"
fi

mkdir -p "$RELEASE_DIR"

# No release cleanup, version bump, remote signing, DMG mounting or publication.
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/NewsBar" "$BUNDLE/Contents/MacOS/NewsBar"
cp version.txt "$BUNDLE/Contents/Resources/"
for asset in AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png; do
    cp "Resources/$asset" "$BUNDLE/Contents/Resources/"
done

RESOURCE_BUNDLE="$BIN_DIR/NewsBar_NewsBar.bundle"  # keep in sync with RecommendationGuide.resourceBundleName
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$BUNDLE/Contents/Resources/"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>NewsBar</string>
    <key>CFBundleIdentifier</key><string>com.newsbar.app</string>
    <key>CFBundleName</key><string>NewsBar</string>
    <key>CFBundleDisplayName</key><string>NewsBar</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --strict --deep --verbose=2 "$BUNDLE"

# Relative path so `shasum -a 256 -c` works from the project root.
(
    cd "$PROJECT_DIR"
    shasum -a 256 "release/${VERSION}/NewsBar.app/Contents/MacOS/NewsBar"
) > "$RELEASE_DIR/NewsBar-binary.sha256"

printf '\nAPP_BUNDLE=%s\nOUTPUT_DIR=%s\nSHA256_FILE=%s\n' \
    "$BUNDLE" "$RELEASE_DIR" "$RELEASE_DIR/NewsBar-binary.sha256"
