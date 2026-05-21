#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION=$(cat version.txt | tr -d '[:space:]')
DMG_FILE="release/${VERSION}/NewsBar-${VERSION}.dmg"

if [ ! -f "$DMG_FILE" ]; then
    echo "❌ DMG not found: $DMG_FILE"
    echo "   Run scripts/build.sh first"
    exit 1
fi

TEMP_NOTES="/tmp/newsbar-release-notes.md"

PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "v$VERSION" ]; then
    echo "## Changes since $PREV_TAG" > "$TEMP_NOTES"
    echo "" >> "$TEMP_NOTES"
    git log "$PREV_TAG..HEAD" --oneline --no-merges | sed 's/^/- /' >> "$TEMP_NOTES"
else
    echo "## NewsBar v$VERSION" > "$TEMP_NOTES"
    echo "" >> "$TEMP_NOTES"
    git log --oneline --no-merges -20 | sed 's/^/- /' >> "$TEMP_NOTES"
fi

if command -v gh &> /dev/null; then
    echo "📦 Creating GitHub Release v$VERSION..."
    gh release create "v$VERSION" \
        --title "NewsBar v$VERSION" \
        --notes-file "$TEMP_NOTES" \
        "$DMG_FILE"
    echo "✅ Release created: v$VERSION"
else
    echo "⚠️  gh CLI not installed. Install it with: brew install gh"
    echo "   Release notes saved to: $TEMP_NOTES"
    echo "   DMG ready at: $DMG_FILE"
fi
