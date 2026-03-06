# Voice

A macOS menu bar app that turns speech into text using local transcription. Press a hotkey, speak, press it again -- transcribed text lands on your clipboard.

Everything runs locally via [whisper.cpp](https://github.com/ggerganov/whisper.cpp). No cloud APIs, no network calls.

## How It Works

1. Press **Cmd+L** (global hotkey, works from any app)
2. Speak
3. Press **Cmd+L** again to stop
4. Text is transcribed and copied to your clipboard
5. **Cmd+V** to paste anywhere

The menu bar icon shows the current state:

| Icon | State |
|------|-------|
| 🎙 | Idle -- ready to record |
| 🔴 | Recording |
| ⏳ | Transcribing |

Audio cues play on start (Tink), stop (Pop), and completion (Glass).

## Install

```bash
git clone git@github.com:sho-luv/Voice.git
cd Voice
./install.sh
```

The installer handles:
- Installing `whisper-cpp` and `sox` via Homebrew
- Downloading the Whisper `small.en` model (465 MB)
- Compiling the Swift app
- Setting up a LaunchAgent (starts on login)
- Launching the app

On first use, macOS will prompt for **microphone permission** -- grant it.

## Requirements

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)

## CLI Tool

The installer also sets up a `voice` command for terminal use:

```bash
voice           # Record, press Enter to stop, transcribes and copies to clipboard
voice -s        # Silence-detection mode (auto-stops after 3s of silence)
voice -k        # Keep the audio file after transcription
voice -m large-v3-turbo  # Use a different Whisper model
```

## Uninstall

```bash
pkill Voice
rm ~/Library/LaunchAgents/com.local.voice.plist
rm ~/bin/voice
# Optionally remove the model:
rm ~/.local/share/whisper-models/ggml-small.en.bin
```

## License

MIT
