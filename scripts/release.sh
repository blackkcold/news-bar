#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

ALLOW_ADHOC=0
for arg in "$@"; do
    case "$arg" in
        --allow-adhoc)
            ALLOW_ADHOC=1
            ;;
        -h|--help)
            echo "Usage: scripts/release.sh [--allow-adhoc]"
            echo "  --allow-adhoc  Publish a local ad-hoc build. Gatekeeper will require"
            echo "                 right-click → Open on first launch; never notarized."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

VERSION=$(cat version.txt | tr -d '[:space:]')
DMG_FILE="release/${VERSION}/NewsBar-${VERSION}.dmg"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ version.txt must contain a semantic version (got '${VERSION}')" >&2
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
case "$BRANCH" in
    release/*) ;;
    *)
        echo "❌ Releases must run from release/* (current: ${BRANCH})" >&2
        exit 1
        ;;
esac

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "❌ Worktree is not clean; commit or stash before releasing." >&2
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

EXPECTED_SHA=$(cat "${DMG_FILE}.sha256")
ACTUAL_SHA=$(shasum -a 256 "$DMG_FILE" | awk '{print $1}')
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "❌ DMG SHA256 does not match ${DMG_FILE}.sha256" >&2
    exit 1
fi

APP_BUNDLE="release/${VERSION}/NewsBar.app"
if [ -d "$APP_BUNDLE" ]; then
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    if codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
        if [ "$ALLOW_ADHOC" -ne 1 ]; then
            echo "❌ The app is ad-hoc signed and cannot be published." >&2
            echo "   Pass --allow-adhoc only when you explicitly accept an unnotarized build." >&2
            exit 1
        fi
        echo "⚠️  Publishing an ad-hoc signed, unnotarized build (explicit override)."
    fi
fi

if [ "$ALLOW_ADHOC" -eq 1 ]; then
    echo "⚠️  Skipping Gatekeeper and stapler checks for the ad-hoc build."
else
    spctl -a -vv -t open --context context:primary-signature "$DMG_FILE"
    xcrun stapler validate "$DMG_FILE"
fi
hdiutil verify "$DMG_FILE"

TEMP_NOTES=$(mktemp "${TMPDIR:-/tmp}/newsbar-release-notes.XXXXXX")

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

if [ "$ALLOW_ADHOC" -eq 1 ]; then
    {
        echo ""
        echo "---"
        echo ""
        echo "⚠️ **签名说明**：本版为 adhoc 签名，未经过 Apple 公证。首次打开如被 Gatekeeper 拦截，请在 Finder 中右键 App → 打开。"
        echo ""
        echo "⚠️ **Signing note**: This build is ad-hoc signed and not notarized. If Gatekeeper blocks the first launch, right-click the app in Finder → Open."
    } >> "$TEMP_NOTES"
fi

if command -v gh &> /dev/null; then
    echo "📦 Creating GitHub Release v$VERSION..."
    gh release create "v$VERSION" \
        --verify-tag \
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
