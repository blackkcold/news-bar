#!/bin/bash
set -euo pipefail

# Put `newsbarctl` on PATH without copying it out of the app bundle, so the CLI
# always matches the installed app version.
#
# Usage:
#   scripts/install-cli.sh [/Applications/NewsBar.app]
#   NEWSBAR_BIN_DIR=~/.local/bin scripts/install-cli.sh

APP="${1:-/Applications/NewsBar.app}"
CLI="$APP/Contents/MacOS/newsbarctl"
BIN_DIR="${NEWSBAR_BIN_DIR:-/usr/local/bin}"
LINK="$BIN_DIR/newsbarctl"

if [ ! -x "$CLI" ]; then
    echo "newsbarctl not found at: $CLI" >&2
    echo "Usage: scripts/install-cli.sh [/path/to/NewsBar.app]" >&2
    exit 1
fi

mkdir -p "$BIN_DIR" 2>/dev/null || true

if [ -w "$BIN_DIR" ]; then
    ln -sf "$CLI" "$LINK"
    echo "Linked $LINK -> $CLI"
    "$LINK" --version
else
    echo "No write access to $BIN_DIR. Run:" >&2
    echo "  sudo ln -sf \"$CLI\" \"$LINK\"" >&2
    exit 1
fi
