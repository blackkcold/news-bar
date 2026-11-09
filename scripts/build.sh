#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

ADHOC=0
for arg in "$@"; do
    case "$arg" in
        --adhoc)
            ADHOC=1
            ;;
        -h|--help)
            echo "Usage: scripts/build.sh [--adhoc]"
            echo "  --adhoc  Local-only build with an ad-hoc signature; never publishable."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

VERSION=$(cat version.txt | tr -d '[:space:]')
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ version.txt must contain a semantic version (got '${VERSION}')" >&2
    exit 1
fi
APP_NAME="NewsBar"
BUNDLE_ID="com.newsbar.app"
RELEASE_DIR="release/${VERSION}"
BUNDLE_DIR="${RELEASE_DIR}/${APP_NAME}.app"

if [ "$ADHOC" -eq 0 ]; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    case "$BRANCH" in
        release/*) ;;
        *)
            echo "❌ A publishable build must run from release/* (current: ${BRANCH})" >&2
            echo "   Use --adhoc for a local-only build." >&2
            exit 1
            ;;
    esac
    if ! git diff --quiet || ! git diff --cached --quiet; then
        echo "❌ Worktree is not clean; commit or stash before building a release." >&2
        exit 1
    fi
    if ! git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
        echo "❌ Tag v${VERSION} does not exist." >&2
        exit 1
    fi
    TAG_COMMIT=$(git rev-list -n1 "v${VERSION}")
    HEAD_COMMIT=$(git rev-parse HEAD)
    if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
        echo "❌ v${VERSION} points to ${TAG_COMMIT:0:7}, but HEAD is ${HEAD_COMMIT:0:7}." >&2
        echo "   Tag the exact commit that will be published." >&2
        exit 1
    fi
fi

echo "🔨 Building NewsBar v${VERSION}..."

rm -rf .build/release
mkdir -p "${RELEASE_DIR}"
rm -rf "${BUNDLE_DIR}"

swift build -c release --arch arm64 2>&1

echo "📦 Creating app bundle..."

mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp .build/release/NewsBar "${BUNDLE_DIR}/Contents/MacOS/"
cp version.txt "${BUNDLE_DIR}/Contents/Resources/"
cp Resources/AppIcon.icns "${BUNDLE_DIR}/Contents/Resources/"

BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
RESOURCE_BUNDLE="${BIN_DIR}/NewsBar_NewsBar.bundle"  # keep in sync with RecommendationGuide.resourceBundleName
if [ ! -d "${RESOURCE_BUNDLE}" ]; then
    echo "Missing SwiftPM resource bundle: ${RESOURCE_BUNDLE}" >&2
    exit 1
fi
cp -R "${RESOURCE_BUNDLE}" "${BUNDLE_DIR}/Contents/Resources/"

cat > "${BUNDLE_DIR}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>NewsBar</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${BUNDLE_DIR}/Contents/Info.plist")
if [ "$PLIST_VERSION" != "$VERSION" ]; then
    echo "❌ Info.plist version ${PLIST_VERSION} does not match version.txt ${VERSION}" >&2
    exit 1
fi

echo "🔏 Signing..."
echo ""

# NEWSBAR_SIGN_IDENTITY — Developer ID Application identity. Required for a
# publishable build; --adhoc is the explicit local-only opt-out.
if [ "$ADHOC" -eq 1 ]; then
    echo "⚠️  --adhoc: local-only signature. This build cannot be published."
    codesign --force --deep --sign - "${BUNDLE_DIR}"
else
    if [ -z "${NEWSBAR_SIGN_IDENTITY:-}" ]; then
        echo "❌ NEWSBAR_SIGN_IDENTITY is required for a publishable build." >&2
        echo "   Use --adhoc only for a local build." >&2
        exit 1
    fi
    echo "   Identity: ${NEWSBAR_SIGN_IDENTITY}"
    codesign --force --deep \
        --sign "${NEWSBAR_SIGN_IDENTITY}" \
        --options runtime --timestamp \
        "${BUNDLE_DIR}"
    codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"
fi


echo "📦 Creating DMG..."

DMG_PATH="${RELEASE_DIR}/${APP_NAME}-${VERSION}.dmg"
DMG_RW="${RELEASE_DIR}/${APP_NAME}-${VERSION}-rw.dmg"
DMG_STAGING="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-dmg.XXXXXX")"
DMG_MOUNT="/Volumes/${APP_NAME}"

cleanup_dmg_artifacts() {
    hdiutil detach "${DMG_MOUNT}" -quiet 2>/dev/null || true
    rm -rf "${DMG_STAGING}" "${DMG_RW}"
}
trap cleanup_dmg_artifacts EXIT

mkdir -p "${DMG_STAGING}/.background"
cp -R "${BUNDLE_DIR}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
cp Resources/DMGBackground.png "${DMG_STAGING}/.background/DMGBackground.png"

hdiutil detach "${DMG_MOUNT}" -quiet 2>/dev/null || true
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGING}" \
    -ov -format UDRW \
    "${DMG_RW}" 2>&1
hdiutil attach "${DMG_RW}" -nobrowse -quiet

# Finder can race the mount; wait for the volume before styling it.
for _ in {1..20}; do
    [ -d "${DMG_MOUNT}" ] && break
    sleep 0.5
done
if [ ! -d "${DMG_MOUNT}" ]; then
    echo "❌ DMG volume did not mount at ${DMG_MOUNT}" >&2
    exit 1
fi

cp Resources/AppIcon.icns "${DMG_MOUNT}/.VolumeIcon.icns"
SetFile -a C "${DMG_MOUNT}" 2>/dev/null || \
    xattr -wx com.apple.FinderInfo "0000000000000000000400000000000000000000000000000000000000000000" "${DMG_MOUNT}"
SetFile -a V "${DMG_MOUNT}/.background" 2>/dev/null || true

# Cosmetic layout only: a Finder/automation failure must not invalidate the DMG.
if ! osascript - "${APP_NAME}" "${APP_NAME}.app" <<'APPLESCRIPT'
on run argv
    set diskName to item 1 of argv
    set appName to item 2 of argv
    tell application "Finder"
        tell disk diskName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {100, 100, 900, 500}
            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 96
            set text size of viewOptions to 13
            set background picture of viewOptions to file ".background:DMGBackground.png"
            set position of item appName to {200, 200}
            set position of item "Applications" to {600, 200}
            update without registering applications
            close
        end tell
    end tell
end run
APPLESCRIPT
then
    echo "⚠️  Finder layout skipped; DMG content remains valid."
fi

sleep 1
hdiutil detach "${DMG_MOUNT}" -quiet
hdiutil convert "${DMG_RW}" -format UDZO -imagekey zlib-level=9 -ov -o "${DMG_PATH}" -quiet
rm -rf "${DMG_STAGING}" "${DMG_RW}"
trap - EXIT
echo "   Custom layout: NewsBar.app → Applications"

if [ "$ADHOC" -eq 0 ]; then
    echo "🧾 Notarizing..."
    codesign --force --timestamp --sign "${NEWSBAR_SIGN_IDENTITY}" "${DMG_PATH}"
    NOTARY_ARGS=(--wait)
    if [ -n "${NEWSBAR_NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS+=(--keychain-profile "${NEWSBAR_NOTARY_PROFILE}")
    elif [ -n "${NEWSBAR_NOTARY_APPLE_ID:-}" ] \
        && [ -n "${NEWSBAR_NOTARY_TEAM_ID:-}" ] \
        && [ -n "${NEWSBAR_NOTARY_PASSWORD:-}" ]; then
        NOTARY_ARGS+=(
            --apple-id "${NEWSBAR_NOTARY_APPLE_ID}"
            --team-id "${NEWSBAR_NOTARY_TEAM_ID}"
            --password "@env:NEWSBAR_NOTARY_PASSWORD"
        )
    else
        echo "❌ Notarization credentials missing." >&2
        echo "   Set NEWSBAR_NOTARY_PROFILE (notarytool keychain profile) or" >&2
        echo "   NEWSBAR_NOTARY_APPLE_ID / NEWSBAR_NOTARY_TEAM_ID / NEWSBAR_NOTARY_PASSWORD." >&2
        exit 1
    fi
    xcrun notarytool submit "${DMG_PATH}" "${NOTARY_ARGS[@]}"
    xcrun stapler staple "${DMG_PATH}"
    xcrun stapler validate "${DMG_PATH}"
    spctl -a -vv -t open --context context:primary-signature "${DMG_PATH}"
    hdiutil verify "${DMG_PATH}"
fi

rm -rf release/latest
ln -sfn "${VERSION}" release/latest

cat > release/versions.json << VJSON
[
    {"version": "${VERSION}", "date": "$(date -u +%Y-%m-%d)", "file": "${APP_NAME}-${VERSION}.dmg"}
]
VJSON

echo ""
echo "✅ Build complete!"
echo "   App:  ${BUNDLE_DIR}"
echo "   DMG:  ${DMG_PATH}"
ls -lh "${DMG_PATH}"

echo "🔐 Generating SHA256..."
shasum -a 256 "${DMG_PATH}" | awk '{print $1}' > "${DMG_PATH}.sha256"
echo "   SHA256: $(cat ${DMG_PATH}.sha256)"
