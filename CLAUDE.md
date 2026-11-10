# Voice

Privacy-first macOS dictation: hold fn, speak, release, and the text is inserted where the cursor is. Speech recognition (Parakeet or Whisper) and AI cleanup (Qwen via llama.cpp) run in-process on the Mac. No cloud, accounts, usage limits or telemetry. GPL-3.0-or-later.

Version 4 is the "(Not Boring)" rework of `~/home/projects/mine/voice` (3.4): the same engine and pipeline, with a SwiftUI face in the Lock Chimes design language (`~/.claude/skills/not-boring-ios`): a 3D clay microphone hero, four themes, mono spec sheets, chunky buttons, synthesized sounds, and a supporter (tip jar) screen. Read that skill's `SKILL.md` before changing the UI.

## Constraints

- **No Xcode project.** Build with `swiftc` via the shell scripts.
- **Privacy.** Audio and transcripts never leave the Mac. The only network access is SHA-256-verified model downloads from Hugging Face and the user-initiated update check. Don't add analytics or remote AI.
- **Self-contained.** The app bundle is one statically linked executable. No helper binaries, dylibs or Homebrew at runtime.
- **Platform.** macOS 14+ (SwiftUI `onChange`, `.menuStyle(.button)`), universal (Apple Silicon + Intel). Apple Silicon uses Metal; the Intel slice runs on CPU (AVX2). `VOICE_UNIVERSAL=1` builds both arches (releases); dev builds default to the host arch.
- **Measure, don't guess.** Capture, audio preparation and decoding changes go through `Voice --bench` before and after; the results table lives in `MODELS.md`.
- **Languages.** Both ASR models are multilingual (Parakeet TDT v3 auto-detects; Whisper takes a language code or "auto"). The `transcriptionLanguage` setting steers Whisper and gates the English-only text cleanup — `polishTranscript` only runs the hesitation/LLM cleanup for English or Automatic.
- **License.** Keep SPDX headers on new source files. Credit new dependencies or models in `THIRD_PARTY_NOTICES.md`.
- **No paywall.** "Support Voice" is a pay-what-you-want Stripe Payment Link with an honor-system badge (`SUPPORT.md`). Nothing is gated; don't add license checks.
- **Design rules.** One hero per screen, ground + surface + ink + one accent (+ warning yellow), `display`/`heavy`/`mono` type, `SpecRow` for data, every tappable thing presses down and makes a sound (`Feedback`). Big moments get a full-screen payoff ("YOU'RE IN.", "THANK YOU.").

## Layout

| Path | What |
|------|------|
| `Voice.swift` | App core: settings, hotkey event tap, audio capture, overlay (with the 3D mic), text injection, menu bar, URL handler, preview mode, `@main` entry |
| `AudioCapture.swift` | Microphone capture on AudioQueue (16 kHz mono Int16), every CoreAudio call off the main thread with start/stop watchdogs |
| `AudioPrep.swift` | `AudioPrep` (speech detection results → trimmed, level-set pieces of at most 28 s) and `Bench` (`Voice --bench`) |
| `ModelDownload.swift` | SHA-256-verified model downloads, publishing progress to `DownloadView` |
| `Design/` | The design system ported from iOS: `Theme` + components, `Feedback` (synth sounds, trackpad haptics), `HeroModel` (`MicStyle`: stage, vintage, ribbon, podcast, built from primitives), `HeroSceneView` (`MicController`, `MicSceneView`) |
| `Views/` | SwiftUI screens: `HomeView` (hero + settings panels), `OnboardingView`, `LookView`, `SupportView`, `DownloadView`, `Windows` (`AppWindows`, `AppModel`, `ThemedRoot`) |
| `Support/SupportStore.swift` | Supporter badge, Stripe link, `voice://` URL handling |
| `tools/icon/main.swift` | Renders `icon.png`/`Voice.icns` from the hero; `tools/thanks.html` is the website's post-payment page |
| `SpeechEngine.swift` | `ModelCatalog` (pinned URLs + SHA-256), `SpeechEngine` (serial queue, preload, idle unload), `TextCleanup`, `SelfTest` |
| `engine/VoiceEngine.{h,cpp}` | C wrapper over whisper.cpp (Whisper + Parakeet) and llama.cpp |
| `engine/build.sh` | Builds `engine/build/libvoiceengine.a` from pinned whisper.cpp/llama.cpp tags against one shared ggml |
| `build-app.sh` | Engine, then `swiftc`, then `Voice.app`. Used by `install.sh` and `create-dmg.sh` |
| `icon.svg`, `render-icon.sh` | The retired 3.x vector icon. Don't run it for 4.0: it overwrites `icon.png`/`Voice.icns`. The 4.0 icon comes from `tools/icon` with `--image Resources/Mics/vintage.png` |
| `voice.sh` | Optional terminal companion (Homebrew `whisper-cli` + `sox`) |
| `tools/bench/` | `make-sets.py` builds faulty copies of a clean test set, `run.sh` + `wer.py` score `Voice --bench` output. Use it before and after any change to capture, preparation or decoding |
| `Resources/Models/` | The bundled voice activity model (Silero, 0.9 MB); `build-app.sh` checks its SHA-256 |
| `MODELS.md` | Model benchmarks and selection history. Read it before changing a model or the cleanup prompt |

## Build and verify

```bash
./build-app.sh                                     # engine (cached) + app bundle
./install.sh                                       # build, sign, install to /Applications
./Voice.app/Contents/MacOS/Voice --selftest a.wav  # headless: transcribe + cleanup battery
tools/bench/run.sh <bench-dir> <label>             # word error rate per test set (see MODELS.md, Audio preparation)
./Voice.app/Contents/MacOS/Voice -screen home -tab ai -theme hazard -shot x.png   # screenshot QA (see README)
```

Screenshot QA loop: render every screen (`home` with `-tab`, `onboarding` with `-step`, `look`, `support`, `thanks`, `download`, `overlay*`) in all four themes, tile them with PIL, look, fix, repeat. Don't guess at layout.

CI (`.github/workflows/ci.yml`) typechecks with
`swiftc -parse-as-library -typecheck Voice.swift SpeechEngine.swift ModelDownload.swift Design/*.swift Views/*.swift Support/*.swift -import-objc-header Voice-Bridging-Header.h -I engine ...`

Accessibility permission is tied to the code signature. Sign with a stable identity (Developer ID or a local "Voice Dev" cert) or the permission is lost on every rebuild.

## Pipeline

1. `InputMonitor` (CGEventTap) detects hold, double-tap (hands-free, `.popo`) and Escape.
2. `beginCapture` starts `AudioCapture` (AudioQueue, 16 kHz mono Int16 into a temp WAV) before any UI, and calls `SpeechEngine.prepare` so the models load while the user talks. A mic that sends only zeros for 2 s is swapped for the built-in one.
3. `endCapture` keeps capturing for 250 ms after release, then finalizes the WAV. `transcribeAndProcess` loads the samples, deletes the file and calls `SpeechEngine.transcribeRecording`: voice activity detection, "No speech detected" if there is none, trim, cut at pauses into pieces of at most 28 s, transcribe each (`AudioPrep`).
4. `polishTranscript` removes hesitations deterministically, runs the LLM only if `TextCleanup.needsModel`, and keeps the output only if `TextCleanup.acceptModelOutput` passes.
5. `TextInjector` inserts through the Accessibility API, or pastes via the clipboard in terminals.

State: `AppState` is `.idle` → `.recording`/`.popo` → `.processing` → `.idle`. `updateIcon()` mirrors it into `AppModel.shared.state`, which the SwiftUI hero watches (listening pulse, bounce on done). The overlay's own `MicController` gets the live audio level (`setLevel`).

## Conventions

- 4-space indent, braces on the same line, lines under ~130 chars, no formatter.
- The chosen theme and mic (`ThemeStore.current`, `.heroStyle`) post `.voiceThemeChanged`; `MicSceneView.updateNSView` and the overlay rebuild the geometry in place when the style changes.
- SwiftUI binds to `Settings` through `SettingsBinder.bind(\.key)`; AppKit code (overlay, menu bar) reads `ThemeStore.shared.current` and listens for `.voiceThemeChanged`.
- Singletons use `static let shared`. Callbacks use the `on` prefix (`onRecordStart`).
- `guard` + early return. `try?` for non-critical work. AI cleanup failures fall back to the uncleaned text and never block pasting.
- GCD for concurrency: UI on `DispatchQueue.main`, work on `.global(qos: .userInitiated)`. Engine calls are serialized on `SpeechEngine`'s own queue.
- Comments explain *why*: OS quirks, timing constants, model decisions.
- Shell: `#!/usr/bin/env bash`, `set -euo pipefail`, header usage comment, UPPER_CASE variables, `command -v` preflight checks.
