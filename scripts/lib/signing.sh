#!/bin/bash
# Code-signing helpers shared by build.sh and package-local.sh.
#
# The identity lives in a throwaway keychain built from the exported .p12 for
# the duration of one build. Nothing is installed into the login keychain, so a
# build never triggers a keychain password prompt and never leaves a private
# key behind.

NEWSBAR_KEYCHAIN=""
NEWSBAR_KEYCHAIN_PASSWORD=""
NEWSBAR_ORIGINAL_KEYCHAINS=()

newsbar_signing_material_available() {
    [ -f "${SIGNING_DIR}/NewsBar.p12" ] && [ -f "${SIGNING_DIR}/NewsBar.p12.password" ]
}

# `security list-keychains` prints one indented, quoted path per line.
newsbar_capture_keychains() {
    NEWSBAR_ORIGINAL_KEYCHAINS=()
    local line
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | tr -d '"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$line" ] && NEWSBAR_ORIGINAL_KEYCHAINS+=("$line")
    done < <(security list-keychains -d user)
}

newsbar_open_signing_keychain() {
    if ! newsbar_signing_material_available; then
        echo "❌ Signing material missing: ${SIGNING_DIR}/NewsBar.p12" >&2
        echo "   Import it from 1Password (see docs/signing-and-release.md)." >&2
        return 1
    fi

    local workdir
    workdir="$(mktemp -d "${TMPDIR:-/tmp}/newsbar-sign.XXXXXX")"
    NEWSBAR_KEYCHAIN="${workdir}/newsbar-sign.keychain-db"
    NEWSBAR_KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"

    security create-keychain -p "$NEWSBAR_KEYCHAIN_PASSWORD" "$NEWSBAR_KEYCHAIN" >/dev/null
    security set-keychain-settings -lut 3600 "$NEWSBAR_KEYCHAIN"
    security unlock-keychain -p "$NEWSBAR_KEYCHAIN_PASSWORD" "$NEWSBAR_KEYCHAIN" >/dev/null
    security import "${SIGNING_DIR}/NewsBar.p12" \
        -k "$NEWSBAR_KEYCHAIN" \
        -P "$(cat "${SIGNING_DIR}/NewsBar.p12.password")" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    # Without the partition list codesign cannot use the key non-interactively.
    security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "$NEWSBAR_KEYCHAIN_PASSWORD" "$NEWSBAR_KEYCHAIN" >/dev/null

    newsbar_capture_keychains
    security list-keychains -d user -s "$NEWSBAR_KEYCHAIN" "${NEWSBAR_ORIGINAL_KEYCHAINS[@]}"
}

newsbar_close_signing_keychain() {
    if [ ${#NEWSBAR_ORIGINAL_KEYCHAINS[@]} -gt 0 ]; then
        security list-keychains -d user -s "${NEWSBAR_ORIGINAL_KEYCHAINS[@]}" || true
    fi
    if [ -n "$NEWSBAR_KEYCHAIN" ] && [ -e "$NEWSBAR_KEYCHAIN" ]; then
        security delete-keychain "$NEWSBAR_KEYCHAIN" 2>/dev/null || true
    fi
    NEWSBAR_KEYCHAIN=""
    NEWSBAR_KEYCHAIN_PASSWORD=""
}

newsbar_assert_signed() {
    local target="$1"
    local info authority
    info="$(codesign -dv --verbose=4 "$target" 2>&1 || true)"

    if printf '%s' "$info" | grep -q "Signature=adhoc"; then
        echo "❌ ${target} is ad-hoc signed; the fixed identity was not applied." >&2
        return 1
    fi

    authority="$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)"
    if [ "$authority" != "$SIGN_IDENTITY" ]; then
        echo "❌ ${target} is signed by '${authority:-unknown}', expected '${SIGN_IDENTITY}'." >&2
        return 1
    fi

    codesign --verify --deep --strict "$target"
}

# Sparkle ships nested code: two XPC services, an installer app and a bare
# helper. Signing the framework before its nested code, or the app before the
# framework, leaves a seal that no longer matches the bytes on disk.
newsbar_sign_app() {
    local app="$1"
    local fw="${app}/Contents/Frameworks/Sparkle.framework"
    local version_dir="${fw}/Versions/B"

    if [ -d "$version_dir" ]; then
        local nested
        for nested in \
            "${version_dir}/XPCServices/Downloader.xpc" \
            "${version_dir}/XPCServices/Installer.xpc" \
            "${version_dir}/Updater.app" \
            "${version_dir}/Autoupdate"; do
            [ -e "$nested" ] || continue
            codesign --force --sign "$SIGN_IDENTITY" "$nested"
        done
        codesign --force --sign "$SIGN_IDENTITY" "$fw"
    fi

    if [ -f "${app}/Contents/MacOS/newsbarctl" ]; then
        codesign --force --sign "$SIGN_IDENTITY" "${app}/Contents/MacOS/newsbarctl"
    fi

    codesign --force --sign "$SIGN_IDENTITY" "$app"
    newsbar_assert_signed "$app"
}

# Copies Sparkle into Contents/Frameworks with ditto so the framework's
# Versions/Current symlinks survive, then adds the rpath the bundle needs.
newsbar_embed_sparkle() {
    local bin_dir="$1"
    local app="$2"
    local framework="${bin_dir}/Sparkle.framework"

    if [ ! -d "$framework" ]; then
        echo "❌ Sparkle.framework not found in ${bin_dir}" >&2
        echo "   Run swift build before packaging." >&2
        return 1
    fi

    mkdir -p "${app}/Contents/Frameworks"
    ditto "$framework" "${app}/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${app}/Contents/MacOS/NewsBar" 2>/dev/null || true
}
