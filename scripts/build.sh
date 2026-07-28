#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=$(cat version.txt | tr -d '[:space:]')
APP_NAME="NewsBar"
BUNDLE_ID="com.newsbar.app"
RELEASE_DIR="release/${VERSION}"
BUNDLE_DIR="${RELEASE_DIR}/${APP_NAME}.app"

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

echo "🔏 Signing..."
echo ""

# NEWSBAR_SIGN_IDENTITY — env var for stable code signing.
# Set it to a Keychain identity (e.g. "Developer ID Application: Your Name (TEAMID)")
# to avoid repeated Keychain prompts caused by ad-hoc signing.
# Leave unset only for quick local builds; ad-hoc signing may still trigger prompts.
if [ -n "${NEWSBAR_SIGN_IDENTITY:-}" ]; then
    echo "   Identity: ${NEWSBAR_SIGN_IDENTITY}"
    if codesign --force --deep \
        --sign "${NEWSBAR_SIGN_IDENTITY}" \
        --options runtime --timestamp \
        "${BUNDLE_DIR}"; then
        echo "   Signed with runtime + timestamp"
    else
        echo "⚠️  Timestamped signing failed — retrying without timestamp."
        echo "   This is expected for some local self-signed certificates."
        codesign --force --deep \
            --sign "${NEWSBAR_SIGN_IDENTITY}" \
            --options runtime \
            "${BUNDLE_DIR}"
    fi
else
    echo "⚠️  NEWSBAR_SIGN_IDENTITY not set — using ad-hoc signing."
    echo "   This may cause repeated Keychain access prompts."
    echo "   Set NEWSBAR_SIGN_IDENTITY for stable signing."
    codesign --force --deep --sign - "${BUNDLE_DIR}"
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

cp Resources/AppIcon.icns "${DMG_MOUNT}/.VolumeIcon.icns"
SetFile -a C "${DMG_MOUNT}" 2>/dev/null || \
    xattr -wx com.apple.FinderInfo "0000000000000000000400000000000000000000000000000000000000000000" "${DMG_MOUNT}"
SetFile -a V "${DMG_MOUNT}/.background" 2>/dev/null || true

osascript - "${APP_NAME}" "${APP_NAME}.app" <<'APPLESCRIPT'
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

sleep 1
hdiutil detach "${DMG_MOUNT}" -quiet
hdiutil convert "${DMG_RW}" -format UDZO -imagekey zlib-level=9 -ov -o "${DMG_PATH}" -quiet
rm -rf "${DMG_STAGING}" "${DMG_RW}"
trap - EXIT
echo "   Custom layout: NewsBar.app → Applications"

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
