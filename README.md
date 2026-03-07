# Voice

**Local speech-to-text for macOS. Hold fn, speak, release. Text appears wherever your cursor is.**

Voice is a lightweight menu bar app that replaces cloud-based dictation with fast, private, local transcription. It works everywhere -- terminals, browsers, editors, chat apps -- without sending a single byte off your machine.

Built with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription and optionally [Ollama](https://ollama.ai), [OpenAI](https://openai.com), or [Anthropic](https://anthropic.com) for AI-powered text cleanup. Inspired by [Wispr Flow](https://wispr.com).

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
| **Space + fn** | POPO mode. Locks recording on for hands-free dictation. Tap fn again to stop. |
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

The menu bar icon also reflects the current state. Click it for options including **Paste Last** to re-insert the most recent transcription.

## Settings

Open from the menu bar (click the mic icon > "Settings...") or press **Cmd+,**.

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
| Provider | Ollama (local), OpenAI, or Anthropic | Ollama |
| Model | Model name for the selected provider | llama3.2:3b |
| API Key | Required for OpenAI and Anthropic (hidden for Ollama) | -- |
| Test Connection | Verify the provider is reachable and the key is valid | -- |

### Transcription

| Setting | Description | Default |
|---------|-------------|---------|
| Whisper model | small.en, medium.en, or large-v3 | small.en |
| Download Model | Download the selected model if not already on disk | -- |

All settings persist across restarts via `UserDefaults` (`~/Library/Preferences/com.local.voice.plist`).

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

Three providers are supported:

| Provider | Setup |
|----------|-------|
| **Ollama** (local) | Install [Ollama](https://ollama.ai), run `ollama pull llama3.2:3b`. No API key needed. |
| **OpenAI** | Enter your API key in Settings. Default model: `gpt-4o-mini`. |
| **Anthropic** | Enter your API key in Settings. Default model: `claude-sonnet-4-20250514`. |

Switch providers and test the connection in the AI tab of Settings. If AI cleanup is disabled (or the provider is unreachable), raw whisper output is used.

## Requirements

- macOS on Apple Silicon or Intel
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)

The installer will handle `whisper-cpp`, `sox`, and the whisper model automatically.

## Manual Build

If you prefer to build without the installer:

```bash
# Install dependencies
brew install whisper-cpp sox

# Download the model (465 MB)
mkdir -p ~/.local/share/whisper-models
curl -L -o ~/.local/share/whisper-models/ggml-small.en.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin

# Compile
swiftc -O -o Voice Voice.swift \
    -framework Cocoa -framework ApplicationServices -framework UserNotifications

# Create app bundle
mkdir -p Voice.app/Contents/MacOS
cp Voice Voice.app/Contents/MacOS/Voice
cp Info.plist Voice.app/Contents/Info.plist

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
- OpenAI/Anthropic: check your API key in Settings and click "Test Connection"
- Voice falls back to raw transcription silently if the provider is unreachable

**Settings window appears on relaunch**
- This was a macOS window restoration issue, now fixed. If it persists: `rm -rf ~/Library/Saved\ Application\ State/com.local.voice.savedState` and relaunch

## Uninstall

```bash
pkill -f Voice.app
rm ~/Library/LaunchAgents/com.local.voice.plist
# Optionally remove the whisper model:
rm ~/.local/share/whisper-models/ggml-small.en.bin
# Optionally remove settings:
defaults delete com.local.voice
```

## License

MIT
