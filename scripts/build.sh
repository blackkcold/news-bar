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
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
    </dict>
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
hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${RELEASE_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}" 2>&1

echo "🎨 Setting DMG icon..."
DMG_MOUNT="/Volumes/${APP_NAME}"

# Detach if already mounted
hdiutil detach "${DMG_MOUNT}" -quiet 2>/dev/null || true

# Create writable DMG, set icon, convert to compressed read-only (best-effort)
DMG_RW="${RELEASE_DIR}/${APP_NAME}-${VERSION}-rw.dmg"
hdiutil convert "${DMG_PATH}" -format UDRW -o "${DMG_RW}" -quiet || true
hdiutil attach "${DMG_RW}" -nobrowse -quiet 2>&1 || true
cp Resources/AppIcon.icns "${DMG_MOUNT}/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "${DMG_MOUNT}" 2>/dev/null || xattr -wx com.apple.FinderInfo "0000000000000000000400000000000000000000000000000000000000000000" "${DMG_MOUNT}" 2>/dev/null || true
hdiutil detach "${DMG_MOUNT}" -quiet 2>&1 || true
hdiutil convert "${DMG_RW}" -format UDZO -o "${DMG_PATH}" -quiet || true
rm -f "${DMG_RW}"
echo "   DMG icon applied"

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
