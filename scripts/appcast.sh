#!/bin/bash
set -euo pipefail

# Builds the signed Sparkle appcast for the current version.
#
# Run after scripts/build.sh. Outputs:
#   release/<version>/appcast.xml   (uploaded by release.sh)
#   release/appcast/*.delta         (uploaded by release.sh)
#
# The EdDSA private key is read from 1Password when NEWSBAR_SPARKLE_KEY is set,
# otherwise from the local signing directory. It is piped to generate_appcast
# over stdin, so it never touches the filesystem.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"

VERSION="$(tr -d '[:space:]' < version.txt)"
DMG="release/${VERSION}/${APP_NAME}-${VERSION}.dmg"
OUTPUT="release/${VERSION}/appcast.xml"
ARCHIVE_DIR="${NEWSBAR_APPCAST_DIR:-release/appcast}"
FEED="${ARCHIVE_DIR}/appcast.xml"
GENERATE_APPCAST="${PROJECT_DIR}/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [ ! -f "$DMG" ]; then
    echo "❌ DMG not found: $DMG (run scripts/build.sh first)" >&2
    exit 1
fi
if [ ! -x "$GENERATE_APPCAST" ]; then
    echo "❌ generate_appcast not found at $GENERATE_APPCAST" >&2
    echo "   Run swift build once so SwiftPM fetches Sparkle." >&2
    exit 1
fi

mkdir -p "$ARCHIVE_DIR"

# Continue an existing feed so the previous versions are known (they are the
# delta sources). The published feed keeps only the newest item: Sparkle
# applies --download-url-prefix to every item it writes, so keeping old items
# would point their enclosure URLs at this release's tag.
SEEDED=0
if [ -f "$FEED" ]; then
    SEEDED=1
elif curl -fsSL "$SU_FEED_URL" -o "$FEED" 2>/dev/null; then
    SEEDED=1
    echo "   Seeded appcast from the live feed."
else
    rm -f "$FEED"
    echo "   No previous feed; publishing a first-release feed."
fi

FEED_VERSIONS=""
if [ "$SEEDED" -eq 1 ]; then
    FEED_VERSIONS="$(grep -oE "<sparkle:version>[^<]+" "$FEED" | sed 's/.*>//' || true)"
fi

# Drop staged archives that are neither this version nor referenced by the
# feed. A stale DMG would be added as a bogus item pointing at this tag.
for staged in "${ARCHIVE_DIR}/${APP_NAME}-"*.dmg; do
    [ -e "$staged" ] || continue
    staged_version="$(basename "$staged" | sed -E "s/^${APP_NAME}-(.*)\.dmg$/\1/")"
    if [ "$staged_version" != "$VERSION" ] \
        && ! printf '%s\n' "$FEED_VERSIONS" | grep -qx "$staged_version"; then
        echo "   Dropping staged archive not in the feed: $staged"
        rm -f "$staged"
    fi
done

ditto "$DMG" "${ARCHIVE_DIR}/${APP_NAME}-${VERSION}.dmg"

# Sparkle can only build a delta from a local copy of the previous app. Seed
# those copies from release/<version>/ when the feed already references them;
# otherwise the update is a plain DMG download, which is still correct.
if [ "$SEEDED" -eq 1 ]; then
    while IFS= read -r previous; do
        [ -n "$previous" ] || continue
        [ "$previous" = "$VERSION" ] && continue
        source_dmg="release/${previous}/${APP_NAME}-${previous}.dmg"
        [ -f "$source_dmg" ] && ditto "$source_dmg" "${ARCHIVE_DIR}/${APP_NAME}-${previous}.dmg"
    done <<< "$FEED_VERSIONS"
fi

# Release notes for this version, embedded in the feed and shown inside the
# update window. Sparkle 2.9+ renders markdown on macOS 12+.
NOTES="${ARCHIVE_DIR}/${APP_NAME}-${VERSION}.md"
awk -v version="v${VERSION}" '
    BEGIN { printing = 0 }
    /^## \[v/ {
        if (printing) exit
        if (index($0, "[" version "]") > 0) { printing = 1 }
    }
    printing { print }
' RELEASE_NOTES.md > "$NOTES"
if [ ! -s "$NOTES" ]; then
    printf '## NewsBar v%s\n\nSee the GitHub release for details.\n' "$VERSION" > "$NOTES"
fi

# EdDSA key: 1Password over stdin, or the local signing directory.
if [ -n "${NEWSBAR_SPARKLE_KEY:-}" ]; then
    command -v op >/dev/null || { echo "❌ op CLI not found" >&2; exit 1; }
    KEY_CMD=(op read "${NEWSBAR_SPARKLE_KEY}")
elif [ -f "${SIGNING_DIR}/sparkle_ed_key" ]; then
    KEY_CMD=(cat "${SIGNING_DIR}/sparkle_ed_key")
else
    echo "❌ Sparkle private key missing." >&2
    echo "   Set NEWSBAR_SPARKLE_KEY=op://<vault>/<item>/<field> or place it at" >&2
    echo "   ${SIGNING_DIR}/sparkle_ed_key." >&2
    exit 1
fi

echo "🧾 Generating appcast for v${VERSION}..."
"${KEY_CMD[@]}" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/${REPO_SLUG}/releases/download/v${VERSION}/" \
    --maximum-deltas 2 \
    --maximum-versions 1 \
    --embed-release-notes \
    --link "https://github.com/${REPO_SLUG}" \
    "$ARCHIVE_DIR"

cp "$FEED" "$OUTPUT"

# Fail loudly if the feed cannot satisfy the app's own requirements.
python3 "${PROJECT_DIR}/scripts/verify-appcast.py" "$OUTPUT" "$VERSION"

echo "✅ ${OUTPUT}"
ls -lh "$OUTPUT" "${ARCHIVE_DIR}"/*.delta 2>/dev/null || true
