#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP_DIR="${SCRIPT_DIR}/Voice.app"
INSTALL_APP_DIR="/Applications/Voice.app"
LAUNCH_AGENT_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_PATH="${LAUNCH_AGENT_DIR}/com.faradaysoft.voice.plist"

find_dylib_source() {
    local libname="$1"
    local whisper_lib_dir="$2"
    local candidate
    for candidate in \
        "${whisper_lib_dir}/${libname}" \
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

# The app records with AVFoundation, but the optional `voice` CLI still uses sox.
if [[ -f "${SCRIPT_DIR}/voice.sh" ]] && ! command -v rec &>/dev/null; then
    echo "Installing sox for the voice CLI..."
    brew install sox
fi

# --- Optional: Ollama ---
if ! command -v ollama &>/dev/null; then
    read -p "Install Ollama for local AI? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Installing Ollama..."
        brew install ollama
        brew services start ollama
        echo "Waiting for Ollama to start..."
        sleep 3
        echo "Pulling llama3.2:3b model..."
        ollama pull llama3.2:3b
        echo "Ollama ready!"
    fi
fi

# --- Whisper model ---
MODEL_DIR="${HOME}/Library/Application Support/Voice/Models"
MODEL_FILE="${MODEL_DIR}/ggml-large-v3-turbo-q5_0.bin"

# Migrate from old location if needed
OLD_MODEL_DIR="${HOME}/.local/share/whisper-models"
if [[ -d "$OLD_MODEL_DIR" ]] && [[ ! -f "$MODEL_FILE" ]]; then
    echo "Migrating whisper models to Application Support..."
    mkdir -p "$MODEL_DIR"
    for f in "$OLD_MODEL_DIR"/*.bin; do
        [[ -f "$f" ]] && mv "$f" "$MODEL_DIR/" 2>/dev/null || true
    done
fi

if [[ ! -f "$MODEL_FILE" ]]; then
    echo "Downloading whisper large-v3-turbo-q5_0 model (574 MB)..."
    mkdir -p "$MODEL_DIR"
    curl -L --progress-bar -o "$MODEL_FILE" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
fi

# --- Compile app ---
echo "Compiling Voice..."

swiftc -O -o "${SCRIPT_DIR}/Voice" \
    "${SCRIPT_DIR}/Voice.swift" \
    "${SCRIPT_DIR}/VoiceExceptionCatcher.m" \
    -import-objc-header "${SCRIPT_DIR}/Voice-Bridging-Header.h" \
    -framework Cocoa -framework ApplicationServices -framework UserNotifications -framework AVFoundation -framework CoreAudio

# --- Create app bundle ---
APP_DIR="${BUILD_APP_DIR}/Contents"
mkdir -p "${APP_DIR}/MacOS"
mkdir -p "${APP_DIR}/Resources"
mkdir -p "${APP_DIR}/Frameworks"
cp "${SCRIPT_DIR}/Voice" "${APP_DIR}/MacOS/Voice"
cp "${SCRIPT_DIR}/Info.plist" "${APP_DIR}/Info.plist"
cp "${SCRIPT_DIR}/Voice.icns" "${APP_DIR}/Resources/Voice.icns"

# --- Bundle whisper-cli and its dylibs ---
WHISPER_CLI="$(command -v whisper-cli)"
if [[ -n "$WHISPER_CLI" ]]; then
    cp "$WHISPER_CLI" "${APP_DIR}/Resources/whisper-cli"

    # Resolve the real path of whisper-cli to find its lib/ directory
    WHISPER_REAL="$(readlink -f "$WHISPER_CLI" 2>/dev/null || realpath "$WHISPER_CLI" 2>/dev/null || echo "$WHISPER_CLI")"
    WHISPER_LIB_DIR="$(dirname "$WHISPER_REAL")/../lib"

    # Copy all dylibs that whisper-cli depends on (uses @rpath)
    for lib in $(otool -L "$WHISPER_CLI" 2>/dev/null | tail -n +2 | grep '@rpath' | awk '{print $1}'); do
        libname="$(echo "$lib" | sed 's|@rpath/||')"
        if source_path="$(find_dylib_source "$libname" "$WHISPER_LIB_DIR")"; then
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

    echo "Bundled whisper-cli into app"
else
    echo "Warning: whisper-cli not found, app will try /opt/homebrew/bin/whisper-cli at runtime"
fi

# Sign with stable identity so macOS TCC keeps accessibility permission across recompiles.
# Priority: Developer ID Application > Voice Dev > ad-hoc
# Uses inside-out signing order: dylibs -> whisper-cli -> app bundle (no --deep)
SIGN_CERT=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: Faraday Soft"; then
    SIGN_CERT="Developer ID Application: Faraday Soft (MWW7M2563A)"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Voice Dev"; then
    SIGN_CERT="Voice Dev"
fi

if [[ -n "$SIGN_CERT" ]]; then
    # Inside-out signing: dylibs first, then whisper-cli, then app bundle
    for dylib in "${APP_DIR}/Frameworks/"*.dylib; do
        codesign --force --sign "${SIGN_CERT}" --timestamp --options runtime "${dylib}"
    done
    if [[ -f "${SCRIPT_DIR}/WhisperMinimal.entitlements" ]]; then
        codesign --force --sign "${SIGN_CERT}" --timestamp --options runtime \
            --entitlements "${SCRIPT_DIR}/WhisperMinimal.entitlements" \
            "${APP_DIR}/Resources/whisper-cli"
    else
        codesign --force --sign "${SIGN_CERT}" --timestamp --options runtime \
            "${APP_DIR}/Resources/whisper-cli"
    fi
    codesign --force --sign "${SIGN_CERT}" --timestamp --options runtime \
        --entitlements "${SCRIPT_DIR}/Voice.entitlements" \
        "${SCRIPT_DIR}/Voice.app"
    echo "App bundle created and signed (${SIGN_CERT}) at ${SCRIPT_DIR}/Voice.app"
else
    # Ad-hoc fallback: --deep is acceptable for local dev builds
    codesign --force --deep --sign - --entitlements "${SCRIPT_DIR}/Voice.entitlements" "${SCRIPT_DIR}/Voice.app"
    echo "App bundle created (ad-hoc signed) at ${SCRIPT_DIR}/Voice.app"
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
echo "  Menu bar: microphone icon"
echo ""
echo "First use: macOS will prompt for Accessibility and Microphone permissions -- grant both."
