#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP_DIR="${SCRIPT_DIR}/Voice.app"
INSTALL_APP_DIR="/Applications/Voice.app"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_PATH="${LAUNCH_AGENT_DIR}/com.faradaysoft.voice.plist"

echo "=== Voice Installer ==="

# --- Dependencies ---
echo "Checking dependencies..."

if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew not found. Install from https://brew.sh" >&2
    exit 1
fi

# cmake builds the statically linked speech engine (engine/build.sh).
if ! command -v cmake &>/dev/null; then
    echo "Installing cmake..."
    brew install cmake
fi

# The app needs neither whisper-cli nor sox; the optional `voice` CLI does.
if [[ -f "${SCRIPT_DIR}/voice.sh" ]]; then
    if ! command -v whisper-cli &>/dev/null; then
        echo "Installing whisper-cpp for the voice CLI..."
        brew install whisper-cpp
    fi
    if ! command -v rec &>/dev/null; then
        echo "Installing sox for the voice CLI..."
        brew install sox
    fi
fi

# --- Build app (models are downloaded by the app on first launch) ---
"${SCRIPT_DIR}/build-app.sh"

# Sign with stable identity so macOS TCC keeps accessibility permission across recompiles.
# Priority: $VOICE_CODESIGN_IDENTITY > any Developer ID Application > Voice Dev > ad-hoc
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGN_CERT="${VOICE_CODESIGN_IDENTITY:-$(printf '%s\n' "${IDENTITIES}" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$SIGN_CERT" ]] && printf '%s\n' "${IDENTITIES}" | grep -q '"Voice Dev"'; then
    SIGN_CERT="Voice Dev"
fi

if [[ -n "$SIGN_CERT" ]]; then
    codesign --force --sign "${SIGN_CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/Voice.entitlements" \
        "${BUILD_APP_DIR}"
    echo "App bundle signed (${SIGN_CERT}) at ${BUILD_APP_DIR}"
else
    codesign --force --sign - --options runtime --entitlements "${SCRIPT_DIR}/Voice.entitlements" "${BUILD_APP_DIR}"
    echo "App bundle ad-hoc signed at ${BUILD_APP_DIR}"
    echo "Note: You may need to re-grant Accessibility permission after recompiling."
fi

# --- Install to /Applications ---
rm -rf "${INSTALL_APP_DIR}"
cp -R "${BUILD_APP_DIR}" "${INSTALL_APP_DIR}"
echo "Installed to ${INSTALL_APP_DIR}"

# --- Install voice CLI tool ---
VOICE_SH="${SCRIPT_DIR}/voice.sh"
if [[ -f "$VOICE_SH" ]]; then
    mkdir -p "${HOME}/bin"
    ln -sf "$VOICE_SH" "${HOME}/bin/voice"
    echo "Symlinked voice CLI to ~/bin/voice"
fi

# --- LaunchAgent (start on login) ---
mkdir -p "${LAUNCH_AGENT_DIR}"
cat > "${LAUNCH_AGENT_PATH}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.faradaysoft.voice</string>
    <key>Program</key>
    <string>${INSTALL_APP_DIR}/Contents/MacOS/Voice</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
echo "LaunchAgent installed (starts on login)"

# --- Launch ---
echo "Launching Voice..."
open "${INSTALL_APP_DIR}"

echo ""
echo "=== Done ==="
echo "  Hold fn        = Push-to-talk (record while held)"
echo "  Double-tap fn  = Hands-free mode (lock-on dictation, tap fn to stop)"
echo "  Escape         = Cancel recording"
echo "  Menu bar: waveform icon"
echo ""
echo "First use: macOS will prompt for Accessibility and Microphone permissions -- grant both."
