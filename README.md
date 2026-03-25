<p align="center">
  <img src="icon.png" width="128" alt="Voice app icon" />
</p>

# Voice

**Local speech-to-text for macOS. Hold fn, speak, release. Text appears wherever your cursor is.**

Voice is a menu bar and Dock app that replaces cloud-based dictation with fast, private, local transcription. It works everywhere -- terminals, browsers, editors, chat apps -- without sending a single byte off your machine.

Built with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription and optionally [Ollama](https://ollama.ai) for local AI text cleanup. 100% on-device, nothing leaves your machine. Inspired by [Wispr Flow](https://wispr.com).

---

## Quick Start

```bash
git clone https://github.com/sho-luv/Voice.git
cd Voice
./install.sh
```

That's it. The installer takes care of dependencies, model download, compilation, code signing, and auto-start on login. On first launch macOS will ask for two permissions -- grant both:

1. **Accessibility** -- needed to detect the hotkey and inject text
2. **Microphone** -- needed to record audio

## Usage

| Shortcut | Action |
|----------|--------|
| **Hold fn** | Push-to-talk. Records while held, transcribes on release. |
| **Double-tap fn** | Hands-free mode. Locks recording on for dictation. Tap fn again to stop. |
| **Escape** | Cancel the current recording. |

The push-to-talk key is configurable in Settings (fn, Right Option, Left Option, or Right Cmd).

A floating overlay at the top of the screen shows what's happening:

| Indicator | Meaning |
|-----------|---------|
| Pulsing red dot | Recording |
| Pulsing blue dot | POPO mode (continuous) |
| Hourglass | Transcribing |
| Checkmark + text preview | Done |
| X + error message | Something went wrong |

The menu bar icon (a waveform) also reflects the current state. Click it for options including **Paste Last** to re-insert the most recent transcription. The app also appears in the Dock with its waveform icon.

### Transcription History

When transcript saving is enabled, each finished transcription is written to a local text file. The current app lets you:

- Full-text search across all transcriptions
- Copy any past transcription to clipboard
- Choose the save directory
- Turn transcript saving on or off

Browse this from **Settings... > Transcription**. By default files are stored in `~/Documents/Voice Transcripts`.

## Settings

Open from the menu bar (click the waveform icon > "Settings...") or press **Cmd+,**.

### General

| Setting | Description | Default |
|---------|-------------|---------|
| Push-to-talk key | fn, Right Option, Left Option, or Right Cmd | fn |
| Sounds | Audio feedback for recording start/stop/done | On |
| Auto-start on login | Install/remove LaunchAgent | On |
| POPO timeout | Safety auto-stop for POPO mode (1-30 min) | 5 min |
| Restore clipboard after paste | Saves and restores clipboard when using Cmd+V paste | On |

### AI

| Setting | Description | Default |
|---------|-------------|---------|
| AI text cleanup | Enable/disable AI post-processing of transcriptions | On |
| Model | Ollama model name for text cleanup | llama3.2:3b |
| Test Connection | Verify Ollama is reachable | -- |

### Transcription

| Setting | Description | Default |
|---------|-------------|---------|
| Whisper model | large-v3-turbo-q5_0, small.en, or large-v3 | large-v3-turbo-q5_0 |
| Download Model | Download the selected model if not already on disk | -- |
| Save transcripts | Save each transcription to a local text file | On |
| Transcript directory | Folder used for saved transcript files | `~/Documents/Voice Transcripts` |

All settings persist across restarts via `UserDefaults` (`~/Library/Preferences/com.faradaysoft.voice.plist`).

## How Text Gets Inserted

Voice automatically picks the best method for the active app:

- **Most apps** (browsers, editors, chat) -- text is injected directly via the macOS Accessibility API. Instant, no clipboard involvement.
- **Terminal apps** (iTerm2, Terminal, Alacritty, WezTerm, Kitty, Warp, Hyper) -- uses clipboard paste with simulated Cmd+V. Your original clipboard is saved beforehand and restored after 500ms (configurable in Settings).

This happens automatically. No configuration needed.

## AI Text Cleanup

Voice can clean up raw transcription before inserting it:

- Strips filler words (um, uh, like, you know, basically)
- Fixes grammar and punctuation
- Handles corrections ("scratch that", "no wait" -- keeps only the final version)
- Adapts tone to context (professional in Mail, casual in Messages, technical in Terminal)

AI cleanup uses [Ollama](https://ollama.ai) running locally on your machine. Install it and pull a model:

```bash
brew install ollama
brew services start ollama
ollama pull llama3.2:3b
```

Test the connection in the AI tab of Settings. If AI cleanup is disabled (or Ollama is unreachable), raw whisper output is used.

## Requirements

- macOS on Apple Silicon or Intel
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)

The installer will handle `whisper-cpp`, `sox`, and the whisper model automatically.

## Release Docs

For release process documentation, see [RELEASING.md](/Users/sho_luv/home/projects/mine/voice/RELEASING.md). That covers the GitHub Actions release pipeline, signing and notarization setup, versioning rules, and the exact steps for shipping a tagged release.

## Manual Build

If you prefer to build without the installer:

```bash
# Install dependencies
brew install whisper-cpp sox

# Download the model (574 MB)
mkdir -p ~/Library/Application\ Support/Voice/Models
curl -L -o ~/Library/Application\ Support/Voice/Models/ggml-large-v3-turbo-q5_0.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin

# Compile
swiftc -O -o Voice Voice.swift \
    -framework Cocoa -framework ApplicationServices -framework UserNotifications

# Create app bundle
mkdir -p Voice.app/Contents/MacOS
mkdir -p Voice.app/Contents/Resources
cp Voice Voice.app/Contents/MacOS/Voice
cp Info.plist Voice.app/Contents/Info.plist
cp Voice.icns Voice.app/Contents/Resources/Voice.icns

# Sign (see Code Signing section below)
codesign --force --sign - Voice.app

# Run
open Voice.app
```

## Code Signing & Accessibility Permissions

macOS tracks Accessibility permissions by the app's code signature. With **ad-hoc signing** (`codesign --sign -`), the identity is tied to the binary hash -- so every recompile invalidates the permission and you must re-grant it.

To avoid this, create a local self-signed certificate:

```bash
# Generate certificate
openssl req -x509 -newkey rsa:2048 \
    -keyout /tmp/vc_key.pem -out /tmp/vc_cert.pem \
    -days 3650 -nodes -subj "/CN=Voice Dev" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"

# Bundle and import to keychain
openssl pkcs12 -export -out /tmp/vc.p12 \
    -inkey /tmp/vc_key.pem -in /tmp/vc_cert.pem \
    -passout pass:temp123 -legacy
security import /tmp/vc.p12 -k ~/Library/Keychains/login.keychain-db \
    -P "temp123" -T /usr/bin/codesign

# Trust for code signing
security add-trusted-cert -d -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db /tmp/vc_cert.pem

# Clean up
rm /tmp/vc_key.pem /tmp/vc_cert.pem /tmp/vc.p12

# Verify
security find-identity -v -p codesigning
# Should show: "Voice Dev"
```

Once created, `install.sh` automatically uses it. Accessibility permission survives recompiles.

**Re-granting Accessibility permission** (when needed):

1. Quit Voice (`pkill -f Voice.app`)
2. System Settings > Privacy & Security > Accessibility
3. Remove Voice if listed, then click **+** and add `Voice.app`
4. Toggle ON and authenticate
5. Launch Voice: `open Voice.app`

The app must **not be running** when you grant the permission.

## Troubleshooting

**fn key does nothing**
- Check System Settings > Privacy & Security > Accessibility -- Voice must be listed and enabled
- If you recompiled, you likely need to re-grant Accessibility (see above). If you set up the "Voice Dev" certificate, this is a one-time step
- If another app uses fn as a hotkey (e.g., Wispr Flow), close it or reassign the key
- Try a different push-to-talk key in Settings

**Text doesn't appear in my app**
- For terminals: Voice uses clipboard Cmd+V. If paste is disabled in your terminal settings, enable it
- For other apps: the Accessibility API is used. Make sure the app has an active text field focused

**AI cleanup not working**
- Ollama: confirm it's running (`curl http://localhost:11434/api/tags`) and the model is pulled (`ollama list`)
- Click "Test Connection" in Settings to verify
- Voice falls back to raw transcription silently if Ollama is unreachable

**Settings window appears on relaunch**
- This was a macOS window restoration issue, now fixed. If it persists: `rm -rf ~/Library/Saved\ Application\ State/com.faradaysoft.voice.savedState` and relaunch

## Uninstall

```bash
pkill -f Voice.app
rm ~/Library/LaunchAgents/com.faradaysoft.voice.plist
# Optionally remove whisper models:
rm -rf ~/Library/Application\ Support/Voice/Models
# Optionally remove settings:
defaults delete com.faradaysoft.voice
```

## License

MIT
