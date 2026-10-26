#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(tr -d '[:space:]' < version.txt)"
OUTPUT_DIR="${1:-${PROJECT_DIR}/output/v${VERSION}_local-interest-$(date +%Y%m%d-%H%M%S)}"
case "$OUTPUT_DIR/" in
    "$PROJECT_DIR/output/"*) ;;
    *) echo "Output must be a new directory under $PROJECT_DIR/output" >&2; exit 1 ;;
esac
if [ -e "$OUTPUT_DIR" ]; then
    echo "Refusing to overwrite existing output: $OUTPUT_DIR" >&2
    exit 1
fi

# No release cleanup, version bump, remote signing, DMG mounting or publication.
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BUNDLE="$OUTPUT_DIR/NewsBar.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/NewsBar" "$BUNDLE/Contents/MacOS/NewsBar"
cp version.txt "$BUNDLE/Contents/Resources/"
for asset in AppIcon.icns MenuBarIcon.png MenuBarIcon@2x.png; do
    cp "Resources/$asset" "$BUNDLE/Contents/Resources/"
done

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
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --strict --deep --verbose=2 "$BUNDLE"
shasum -a 256 "$BUNDLE/Contents/MacOS/NewsBar" > "$OUTPUT_DIR/NewsBar-binary.sha256"
printf '\nAPP_BUNDLE=%s\nOUTPUT_DIR=%s\n' "$BUNDLE" "$OUTPUT_DIR"
