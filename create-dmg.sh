#!/usr/bin/env bash
# create-dmg.sh — Build, sign, notarize, and package Voice.app as a DMG.
#
# Usage:
#   ./create-dmg.sh
#
# Requirements:
#   - whisper-cli installed (brew install whisper-cpp)
#   - Developer ID Application certificate in Keychain (for production signing)
#   - xcrun notarytool keychain profile "voice-notarize" (for notarization — one-time setup)
#   - create-dmg installed (brew install create-dmg) — optional, falls back to hdiutil
#
# One-time notarization credential setup:
#   xcrun notarytool store-credentials voice-notarize \
#     --apple-id YOUR_APPLE_ID \
#     --team-id MWW7M2563A \
#     --password APP_SPECIFIC_PASSWORD

set -euo pipefail
shopt -s nullglob

APP_NAME="Voice"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SCRIPT_DIR}/Info.plist" 2>/dev/null || true)"
if [[ -z "${VERSION}" ]]; then
    echo "Error: Could not read CFBundleShortVersionString from Info.plist" >&2
    exit 1
fi
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
CERT="${VOICE_CODESIGN_IDENTITY:-Developer ID Application: Leon Johnson (MWW7M2563A)}"
NOTARY_PROFILE="${VOICE_NOTARY_PROFILE:-voice-notarize}"

find_dylib_source() {
    local libname="$1"
    local candidate
    for candidate in \
        "${WHISPER_LIB_DIR}/${libname}" \
        "/opt/homebrew/lib/${libname}" \
        "/usr/local/lib/${libname}"
    do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

echo "=== Building ${APP_NAME} ${VERSION} DMG ==="

# --- Check whisper-cli is available ---
WHISPER_CLI="$(command -v whisper-cli || true)"
if [[ -z "$WHISPER_CLI" ]]; then
    echo "Error: whisper-cli not found. Install with: brew install whisper-cpp" >&2
    exit 1
fi

# --- Determine signing identity ---
USE_DEVELOPER_ID=false
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "${CERT}"; then
    USE_DEVELOPER_ID=true
    echo "Using Developer ID certificate: ${CERT}"
elif [[ -n "${VOICE_CODESIGN_IDENTITY:-}" ]]; then
    echo "Error: Requested signing identity not found: ${CERT}" >&2
    exit 1
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Voice Dev"; then
    CERT="Voice Dev"
    echo "Developer ID not found. Falling back to Voice Dev certificate."
else
    CERT="-"
    echo "Warning: No Developer ID or Voice Dev certificate found. Using ad-hoc signing." >&2
    echo "  Users will need to right-click > Open on first launch." >&2
    USE_DEVELOPER_ID=false
fi

# --- Compile ---
echo "Compiling..."
swiftc -O -o "${SCRIPT_DIR}/Voice" "${SCRIPT_DIR}/Voice.swift" \
    -framework Cocoa -framework ApplicationServices \
    -framework UserNotifications -framework AVFoundation \
    -framework CoreAudio \
    -Xlinker -x \
    -Xlinker -dead_strip

# --- Create app bundle ---
echo "Creating app bundle..."
APP_DIR="${SCRIPT_DIR}/Voice.app/Contents"
rm -rf "${SCRIPT_DIR}/Voice.app"
mkdir -p "${APP_DIR}/MacOS" "${APP_DIR}/Resources" "${APP_DIR}/Frameworks"
cp "${SCRIPT_DIR}/Voice" "${APP_DIR}/MacOS/Voice"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Info.plist"
cp "${SCRIPT_DIR}/Voice.icns" "${APP_DIR}/Resources/Voice.icns"

# --- Bundle whisper-cli and dylibs ---
echo "Bundling whisper-cli..."
cp "$WHISPER_CLI" "${APP_DIR}/Resources/whisper-cli"

# Resolve the real path of whisper-cli to find its lib/ directory
WHISPER_REAL="$(readlink -f "$WHISPER_CLI" 2>/dev/null || realpath "$WHISPER_CLI" 2>/dev/null || echo "$WHISPER_CLI")"
WHISPER_LIB_DIR="$(dirname "$WHISPER_REAL")/../lib"

# Copy all dylibs that whisper-cli depends on (uses @rpath)
for lib in $(otool -L "$WHISPER_CLI" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
    libname="$(echo "$lib" | sed 's|@rpath/||')"
    if source_path="$(find_dylib_source "$libname")"; then
        cp "$source_path" "${APP_DIR}/Frameworks/$libname"
    else
        echo "Warning: Could not locate ${libname} required by whisper-cli" >&2
    fi
    install_name_tool -change "$lib" "@executable_path/../Frameworks/$libname" \
        "${APP_DIR}/Resources/whisper-cli" 2>/dev/null || true
done

# Also copy any Homebrew absolute-path dylibs
for lib in $(otool -L "$WHISPER_CLI" 2>/dev/null | tail -n +2 | grep -E '/(opt/homebrew|usr/local)' | awk '{print $1}'); do
    libname="$(basename "$lib")"
    cp "$lib" "${APP_DIR}/Frameworks/$libname"
    install_name_tool -change "$lib" "@executable_path/../Frameworks/$libname" \
        "${APP_DIR}/Resources/whisper-cli" 2>/dev/null || true
done

# Fix dylib cross-references (dylibs that reference other dylibs via @rpath)
for fw in "${APP_DIR}/Frameworks/"*.dylib; do
    for lib in $(otool -L "$fw" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
        libname="$(echo "$lib" | sed 's|@rpath/||')"
        install_name_tool -change "$lib" "@executable_path/../Frameworks/$libname" "$fw" 2>/dev/null || true
    done
done

# --- Sign inside-out (dylibs -> whisper-cli -> app bundle) ---
echo "Signing..."
if [[ "$CERT" == "-" ]]; then
    # Ad-hoc fallback: sign with --deep (acceptable for dev builds only)
    echo "  Ad-hoc signing with --deep (not suitable for distribution)"
    codesign --force --deep --sign - --entitlements "${SCRIPT_DIR}/Voice.entitlements" "${SCRIPT_DIR}/Voice.app"
else
    # Production signing: inside-out order, hardened runtime, no --deep
    echo "  Signing dylibs..."
    for dylib in "${APP_DIR}/Frameworks/"*.dylib; do
        codesign --force --sign "${CERT}" --timestamp --options runtime "${dylib}"
    done

    echo "  Signing whisper-cli..."
    codesign --force --sign "${CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/WhisperMinimal.entitlements" \
        "${APP_DIR}/Resources/whisper-cli"

    echo "  Signing app bundle..."
    codesign --force --sign "${CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/Voice.entitlements" \
        "${SCRIPT_DIR}/Voice.app"

    echo "  Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "${SCRIPT_DIR}/Voice.app"
    echo "  Signed with: ${CERT}"
fi

# --- Create DMG ---
echo "Creating DMG..."
STAGING="${SCRIPT_DIR}/.dmg-staging"
rm -rf "$STAGING" "${SCRIPT_DIR}/${DMG_NAME}"
mkdir -p "$STAGING"
cp -R "${SCRIPT_DIR}/Voice.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if command -v create-dmg &>/dev/null; then
    # Use create-dmg for a polished installer DMG with drag-to-Applications layout
    DMG_BG_ARGS=()
    if [[ -f "${SCRIPT_DIR}/dmg-background.png" ]]; then
        DMG_BG_ARGS=(--background "${SCRIPT_DIR}/dmg-background.png")
    else
        echo "Warning: dmg-background.png not found — DMG will use default background. Run the background generator or add an image." >&2
    fi
    create-dmg \
        --volname "Voice" \
        --volicon "${SCRIPT_DIR}/Voice.icns" \
        "${DMG_BG_ARGS[@]}" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 120 \
        --text-size 12 \
        --icon "Voice.app" 175 195 \
        --hide-extension "Voice.app" \
        --icon "Applications" 485 195 \
        "${SCRIPT_DIR}/${DMG_NAME}" \
        "${STAGING}/"
else
    echo "Warning: create-dmg not installed. Using hdiutil (no custom background). Install with: brew install create-dmg" >&2
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "${SCRIPT_DIR}/${DMG_NAME}"
fi

rm -rf "$STAGING"

# --- Sign the DMG ---
if [[ "$CERT" != "-" ]]; then
    echo "Signing DMG..."
    codesign --force --sign "${CERT}" --timestamp "${SCRIPT_DIR}/${DMG_NAME}"
fi

# --- Notarization ---
if [[ "$USE_DEVELOPER_ID" == "true" ]]; then
    if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" &>/dev/null 2>&1; then
        echo "Notarizing DMG (this may take a few minutes)..."
        xcrun notarytool submit "${SCRIPT_DIR}/${DMG_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait
        echo "Stapling notarization ticket..."
        xcrun stapler staple "${SCRIPT_DIR}/${DMG_NAME}"
        echo "Notarization complete."
    else
        echo ""
        echo "Notarization credentials not configured. To set up (one-time):"
        echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\"
        echo "    --apple-id YOUR_APPLE_ID \\"
        echo "    --team-id MWW7M2563A \\"
        echo "    --password APP_SPECIFIC_PASSWORD"
        echo ""
        echo "Then re-run this script to notarize and staple."
    fi

    # Final Gatekeeper verification
    echo "Verifying with Gatekeeper..."
    spctl --assess --type execute -vvvv "${SCRIPT_DIR}/Voice.app" || true
fi

echo ""
echo "=== Created ${DMG_NAME} ==="
echo "  Size: $(du -h "${SCRIPT_DIR}/${DMG_NAME}" | cut -f1)"
echo ""
