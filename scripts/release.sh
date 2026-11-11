#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"
# shellcheck source=lib/signing.sh
source "${PROJECT_DIR}/scripts/lib/signing.sh"

ALLOW_ADHOC=0
for arg in "$@"; do
    case "$arg" in
        --allow-adhoc)
            ALLOW_ADHOC=1
            ;;
        -h|--help)
            echo "Usage: scripts/release.sh [--allow-adhoc]"
            echo "  --allow-adhoc  Publish a local ad-hoc build. Unsupported: updates still"
            echo "                 verify with EdDSA, but the install is not signed with the"
            echo "                 fixed identity and bypasses every signing guarantee."
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

VERSION=$(cat version.txt | tr -d '[:space:]')
DMG_FILE="release/${VERSION}/${APP_NAME}-${VERSION}.dmg"
APPCAST_FILE="release/${VERSION}/appcast.xml"
ARCHIVE_DIR="${NEWSBAR_APPCAST_DIR:-release/appcast}"

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

if [ ! -f "$APPCAST_FILE" ]; then
    echo "❌ appcast not found: $APPCAST_FILE"
    echo "   Run scripts/appcast.sh after scripts/build.sh"
    exit 1
fi

EXPECTED_SHA=$(cat "${DMG_FILE}.sha256")
ACTUAL_SHA=$(shasum -a 256 "$DMG_FILE" | awk '{print $1}')
if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
    echo "❌ DMG SHA256 does not match ${DMG_FILE}.sha256" >&2
    exit 1
fi

python3 "scripts/verify-appcast.py" "$APPCAST_FILE" "$VERSION"

APP_BUNDLE="release/${VERSION}/${APP_NAME}.app"
if [ -d "$APP_BUNDLE" ]; then
    if codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
        if [ "$ALLOW_ADHOC" -ne 1 ]; then
            echo "❌ The app is ad-hoc signed and cannot be published." >&2
            echo "   Build with the fixed identity, or pass --allow-adhoc explicitly." >&2
            exit 1
        fi
        echo "⚠️  Publishing an ad-hoc signed build (explicit override)."
    else
        SIGN_AUTHORITY=$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | sed -n 's/^Authority=//p' | head -1)
        if [ "$SIGN_AUTHORITY" != "$SIGN_IDENTITY" ]; then
            echo "❌ App is signed by '${SIGN_AUTHORITY:-unknown}', expected '${SIGN_IDENTITY}'." >&2
            exit 1
        fi
        codesign --verify --deep --strict "$APP_BUNDLE"
    fi
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

# RELEASE_NOTES.md is the documented single source for the release body and
# for the in-app update window. Prefer its section for this version; the
# commit-derived notes above stay as a fallback for versions without one.
NOTES_SECTION=$(mktemp "${TMPDIR:-/tmp}/newsbar-release-section.XXXXXX")
awk -v version="v$VERSION" '
    /^## \[v/ {
        if (printing) exit
        if (index($0, "[" version "]") > 0) { printing = 1; next }
    }
    printing && /^---$/ { exit }
    printing { print }
' RELEASE_NOTES.md > "$NOTES_SECTION"

if [ -s "$NOTES_SECTION" ]; then
    {
        echo "# NewsBar v$VERSION"
        echo ""
        cat "$NOTES_SECTION"
        if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "v$VERSION" ]; then
            echo ""
            echo "**Full Changelog**: https://github.com/${REPO_SLUG}/compare/${PREV_TAG}...v${VERSION}"
        fi
    } > "$TEMP_NOTES"
fi

if [ "$ALLOW_ADHOC" -eq 1 ]; then
    {
        echo ""
        echo "---"
        echo ""
        echo "⚠️ **签名说明**：本版为 adhoc 签名，未经过公证。首次打开如被 Gatekeeper 拦截，请到「系统设置 → 隐私与安全性 → 仍要打开」。"
        echo ""
        echo "⚠️ **Signing note**: This build is ad-hoc signed and not notarized. If Gatekeeper blocks the first launch, use System Settings → Privacy & Security → Open Anyway."
    } >> "$TEMP_NOTES"
fi

# Upload the feed and its deltas next to the DMG so
# /releases/latest/download/appcast.xml always resolves to the newest feed.
UPLOAD_FILES=("$DMG_FILE" "${DMG_FILE}.sha256" "$APPCAST_FILE")
while IFS= read -r delta; do
    [ -n "$delta" ] && UPLOAD_FILES+=("$delta")
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name "*.delta" 2>/dev/null | sort)

if command -v gh &> /dev/null; then
    echo "📦 Creating GitHub Release v$VERSION..."
    gh release create "v$VERSION" \
        --verify-tag \
        --title "NewsBar v$VERSION" \
        --notes-file "$TEMP_NOTES" \
        "${UPLOAD_FILES[@]}"

    echo "🔎 Verifying the published feed..."
    PINNED_FEED="https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/appcast.xml"
    if curl -fsSL "$PINNED_FEED" -o ${TMPDIR:-/tmp}/newsbar-published-appcast.xml; then
        python3 scripts/verify-appcast.py ${TMPDIR:-/tmp}/newsbar-published-appcast.xml "$VERSION"
    else
        echo "⚠️  Could not fetch ${PINNED_FEED}; check the release assets manually."
    fi

    echo "✅ Release created: v$VERSION"
else
    echo "⚠️  gh CLI not installed. Install it with: brew install gh"
    echo "   Release notes saved to: $TEMP_NOTES"
    echo "   DMG ready at: $DMG_FILE"
    echo "   Assets to upload manually:"
    printf '     %s\n' "${UPLOAD_FILES[@]}"
fi
