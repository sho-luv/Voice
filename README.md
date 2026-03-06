# Voice

A macOS menu bar app that turns speech into text using local transcription. Hold the **fn key** to record, release to transcribe -- text is injected directly into the active text field.

Everything runs locally via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and optionally [Ollama](https://ollama.ai) for AI cleanup. No cloud APIs, no network calls.

## How It Works

| Action | What Happens |
|--------|-------------|
| **Hold fn** | Push-to-talk: records while held, transcribes on release |
| **Space+fn** | POPO mode: locks dictation on, tap fn again to stop |
| **Escape** | Cancel current recording |

A floating overlay appears at the top of the screen showing the current state:

| Overlay | State |
|---------|-------|
| Pulsing red dot | Recording (push-to-talk) |
| Pulsing blue dot | POPO mode (continuous) |
| Hourglass | Transcribing |
| Checkmark + preview | Done (auto-dismisses) |
| X + message | Error (auto-dismisses) |

The menu bar icon is a secondary indicator (microphone = idle, red = recording, blue = POPO, hourglass = transcribing).

### Text Injection

Transcribed text is injected directly into the focused text field via the Accessibility API. If AX injection fails (e.g., the app doesn't support it), Voice falls back to clipboard paste (Cmd+V) and restores the original clipboard contents.

### AI Cleanup (Optional)

If [Ollama](https://ollama.ai) is running locally with `llama3.2:3b`, Voice automatically cleans up transcription:
- Removes filler words (um, uh, like, you know)
- Fixes grammar and punctuation
- Handles mid-sentence corrections
- Adapts tone based on the active app (professional for Mail, casual for Messages, etc.)

If Ollama is not running, raw whisper output is used -- no crash, no error.

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

On first use, macOS will prompt for **Accessibility** and **Microphone** permissions -- grant both.

## Requirements

- macOS (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools (`xcode-select --install`)
- Optional: [Ollama](https://ollama.ai) with `llama3.2:3b` for AI text cleanup

## Build Manually

```bash
swiftc -O -o Voice Voice.swift \
    -framework Cocoa -framework ApplicationServices -framework UserNotifications
```

## Uninstall

```bash
pkill Voice
rm ~/Library/LaunchAgents/com.local.voice.plist
# Optionally remove the model:
rm ~/.local/share/whisper-models/ggml-small.en.bin
```

## License

MIT
