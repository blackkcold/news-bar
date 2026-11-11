#!/bin/bash
set -euo pipefail

# Local verification build — canonical output only:
#   release/<version>/NewsBar.app
#
# This helper intentionally does NOT create a DMG and does NOT update
# release/latest or any published release artifact.
# Do not add an output/ directory: ad-hoc package paths are deprecated.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"
# shellcheck source=lib/signing.sh
source "${PROJECT_DIR}/scripts/lib/signing.sh"

VERSION="$(tr -d '[:space:]' < version.txt)"
RELEASE_DIR="${PROJECT_DIR}/release/${VERSION}"
BUNDLE="${RELEASE_DIR}/${APP_NAME}.app"
FORCE=0
FORCE_ADHOC=0

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --adhoc) FORCE_ADHOC=1 ;;
        -h|--help)
            echo "Usage: bash scripts/package-local.sh [--force] [--adhoc]"
            echo "Output: release/${VERSION}/NewsBar.app"
            echo "  --force  Replace an existing local bundle."
            echo "  --adhoc  Sign ad-hoc even when the fixed identity is available."
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

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/NewsBar" "$BUNDLE/Contents/MacOS/NewsBar"
cp "$BIN_DIR/newsbarctl" "$BUNDLE/Contents/MacOS/newsbarctl"
cp version.txt "$BUNDLE/Contents/Resources/"
for asset in AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png; do
    cp "Resources/$asset" "$BUNDLE/Contents/Resources/"
done

RESOURCE_BUNDLE="$BIN_DIR/NewsBar_NewsBar.bundle"  # keep in sync with RecommendationGuide.resourceBundleName
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
ditto "$RESOURCE_BUNDLE" "$BUNDLE/Contents/Resources/NewsBar_NewsBar.bundle"

newsbar_embed_sparkle "$BIN_DIR" "$BUNDLE"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>NewsBar</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key><string>${SU_FEED_URL}</string>
    <key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>
    <key>SURequireSignedFeed</key><true/>
</dict></plist>
PLIST

plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null

if [ "$FORCE_ADHOC" -eq 0 ] && newsbar_signing_material_available; then
    trap newsbar_close_signing_keychain EXIT
    newsbar_open_signing_keychain
    newsbar_sign_app "$BUNDLE"
else
    echo "⚠️  Signing ad-hoc; the fixed identity is unavailable or disabled."
    codesign --force --sign - "$BUNDLE/Contents/MacOS/newsbarctl"
    codesign --force --sign - "$BUNDLE"
    codesign --verify --strict --deep --verbose=2 "$BUNDLE"
fi

# Relative path so `shasum -a 256 -c` works from the project root.
(
    cd "$PROJECT_DIR"
    shasum -a 256 "release/${VERSION}/NewsBar.app/Contents/MacOS/NewsBar"
) > "$RELEASE_DIR/NewsBar-binary.sha256"

printf '\nAPP_BUNDLE=%s\nOUTPUT_DIR=%s\nSHA256_FILE=%s\n' \
    "$BUNDLE" "$RELEASE_DIR" "$RELEASE_DIR/NewsBar-binary.sha256"
