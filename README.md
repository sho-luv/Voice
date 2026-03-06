# Voice

**Local speech-to-text for macOS. Hold fn, speak, release. Text appears wherever your cursor is.**

Voice is a lightweight menu bar app that replaces cloud-based dictation with fast, private, local transcription. It works everywhere -- terminals, browsers, editors, chat apps -- without sending a single byte off your machine.

Built with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription and optionally [Ollama](https://ollama.ai) for AI-powered text cleanup. Inspired by [Wispr Flow](https://wispr.com).

---

## Quick Start

```bash
git clone https://github.com/sho-luv/Voice.git
cd Voice
./install.sh
```

That's it. The installer takes care of dependencies, model download, compilation, and auto-start on login. On first launch macOS will ask for two permissions -- grant both:

1. **Accessibility** -- needed to detect the fn key and inject text
2. **Microphone** -- needed to record audio

## Usage

| Shortcut | Action |
|----------|--------|
| **Hold fn** | Push-to-talk. Records while held, transcribes on release. |
| **Space + fn** | POPO mode. Locks recording on for hands-free dictation. Tap fn again to stop. |
| **Escape** | Cancel the current recording. |

A floating overlay at the top of the screen shows what's happening:

| Indicator | Meaning |
|-----------|---------|
| Pulsing red dot | Recording |
| Pulsing blue dot | POPO mode (continuous) |
| Hourglass | Transcribing |
| Checkmark + text preview | Done |
| X + error message | Something went wrong |

The menu bar icon also reflects the current state. Click it for options including **Paste Last** to re-insert the most recent transcription.

## How Text Gets Inserted

Voice automatically picks the best method for the active app:

- **Most apps** (browsers, editors, chat) -- text is injected directly via the macOS Accessibility API. Instant, no clipboard involvement.
- **Terminal apps** (iTerm2, Terminal, Alacritty, WezTerm, Kitty, Warp, Hyper) -- uses clipboard paste with simulated Cmd+V. Your original clipboard is saved beforehand and restored after 500ms.

This happens automatically. No configuration needed.

## AI Text Cleanup (Optional)

If [Ollama](https://ollama.ai) is running locally with `llama3.2:3b`, Voice cleans up the raw transcription before inserting it:

- Strips filler words (um, uh, like, you know, basically)
- Fixes grammar and punctuation
- Handles corrections ("scratch that", "no wait" -- keeps only the final version)
- Adapts tone to context (professional in Mail, casual in Messages, technical in Terminal)

To enable: install Ollama and run `ollama pull llama3.2:3b`. Voice checks for it on launch -- if it's not there, raw whisper output is used with no errors.

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

# Run
./Voice
```

## Troubleshooting

**fn key does nothing**
- Check System Settings > Privacy & Security > Accessibility -- Voice must be listed and enabled
- If another app uses fn as a hotkey (e.g., Wispr Flow), close it or reassign the key
- After recompiling, you may need to toggle the Accessibility permission off and on

**Text doesn't appear in my app**
- For terminals: Voice uses clipboard Cmd+V. If paste is disabled in your terminal settings, enable it
- For other apps: the Accessibility API is used. Make sure the app has an active text field focused

**Ollama cleanup not working**
- Confirm Ollama is running: `curl http://localhost:11434/api/tags`
- Confirm the model is pulled: `ollama list` should show `llama3.2:3b`
- Voice falls back to raw transcription silently if Ollama is unavailable

## Uninstall

```bash
pkill Voice
rm ~/Library/LaunchAgents/com.local.voice.plist
# Optionally remove the whisper model:
rm ~/.local/share/whisper-models/ggml-small.en.bin
```

## License

MIT
