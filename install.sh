#!/usr/bin/env bash
set -euo pipefail

echo "=== Voice Installer ==="

# --- Dependencies ---
echo "Checking dependencies..."

if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew not found. Install from https://brew.sh" >&2
    exit 1
fi

if ! command -v whisper-cli &>/dev/null; then
    echo "Installing whisper-cpp..."
    brew install whisper-cpp
fi

if ! command -v rec &>/dev/null; then
    echo "Installing sox..."
    brew install sox
fi

# --- Whisper model ---
MODEL_DIR="${HOME}/.local/share/whisper-models"
MODEL_FILE="${MODEL_DIR}/ggml-small.en.bin"

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "Downloading whisper small.en model (465 MB)..."
    mkdir -p "$MODEL_DIR"
    curl -L --progress-bar -o "$MODEL_FILE" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
fi

# --- Compile app ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Compiling Voice..."

swiftc -O -o "${SCRIPT_DIR}/Voice" "${SCRIPT_DIR}/Voice.swift" \
    -framework Cocoa -framework ApplicationServices -framework UserNotifications

# --- Create app bundle ---
APP_DIR="${SCRIPT_DIR}/Voice.app/Contents"
mkdir -p "${APP_DIR}/MacOS"
mkdir -p "${APP_DIR}/Resources"
cp "${SCRIPT_DIR}/Voice" "${APP_DIR}/MacOS/Voice"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Info.plist"
cp "${SCRIPT_DIR}/Voice.icns" "${APP_DIR}/Resources/Voice.icns"

# Sign with stable identity so macOS TCC keeps accessibility permission across recompiles.
# Falls back to ad-hoc if "Voice Dev" certificate isn't in keychain.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Voice Dev"; then
    codesign --force --sign "Voice Dev" "${SCRIPT_DIR}/Voice.app"
    echo "App bundle created and signed (Voice Dev) at ${SCRIPT_DIR}/Voice.app"
else
    codesign --force --sign - "${SCRIPT_DIR}/Voice.app"
    echo "App bundle created (ad-hoc signed) at ${SCRIPT_DIR}/Voice.app"
    echo "Note: You may need to re-grant Accessibility permission after recompiling."
fi

# --- Install voice CLI tool ---
VOICE_SH="$(dirname "$SCRIPT_DIR")/voice.sh"
if [[ -f "$VOICE_SH" ]]; then
    mkdir -p "${HOME}/bin"
    ln -sf "$VOICE_SH" "${HOME}/bin/voice"
    echo "Symlinked voice CLI to ~/bin/voice"
fi

# --- LaunchAgent (start on login) ---
PLIST="${HOME}/Library/LaunchAgents/com.local.voice.plist"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.voice</string>
    <key>Program</key>
    <string>${APP_DIR}/MacOS/Voice</string>
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
open "${SCRIPT_DIR}/Voice.app"

echo ""
echo "=== Done ==="
echo "  Hold fn        = Push-to-talk (record while held)"
echo "  Space+fn       = POPO mode (lock-on dictation, tap fn to stop)"
echo "  Escape         = Cancel recording"
echo "  Menu bar: microphone icon"
echo ""
echo "First use: macOS will prompt for Accessibility and Microphone permissions -- grant both."
