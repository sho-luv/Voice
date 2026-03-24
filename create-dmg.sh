#!/usr/bin/env bash
set -euo pipefail

VERSION="3.1"
APP_NAME="Voice"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Building ${APP_NAME} ${VERSION} DMG ==="

# --- Check whisper-cli is available ---
WHISPER_CLI="$(command -v whisper-cli || true)"
if [[ -z "$WHISPER_CLI" ]]; then
    echo "Error: whisper-cli not found. Install with: brew install whisper-cpp" >&2
    exit 1
fi

# --- Compile ---
echo "Compiling..."
swiftc -O -o "${SCRIPT_DIR}/Voice" "${SCRIPT_DIR}/Voice.swift" \
    -framework Cocoa -framework ApplicationServices \
    -framework UserNotifications -framework AVFoundation

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
    if [[ -f "$WHISPER_LIB_DIR/$libname" ]]; then
        cp "$WHISPER_LIB_DIR/$libname" "${APP_DIR}/Frameworks/$libname"
    elif [[ -f "/opt/homebrew/lib/$libname" ]]; then
        cp "/opt/homebrew/lib/$libname" "${APP_DIR}/Frameworks/$libname"
    fi
    install_name_tool -change "$lib" "@executable_path/../Frameworks/$libname" \
        "${APP_DIR}/Resources/whisper-cli" 2>/dev/null || true
done

# Also copy any /opt/homebrew absolute-path dylibs
for lib in $(otool -L "$WHISPER_CLI" 2>/dev/null | tail -n +2 | grep /opt/homebrew | awk '{print $1}'); do
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

# --- Sign ---
echo "Signing..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Voice Dev"; then
    codesign --force --deep --sign "Voice Dev" "${SCRIPT_DIR}/Voice.app"
    echo "  Signed with Voice Dev certificate"
else
    codesign --force --deep --sign - "${SCRIPT_DIR}/Voice.app"
    echo "  Ad-hoc signed (users will need to right-click > Open on first launch)"
fi

# --- Create DMG ---
echo "Creating DMG..."
STAGING="${SCRIPT_DIR}/.dmg-staging"
rm -rf "$STAGING" "${SCRIPT_DIR}/${DMG_NAME}"
mkdir -p "$STAGING"
cp -R "${SCRIPT_DIR}/Voice.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "${SCRIPT_DIR}/${DMG_NAME}"

rm -rf "$STAGING"

echo ""
echo "=== Created ${DMG_NAME} ==="
echo "  Size: $(du -h "${SCRIPT_DIR}/${DMG_NAME}" | cut -f1)"
echo ""
echo "To notarize (requires Apple Developer ID):"
echo "  xcrun notarytool submit ${DMG_NAME} --apple-id YOUR_ID --team-id YOUR_TEAM --password YOUR_APP_PASSWORD"
