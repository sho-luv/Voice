# Voice

A macOS menu bar app that turns speech into text using local transcription. Hold the **fn key** to record, release to transcribe -- text is injected directly into the active text field. Works in terminals, browsers, editors, and any app.

Inspired by [Wispr Flow](https://wispr.com), but fully local. Everything runs via [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and optionally [Ollama](https://ollama.ai) for AI cleanup. No cloud APIs, no network calls, no subscription.

## How It Works

| Action | What Happens |
|--------|-------------|
| **Hold fn** | Push-to-talk: records while held, transcribes on release |
| **Space+fn** | POPO mode: locks dictation on, tap fn again to stop |
| **Escape** | Cancel current recording |
| **Paste Last** | Re-insert last transcription (menu bar option) |

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

Voice uses two strategies to insert text into the active app:

- **Accessibility API** -- direct text injection for apps with editable text fields (browsers, editors, etc.)
- **Clipboard paste** -- for terminal apps (iTerm2, Terminal, Alacritty, WezTerm, Kitty, Warp, Hyper) where AX injection silently fails. Uses delayed clipboard rendering via `NSPasteboardItemDataProvider` and simulated Cmd+V with the event tap temporarily disabled to prevent self-interception. Original clipboard contents are saved and restored after 500ms.

Terminal apps are auto-detected by bundle ID -- no configuration needed.

### AI Cleanup (Optional)

If [Ollama](https://ollama.ai) is running locally with `llama3.2:3b`, Voice automatically cleans up transcription:
- Removes filler words (um, uh, like, you know)
- Fixes grammar and punctuation
- Handles mid-sentence corrections ("scratch that", "no wait")
- Adapts tone based on the active app (professional for Mail, casual for Messages, technical for Terminal/Xcode)

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

## How It Works (Technical)

Voice intercepts the fn key via `CGEvent.tapCreate` with a `.defaultTap` event tap. The fn keypress is swallowed (returns nil) to prevent the macOS emoji picker from opening. Recording uses `sox`'s `rec` command at 16kHz mono, transcription uses `whisper-cli`.

For clipboard paste in terminals, the approach mirrors [Wispr Flow](https://wispr.com)'s architecture:
1. Save current clipboard contents (all pasteboard types)
2. Register a `NSPasteboardItemDataProvider` for delayed rendering
3. Temporarily disable the CGEventTap
4. Post Cmd+V via `CGEventPost` to `.cghidEventTap`
5. Target app reads clipboard, triggering the data provider callback
6. Re-enable event tap after 100ms
7. Restore original clipboard after 500ms

## Uninstall

```bash
pkill Voice
rm ~/Library/LaunchAgents/com.local.voice.plist
# Optionally remove the model:
rm ~/.local/share/whisper-models/ggml-small.en.bin
```

## License

MIT
