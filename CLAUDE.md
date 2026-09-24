# Voice

Privacy-first macOS dictation: hold fn, speak, release, and the text is inserted where the cursor is. Speech recognition (Parakeet or Whisper) and AI cleanup (Qwen via llama.cpp) run in-process on the Mac. No cloud, accounts, usage limits or telemetry. GPL-3.0-or-later.

## Constraints

- **No Xcode project.** Build with `swiftc` via the shell scripts.
- **Privacy.** Audio and transcripts never leave the Mac. The only network access is SHA-256-verified model downloads from Hugging Face and the user-initiated update check. Don't add analytics or remote AI.
- **Self-contained.** The app bundle is one statically linked executable. No helper binaries, dylibs or Homebrew at runtime.
- **Platform.** macOS 13+, Apple Silicon only.
- **Languages.** Both ASR models are multilingual (Parakeet TDT v3 auto-detects; Whisper takes a language code or "auto"). The `transcriptionLanguage` setting steers Whisper and gates the English-only text cleanup — `polishTranscript` only runs the hesitation/LLM cleanup for English or Automatic.
- **License.** Keep SPDX headers on new source files. Credit new dependencies or models in `THIRD_PARTY_NOTICES.md`.

## Layout

| Path | What |
|------|------|
| `Voice.swift` | App: settings, hotkey event tap, audio capture, overlay, text injection, onboarding, menu bar, `@main` entry |
| `SpeechEngine.swift` | `ModelCatalog` (pinned URLs + SHA-256), `SpeechEngine` (serial queue, preload, idle unload), `TextCleanup`, `SelfTest` |
| `engine/VoiceEngine.{h,cpp}` | C wrapper over whisper.cpp (Whisper + Parakeet) and llama.cpp |
| `engine/build.sh` | Builds `engine/build/libvoiceengine.a` from pinned whisper.cpp/llama.cpp tags against one shared ggml |
| `build-app.sh` | Engine, then `swiftc`, then `Voice.app`. Used by `install.sh` and `create-dmg.sh` |
| `voice.sh` | Optional terminal companion (Homebrew `whisper-cli` + `sox`) |
| `MODELS.md` | Model benchmarks and selection history. Read it before changing a model or the cleanup prompt |

## Build and verify

```bash
./build-app.sh                                     # engine (cached) + app bundle
./install.sh                                       # build, sign, install to /Applications
./Voice.app/Contents/MacOS/Voice --selftest a.wav  # headless: transcribe + cleanup battery
```

CI (`.github/workflows/ci.yml`) typechecks with
`swiftc -parse-as-library -typecheck Voice.swift SpeechEngine.swift -import-objc-header Voice-Bridging-Header.h -I engine ...`

Accessibility permission is tied to the code signature. Sign with a stable identity (Developer ID or a local "Voice Dev" cert) or the permission is lost on every rebuild.

## Pipeline

1. `InputMonitor` (CGEventTap) detects hold, double-tap (hands-free, `.popo`) and Escape.
2. `beginCapture` records 16 kHz mono Int16 to a temp WAV via `AVAudioEngine`, and calls `SpeechEngine.prepare` so the models load while the user talks.
3. `endCapture` finalizes the WAV. `transcribeAndProcess` normalizes it, loads the samples and deletes the file, then calls `SpeechEngine.transcribe`.
4. `polishTranscript` removes hesitations deterministically, runs the LLM only if `TextCleanup.needsModel`, and keeps the output only if `TextCleanup.acceptModelOutput` passes.
5. `TextInjector` inserts through the Accessibility API, or pastes via the clipboard in terminals.

State: `AppState` is `.idle` → `.recording`/`.popo` → `.processing` → `.idle`.

## Conventions

- 4-space indent, braces on the same line, lines under ~130 chars, no formatter.
- Singletons use `static let shared`. Callbacks use the `on` prefix (`onRecordStart`).
- `guard` + early return. `try?` for non-critical work. AI cleanup failures fall back to the uncleaned text and never block pasting.
- GCD for concurrency: UI on `DispatchQueue.main`, work on `.global(qos: .userInitiated)`. Engine calls are serialized on `SpeechEngine`'s own queue.
- Comments explain *why*: OS quirks, timing constants, model decisions.
- Shell: `#!/usr/bin/env bash`, `set -euo pipefail`, header usage comment, UPPER_CASE variables, `command -v` preflight checks.
