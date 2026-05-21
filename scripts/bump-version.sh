#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

CURRENT=$(cat version.txt | tr -d '[:space:]')

if [ $# -gt 0 ]; then
    NEW_VERSION="$1"
else
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
    PATCH=$((PATCH + 1))
    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
fi

echo "$NEW_VERSION" > version.txt

git add version.txt
git commit -m "chore: bump version to $NEW_VERSION"
git tag "v$NEW_VERSION"

echo "✅ Version bumped: $CURRENT → $NEW_VERSION"
echo "   Tag: v$NEW_VERSION"
echo ""
echo "   Run: scripts/build.sh   to create release"
