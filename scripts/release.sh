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

if [ ! -f "${DMG_FILE}.sha256" ]; then
    echo "❌ SHA256 file not found: ${DMG_FILE}.sha256"
    echo "   Run the updated scripts/build.sh first"
    exit 1
fi

TEMP_NOTES="/tmp/newsbar-release-notes.md"

# ── Generate structured-cn Release Notes ──

# Resolve previous tag (skip current version tag if bump-version already created it)
PREV_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" = "v$VERSION" ]; then
    PREV_TAG=$(git tag --sort=-creatordate | grep -v "v$VERSION" | head -1 2>/dev/null || echo "")
fi

if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "v$VERSION" ]; then
    COMMIT_RANGE="$PREV_TAG..HEAD"
else
    COMMIT_RANGE="HEAD~20..HEAD"
fi

# Temporary files for sections
SEC_DIR=$(mktemp -d)
for s in fix feat refactor docs perf test ci build chore release security other; do
    : > "$SEC_DIR/$s"
done

# Parse and categorize each commit message
while IFS= read -r msg; do
    [ -z "$msg" ] && continue
    # Skip pure version-bump commits
    echo "$msg" | grep -qiE '^(chore|release):\s*bump version' && continue

    # Extract conventional-commit prefix (lowercased)
    prefix=$(echo "$msg" | sed -nE 's/^([a-z]+)[:(].*/\1/p' | tr '[:upper:]' '[:lower:]')
    # Strip prefix marker and trailing period (macOS-compatible: [[:space:]] not \\s)
    clean_msg=$(echo "$msg" | sed -E 's/^[a-z]+[:(][[:space:]]*//i' | sed 's/\.$//')
    # Capitalise first letter
    clean_msg="$(echo "${clean_msg:0:1}" | tr '[:lower:]' '[:upper:]')${clean_msg:1}"

    case "$prefix" in
        fix|bugfix|hotfix) sec="fix" ;;
        feat)             sec="feat" ;;
        refactor)         sec="refactor" ;;
        docs)             sec="docs" ;;
        perf)             sec="perf" ;;
        test|tests)       sec="test" ;;
        ci)               sec="ci" ;;
        build)            sec="build" ;;
        chore)            sec="chore" ;;
        release)          sec="release" ;;
        security)         sec="security" ;;
        *)                sec="other" ;;
    esac
    echo "- $clean_msg" >> "$SEC_DIR/$sec"
done < <(git log "$COMMIT_RANGE" --no-merges --format="%s")

# Title
echo "# NewsBar v$VERSION" > "$TEMP_NOTES"
echo "" >> "$TEMP_NOTES"

# Emit non-empty sections in priority order
emit_section() {
    local file="$SEC_DIR/$1"
    if [ -s "$file" ]; then
        echo "$2 $3" >> "$TEMP_NOTES"
        cat "$file" >> "$TEMP_NOTES"
        echo "" >> "$TEMP_NOTES"
    fi
}
emit_section feat     "✨" "新增 / 新功能"
emit_section fix      "🐛" "修复"
emit_section security "🔐" "安全"
emit_section perf     "⚡" "性能优化"
emit_section refactor "♻️" "重构"
emit_section test     "✅" "测试"
emit_section docs     "📝" "文档"
emit_section ci       "🔄" "CI/CD"
emit_section build    "📦" "构建"
emit_section chore    "🔧" "杂项 / 改进"
emit_section release  "🚀" "发布"
emit_section other    "🔧" "其他"

# Full Changelog link
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "v$VERSION" ]; then
    echo "---" >> "$TEMP_NOTES"
    echo "" >> "$TEMP_NOTES"
    echo "**Full Changelog**: compare/$PREV_TAG...v$VERSION" >> "$TEMP_NOTES"
else
    echo "---" >> "$TEMP_NOTES"
    echo "" >> "$TEMP_NOTES"
    echo "**Full Changelog**: compare/v$VERSION" >> "$TEMP_NOTES"
fi

rm -rf "$SEC_DIR"

if command -v gh &> /dev/null; then
    echo "📦 Creating GitHub Release v$VERSION..."
    gh release create "v$VERSION" \
        --title "NewsBar v$VERSION" \
        --notes-file "$TEMP_NOTES" \
        "$DMG_FILE" \
        "${DMG_FILE}.sha256"
    echo "✅ Release created: v$VERSION"
else
    echo "⚠️  gh CLI not installed. Install it with: brew install gh"
    echo "   Release notes saved to: $TEMP_NOTES"
    echo "   DMG ready at: $DMG_FILE"
fi
