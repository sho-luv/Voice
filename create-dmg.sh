#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# create-dmg.sh — Build, sign, notarize, and package Voice.app as a DMG.
#
# Usage:
#   ./create-dmg.sh
#   VOICE_BUNDLE_MODELS=1 ./create-dmg.sh   # offline build with models inside (~1.4 GB)
#
# Requirements:
#   - cmake (brew install cmake) — builds the static speech engine
#   - create-dmg (brew install create-dmg)
#   - Developer ID Application certificate in Keychain (for production signing)
#   - xcrun notarytool keychain profile "voice-notarize" (for notarization — one-time setup)
#
# One-time notarization credential setup:
#   xcrun notarytool store-credentials voice-notarize \
#     --apple-id YOUR_APPLE_ID \
#     --team-id MWW7M2563A \
#     --password APP_SPECIFIC_PASSWORD

set -euo pipefail

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

echo "=== Building ${APP_NAME} ${VERSION} DMG ==="

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
fi

# --- Build (engine + app bundle; no helper binaries or dylibs) ---
"${SCRIPT_DIR}/build-app.sh"

# --- Sign ---
echo "Signing..."
if [[ "$CERT" == "-" ]]; then
    codesign --force --sign - --options runtime --entitlements "${SCRIPT_DIR}/Voice.entitlements" "${SCRIPT_DIR}/Voice.app"
    echo "  Ad-hoc signed (not suitable for distribution)"
else
    codesign --force --sign "${CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/Voice.entitlements" \
        "${SCRIPT_DIR}/Voice.app"
    echo "  Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "${SCRIPT_DIR}/Voice.app"
    echo "  Signed with: ${CERT}"
fi

# --- Create DMG (polished install UX via `create-dmg`) ---
# Requires: brew install create-dmg
echo "Creating DMG..."
hdiutil detach "/Volumes/Voice ${VERSION}" 2>/dev/null || true
rm -f "${SCRIPT_DIR}/${DMG_NAME}"

if ! command -v create-dmg &>/dev/null; then
    echo "Error: create-dmg not found. Install with: brew install create-dmg" >&2
    exit 1
fi

# Background is 1320x800 @2x → window is 660x400 @1x. Arrow centered at y=190.
# Voice.app icon sits left of arrow start; Applications alias sits right of arrow end.
create-dmg \
    --volname "Voice ${VERSION}" \
    --background "${SCRIPT_DIR}/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "Voice.app" 175 190 \
    --app-drop-link 485 190 \
    --hide-extension "Voice.app" \
    --hdiutil-quiet \
    "${SCRIPT_DIR}/${DMG_NAME}" \
    "${SCRIPT_DIR}/Voice.app"

# --- Sign the DMG ---
if [[ "$CERT" != "-" ]]; then
    echo "Signing DMG..."
    codesign --force --sign "${CERT}" --timestamp "${SCRIPT_DIR}/${DMG_NAME}"
fi

# --- Notarization ---
if [[ "$USE_DEVELOPER_ID" == "true" ]]; then
    if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" &>/dev/null; then
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

    echo "Verifying with Gatekeeper..."
    spctl --assess --type execute -vvvv "${SCRIPT_DIR}/Voice.app" || true
fi

echo ""
echo "=== Created ${DMG_NAME} ==="
echo "  Size: $(du -h "${SCRIPT_DIR}/${DMG_NAME}" | cut -f1)"
echo ""
