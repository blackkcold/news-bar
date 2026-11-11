#!/bin/bash
set -euo pipefail

# Checks that this machine can build a signed NewsBar, and prints the values
# that must not change (certificate fingerprint, Sparkle public key).
#
# Run after restoring the two 1Password items on a new machine.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=lib/app-config.sh
source "${PROJECT_DIR}/scripts/lib/app-config.sh"
# shellcheck source=lib/signing.sh
source "${PROJECT_DIR}/scripts/lib/signing.sh"

STATUS=0

check_file() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then
        echo "❌ missing ${label}: ${path}"
        STATUS=1
        return
    fi
    local mode
    mode="$(stat -f '%Lp' "$path")"
    if [ "$mode" != "600" ]; then
        echo "⚠️  ${label} permissions are ${mode}, expected 600: ${path}"
    fi
    echo "✅ ${label}: ${path}"
}

check_file "${SIGNING_DIR}/NewsBar.p12" "code signing certificate"
check_file "${SIGNING_DIR}/NewsBar.p12.password" "certificate password"
check_file "${SIGNING_DIR}/sparkle_ed_key" "Sparkle EdDSA private key"

if [ -f "${SIGNING_DIR}/sparkle_ed_key" ]; then
    if python3 - "${SIGNING_DIR}/sparkle_ed_key" "$SU_PUBLIC_ED_KEY" <<'PY'
import base64, sys
seed = base64.b64decode(open(sys.argv[1]).read().strip())
if len(seed) != 32:
    sys.exit(f"seed is {len(seed)} bytes, expected 32")
base64.b64decode(sys.argv[2])
PY
    then
        echo "✅ Sparkle key format is valid (32-byte seed)"
    else
        echo "❌ Sparkle key is not a base64-encoded 32-byte seed"
        STATUS=1
    fi
fi

if [ -f "${SIGNING_DIR}/NewsBar.pem" ]; then
    echo "   certificate: $(openssl x509 -in "${SIGNING_DIR}/NewsBar.pem" -noout -subject 2>/dev/null)"
    echo "   expires:     $(openssl x509 -in "${SIGNING_DIR}/NewsBar.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
    echo "   sha256:      $(openssl x509 -in "${SIGNING_DIR}/NewsBar.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
fi

echo "   app public key: ${SU_PUBLIC_ED_KEY}"

if [ "$STATUS" -ne 0 ]; then
    echo ""
    echo "Restore the items from 1Password before building:"
    echo "  NewsBar Signing Cert   → ${SIGNING_DIR}/NewsBar.p12 (+ password file)"
    echo "  NewsBar Sparkle EdDSA  → ${SIGNING_DIR}/sparkle_ed_key"
    exit 1
fi

newsbar_open_signing_keychain
trap newsbar_close_signing_keychain EXIT

if security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "✅ codesign identity resolves: ${SIGN_IDENTITY}"
else
    echo "❌ codesign cannot find '${SIGN_IDENTITY}' in the imported certificate"
    exit 1
fi

echo ""
echo "Never regenerate the certificate: its leaf hash is the app's designated"
echo "requirement. A new certificate resets every TCC and notification grant."
