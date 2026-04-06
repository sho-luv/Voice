#!/usr/bin/env bash
# create-dmg.sh — Build, sign, notarize, and package Voice.app as a DMG.
#
# Usage:
#   ./create-dmg.sh
#
# Requirements:
#   - whisper-cli installed (brew install whisper-cpp)
#   - llama.cpp installed (brew install llama.cpp)
#   - Developer ID Application certificate in Keychain (for production signing)
#   - xcrun notarytool keychain profile "voice-notarize" (for notarization — one-time setup)
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

echo "=== Building ${APP_NAME} ${VERSION} DMG ==="

# --- Check prerequisites ---
WHISPER_CLI="$(command -v whisper-cli || true)"
if [[ -z "$WHISPER_CLI" ]]; then
    echo "Error: whisper-cli not found. Install with: brew install whisper-cpp" >&2
    exit 1
fi

LLAMA_CLI="$(command -v llama-completion || true)"
if [[ -z "$LLAMA_CLI" ]]; then
    echo "Error: llama-completion not found. Install with: brew install llama.cpp" >&2
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
mkdir -p "${APP_DIR}/MacOS" "${APP_DIR}/Resources"
mkdir -p "${APP_DIR}/Frameworks/whisper"
mkdir -p "${APP_DIR}/Frameworks/llama/backends"
cp "${SCRIPT_DIR}/Voice" "${APP_DIR}/MacOS/Voice"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Info.plist"
cp "${SCRIPT_DIR}/Voice.icns" "${APP_DIR}/Resources/Voice.icns"

# --- Bundle whisper-cli + dylibs ---
echo "Bundling whisper-cli..."
cp "$WHISPER_CLI" "${APP_DIR}/Resources/whisper-cli"

WHISPER_REAL="$(readlink -f "$WHISPER_CLI" 2>/dev/null || realpath "$WHISPER_CLI" 2>/dev/null || echo "$WHISPER_CLI")"
WHISPER_LIB_DIR="$(dirname "$WHISPER_REAL")/../lib"

# Copy @rpath dylibs for whisper-cli
for lib in $(otool -L "$WHISPER_CLI" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
    libname="$(echo "$lib" | sed 's|@rpath/||')"
    for candidate in "${WHISPER_LIB_DIR}/${libname}" "/opt/homebrew/lib/${libname}" "/usr/local/lib/${libname}"; do
        if [[ -f "${candidate}" ]]; then
            cp "$candidate" "${APP_DIR}/Frameworks/whisper/$libname"
            break
        fi
    done
    install_name_tool -change "$lib" "@executable_path/../Frameworks/whisper/$libname" \
        "${APP_DIR}/Resources/whisper-cli" 2>/dev/null || true
done

# Copy Homebrew absolute-path dylibs for whisper-cli
for lib in $(otool -L "$WHISPER_CLI" 2>/dev/null | tail -n +2 | grep -E '/(opt/homebrew|usr/local)' | awk '{print $1}'); do
    libname="$(basename "$lib")"
    cp "$lib" "${APP_DIR}/Frameworks/whisper/$libname"
    install_name_tool -change "$lib" "@executable_path/../Frameworks/whisper/$libname" \
        "${APP_DIR}/Resources/whisper-cli" 2>/dev/null || true
done

# Fix whisper dylib install names and cross-references
for fw in "${APP_DIR}/Frameworks/whisper/"*.dylib; do
    fwname="$(basename "$fw")"
    install_name_tool -id "@executable_path/../Frameworks/whisper/$fwname" "$fw" 2>/dev/null || true
    for lib in $(otool -L "$fw" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
        libname="$(echo "$lib" | sed 's|@rpath/||')"
        install_name_tool -change "$lib" "@executable_path/../Frameworks/whisper/$libname" "$fw" 2>/dev/null || true
    done
    for lib in $(otool -L "$fw" 2>/dev/null | tail -n +2 | grep -E '/(opt/homebrew|usr/local)' | awk '{print $1}'); do
        libname="$(basename "$lib")"
        install_name_tool -change "$lib" "@executable_path/../Frameworks/whisper/$libname" "$fw" 2>/dev/null || true
    done
done

# --- Bundle llama-completion + dylibs ---
echo "Bundling llama-completion..."
cp "$LLAMA_CLI" "${APP_DIR}/Resources/llama-completion"

LLAMA_REAL="$(readlink -f "$LLAMA_CLI" 2>/dev/null || realpath "$LLAMA_CLI" 2>/dev/null || echo "$LLAMA_CLI")"
LLAMA_LIB_DIR="$(dirname "$LLAMA_REAL")/../lib"

# Copy @rpath dylibs for llama-completion (libllama, libmtmd)
for lib in $(otool -L "$LLAMA_CLI" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
    libname="$(echo "$lib" | sed 's|@rpath/||')"
    for candidate in "${LLAMA_LIB_DIR}/${libname}" "/opt/homebrew/lib/${libname}" "/usr/local/lib/${libname}"; do
        if [[ -f "${candidate}" ]]; then
            cp "$candidate" "${APP_DIR}/Frameworks/llama/$libname"
            break
        fi
    done
    install_name_tool -change "$lib" "@executable_path/../Frameworks/llama/$libname" \
        "${APP_DIR}/Resources/llama-completion" 2>/dev/null || true
done

# Copy Homebrew absolute-path dylibs for llama-completion (ggml, openssl, etc.)
for lib in $(otool -L "$LLAMA_CLI" 2>/dev/null | tail -n +2 | grep -E '/(opt/homebrew|usr/local)' | awk '{print $1}'); do
    libname="$(basename "$lib")"
    cp "$lib" "${APP_DIR}/Frameworks/llama/$libname"
    install_name_tool -change "$lib" "@executable_path/../Frameworks/llama/$libname" \
        "${APP_DIR}/Resources/llama-completion" 2>/dev/null || true
done

# Copy ggml backend plugins (.so files)
GGML_BACKEND_DIR="$(brew --prefix ggml 2>/dev/null)/libexec"
if [[ -d "$GGML_BACKEND_DIR" ]]; then
    echo "  Bundling ggml backends..."
    for plugin in "${GGML_BACKEND_DIR}/"*.so; do
        cp "$plugin" "${APP_DIR}/Frameworks/llama/backends/"
    done
fi

# Copy libomp (needed by CPU backends)
LIBOMP="$(brew --prefix libomp 2>/dev/null)/lib/libomp.dylib"
if [[ -f "$LIBOMP" ]]; then
    cp "$LIBOMP" "${APP_DIR}/Frameworks/llama/libomp.dylib"
fi

# Fix llama dylib install names and cross-references
for fw in "${APP_DIR}/Frameworks/llama/"*.dylib; do
    fwname="$(basename "$fw")"
    install_name_tool -id "@executable_path/../Frameworks/llama/$fwname" "$fw" 2>/dev/null || true
    for lib in $(otool -L "$fw" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
        libname="$(echo "$lib" | sed 's|@rpath/||')"
        install_name_tool -change "$lib" "@executable_path/../Frameworks/llama/$libname" "$fw" 2>/dev/null || true
    done
    for lib in $(otool -L "$fw" 2>/dev/null | tail -n +2 | grep -E '/(opt/homebrew|usr/local)' | awk '{print $1}'); do
        libname="$(basename "$lib")"
        install_name_tool -change "$lib" "@executable_path/../Frameworks/llama/$libname" "$fw" 2>/dev/null || true
    done
done

# Fix backend plugin dylib references
for plugin in "${APP_DIR}/Frameworks/llama/backends/"*.so; do
    for lib in $(otool -L "$plugin" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
        libname="$(echo "$lib" | sed 's|@rpath/||')"
        install_name_tool -change "$lib" "@executable_path/../Frameworks/llama/$libname" "$plugin" 2>/dev/null || true
    done
    for lib in $(otool -L "$plugin" 2>/dev/null | tail -n +2 | grep -E '/(opt/homebrew|usr/local)' | awk '{print $1}'); do
        libname="$(basename "$lib")"
        install_name_tool -change "$lib" "@executable_path/../Frameworks/llama/$libname" "$plugin" 2>/dev/null || true
    done
done

# --- Bundle models ---
echo "Bundling models..."

# Whisper model
WHISPER_MODEL="$(defaults read com.faradaysoft.voice whisperModel 2>/dev/null || echo 'large-v3-turbo-q5_0')"
WHISPER_MODEL_FILE="${HOME}/Library/Application Support/Voice/Models/ggml-${WHISPER_MODEL}.bin"
if [[ -f "${WHISPER_MODEL_FILE}" ]]; then
    echo "  Whisper model: ggml-${WHISPER_MODEL}.bin ($(du -h "${WHISPER_MODEL_FILE}" | cut -f1))"
    cp "${WHISPER_MODEL_FILE}" "${APP_DIR}/Resources/ggml-${WHISPER_MODEL}.bin"
else
    echo "Error: Whisper model not found at ${WHISPER_MODEL_FILE}" >&2
    exit 1
fi

# LLM model for AI text cleanup
LLAMA_MODEL_FILE="${HOME}/Library/Application Support/Voice/Models/qwen2.5-0.5b-instruct-q4_0.gguf"
if [[ -f "${LLAMA_MODEL_FILE}" ]]; then
    echo "  LLM model: $(basename "${LLAMA_MODEL_FILE}") ($(du -h "${LLAMA_MODEL_FILE}" | cut -f1))"
    cp "${LLAMA_MODEL_FILE}" "${APP_DIR}/Resources/"
else
    echo "Error: LLM model not found at ${LLAMA_MODEL_FILE}" >&2
    echo "  Download from: https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF" >&2
    exit 1
fi

# --- Sign inside-out (dylibs -> backends -> binaries -> app bundle) ---
echo "Signing..."
if [[ "$CERT" == "-" ]]; then
    echo "  Ad-hoc signing with --deep (not suitable for distribution)"
    codesign --force --deep --sign - --entitlements "${SCRIPT_DIR}/Voice.entitlements" "${SCRIPT_DIR}/Voice.app"
else
    echo "  Signing whisper dylibs..."
    for dylib in "${APP_DIR}/Frameworks/whisper/"*.dylib; do
        codesign --force --sign "${CERT}" --timestamp --options runtime "${dylib}"
    done

    echo "  Signing llama dylibs..."
    for dylib in "${APP_DIR}/Frameworks/llama/"*.dylib; do
        codesign --force --sign "${CERT}" --timestamp --options runtime "${dylib}"
    done

    echo "  Signing ggml backend plugins..."
    for plugin in "${APP_DIR}/Frameworks/llama/backends/"*.so; do
        codesign --force --sign "${CERT}" --timestamp --options runtime "${plugin}"
    done

    echo "  Signing whisper-cli..."
    codesign --force --sign "${CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/WhisperMinimal.entitlements" \
        "${APP_DIR}/Resources/whisper-cli"

    echo "  Signing llama-completion..."
    codesign --force --sign "${CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/WhisperMinimal.entitlements" \
        "${APP_DIR}/Resources/llama-completion"

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
hdiutil detach /Volumes/Voice 2>/dev/null || true
STAGING="${SCRIPT_DIR}/.dmg-staging"
rm -rf "$STAGING" "${SCRIPT_DIR}/${DMG_NAME}"
mkdir -p "$STAGING"
cp -R "${SCRIPT_DIR}/Voice.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

HYBRID_TMP="${SCRIPT_DIR}/.voice-hybrid"
rm -f "${HYBRID_TMP}.cdr" "${HYBRID_TMP}.cdr.dmg"
hdiutil makehybrid -o "${HYBRID_TMP}.cdr" \
    -hfs -hfs-volume-name "Voice" \
    "$STAGING/"
HYBRID_FILE="${HYBRID_TMP}.cdr"
[[ -f "${HYBRID_FILE}.dmg" ]] && HYBRID_FILE="${HYBRID_FILE}.dmg"
hdiutil convert "$HYBRID_FILE" -format UDZO \
    -imagekey zlib-level=9 \
    -o "${SCRIPT_DIR}/${DMG_NAME}"
rm -f "${HYBRID_TMP}.cdr" "${HYBRID_TMP}.cdr.dmg"
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

    echo "Verifying with Gatekeeper..."
    spctl --assess --type execute -vvvv "${SCRIPT_DIR}/Voice.app" || true
fi

echo ""
echo "=== Created ${DMG_NAME} ==="
echo "  Size: $(du -h "${SCRIPT_DIR}/${DMG_NAME}" | cut -f1)"
echo ""
