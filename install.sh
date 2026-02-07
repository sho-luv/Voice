#!/usr/bin/env bash
set -euo pipefail

echo "=== VoiceMic Installer ==="

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
echo "Compiling VoiceMic..."

swiftc -O -o "${SCRIPT_DIR}/VoiceMic" "${SCRIPT_DIR}/VoiceMic.swift" \
    -framework Cocoa -framework Carbon -framework UserNotifications

# --- Create app bundle ---
APP_DIR="${SCRIPT_DIR}/VoiceMic.app/Contents"
mkdir -p "${APP_DIR}/MacOS"
cp "${SCRIPT_DIR}/VoiceMic" "${APP_DIR}/MacOS/VoiceMic"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Info.plist"

echo "App bundle created at ${SCRIPT_DIR}/VoiceMic.app"

# --- Install voice CLI tool ---
VOICE_SH="$(dirname "$SCRIPT_DIR")/voice.sh"
if [[ -f "$VOICE_SH" ]]; then
    mkdir -p "${HOME}/bin"
    ln -sf "$VOICE_SH" "${HOME}/bin/voice"
    echo "Symlinked voice CLI to ~/bin/voice"
fi

# --- LaunchAgent (start on login) ---
PLIST="${HOME}/Library/LaunchAgents/com.local.voicemic.plist"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.voicemic</string>
    <key>Program</key>
    <string>${APP_DIR}/MacOS/VoiceMic</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
echo "LaunchAgent installed (starts on login)"

# --- Launch ---
echo "Launching VoiceMic..."
open "${SCRIPT_DIR}/VoiceMic.app"

echo ""
echo "=== Done ==="
echo "  Hotkey: Cmd+L to toggle recording"
echo "  Menu bar: 🎙 icon"
echo "  CLI: voice (record with Enter/silence to stop)"
echo ""
echo "First use: macOS will prompt for microphone permission -- grant it."
