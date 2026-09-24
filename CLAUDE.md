<!-- GSD:project-start source:PROJECT.md -->
## Project

**Voice**

Voice is a privacy-first macOS speech-to-text app by Faraday Soft (Enfrosec LLC). Press fn, talk, release — transcribed text is pasted into whatever app you're using. Speech recognition (Parakeet/Whisper) and AI cleanup (Qwen via llama.cpp) run in-process on the Mac. No cloud, no accounts, no usage limits. Free and open source under GPL-3.0-or-later.

**Core Value:** Local-only, instant dictation that works everywhere on macOS — press a key, speak, text appears. Privacy is non-negotiable.

### Constraints

- **No Xcode**: Build with swiftc directly — keeps it simple, no project file complexity
- **Two Swift files**: `Voice.swift` (app/UI) + `SpeechEngine.swift` (model catalog, engine wrapper, text cleanup). Entry point is `@main enum VoiceMain`, compiled with `-parse-as-library`
- **License**: GPL-3.0-or-later (`LICENSE`); keep SPDX headers on new source files and credit new deps in `THIRD_PARTY_NOTICES.md`
- **Privacy**: Audio and transcripts stay local; the only network access is SHA-256-verified model downloads (Hugging Face) and the user-initiated update check
- **Self-contained**: App bundle is one statically linked executable (engine in `engine/`) — no helper binaries, dylibs or Homebrew at runtime. Models download on first launch (SHA-256 verified)
- **macOS only**: Target macOS 13+ (Ventura and later)
- **Accessibility permission**: Required for global hotkey — UX must handle permission flow gracefully
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Swift - `Voice.swift` (~4800 lines: UI, recording, orchestration, settings, menu bar, overlay) + `SpeechEngine.swift` (model catalog, in-process engine wrapper, text cleanup, `--selftest`). C++ - `engine/VoiceEngine.cpp` wrapper over whisper.cpp/llama.cpp.
- Bash - Build/install tooling (`engine/build.sh`, `build-app.sh`, `install.sh`, `create-dmg.sh`, `voice.sh`).
- HTML/CSS - Marketing website (`website/index.html`, `website/privacy.html`, `website/terms.html`). Static site hosted on GitHub Pages at `faradaysoft.com`.
## Runtime
- macOS native (AppKit/Cocoa). No iOS, no cross-platform.
- Apple Silicon (arm64) only.
- Bundle identifier: `com.faradaysoft.voice`
- Homebrew - Build-time only: `cmake` (engine build), `create-dmg`; `whisper-cpp`/`sox` only for the optional `voice.sh` CLI
- No Swift Package Manager, no CocoaPods, no Xcode project file
## Frameworks
- Cocoa - AppKit UI: `NSStatusBar`, `NSMenu`, `NSWindow`, `NSViewController`, `NSView`
- ApplicationServices - `CGEvent` tap for global hotkey monitoring, accessibility API
- UserNotifications - `UNUserNotificationCenter` for native macOS notifications
- AVFoundation - Audio recording via `AVAudioEngine`, `AVAudioConverter`, and mic permission handling
- `swiftc` (Swift compiler) - Direct compilation, no Xcode project or SPM
- `codesign` - Ad-hoc or "Voice Dev" certificate signing
- `hdiutil` - DMG creation for distribution
- `cmake` + `clang++` - Build `engine/build/libvoiceengine.a` via `engine/build.sh` (pinned whisper.cpp + llama.cpp tags, one shared ggml, Metal embedded)
## Key Dependencies
- **Engine** (`engine/VoiceEngine.h/.cpp`, `engine/build.sh`) - C wrapper over whisper.cpp v1.9.4 (Whisper + Parakeet) and llama.cpp b11151, statically linked. `ve_asr_*` for speech, `ve_llm_*` for cleanup. Swift wrapper: `SpeechEngine` (serial queue, preload on record start, warm-up at launch, 10-min idle unload)
- `sox` (`rec` command) - Optional recording dependency for the standalone `voice.sh` CLI.
- Models (`ModelCatalog` in `SpeechEngine.swift`, pinned URL + SHA-256): Parakeet TDT 0.6B v3 Q4_0 (default ASR, 356 MB), Whisper large-v3-turbo Q5_0 (optional ASR, 574 MB — only model that takes the vocabulary prompt), Qwen2.5-1.5B-Instruct Q4_0 (cleanup, 1.07 GB). Stored in `~/Library/Application Support/Voice/Models/`
- Cleanup pipeline (`polishTranscript` in `Voice.swift`): deterministic hesitation removal → LLM only if `TextCleanup.needsModel` → output kept only if `TextCleanup.acceptModelOutput` says it is still a faithful rewrite. See MODELS.md
## Configuration
- `hotkeyIndex` - Push-to-talk key (fn, Right Option, Left Option, Right Cmd)
- `soundsEnabled` - Audio feedback on record start/stop
- `autoStartOnLogin` - LaunchAgent management
- `popoTimeout` - POPO mode timeout (1-30 minutes)
- `clipboardRestore` - Restore clipboard after paste
- `aiEnabled` - Enable/disable AI text cleanup
- `aiModelOllama` - Legacy persisted key retained for compatibility with older installs
- `speechModel` - `ModelCatalog` id (migrated from legacy `whisperModel`: vocabulary users → Whisper, others → Parakeet)
- `Info.plist` - App metadata, version (`3.2`), bundle ID, microphone usage description
- `Voice.entitlements` - Audio input only. No library-validation / unsigned-memory / dyld exceptions (nothing external is loaded)
- Prefers "Voice Dev" certificate from Keychain if available
- Falls back to ad-hoc signing (`codesign --force --sign - --options runtime`) — single signature, nothing nested
- Entitlements in `Voice.entitlements`
## Platform Requirements
- macOS with Xcode Command Line Tools (for `swiftc`)
- Homebrew
- `cmake` installed (`brew install cmake`) — `engine/build.sh` clones pinned sources into `engine/.deps`
- Verify without UI: `Voice.app/Contents/MacOS/Voice --selftest file.wav` (transcribes + runs the MODELS.md cleanup battery)
- `sox` installed (`brew install sox`) - optional, used by `voice.sh`
- macOS 13+ on Apple Silicon (engine is arm64-only)
- Accessibility permission (for global hotkey event tap via `CGEvent`)
- Microphone permission (for audio recording)
- App bundle is ~7 MB: executable + Info.plist + icon (`build-app.sh`)
- Models downloaded on first launch by `ModelDownloadWindowController`; `VOICE_BUNDLE_MODELS=1` bundles them for offline builds
- LaunchAgent at `~/Library/LaunchAgents/com.faradaysoft.voice.plist`
- Managed programmatically by `Settings.updateLaunchAgent()`
## Distribution
- Built by `create-dmg.sh` using `hdiutil` (UDZO compressed)
- Contains `Voice.app` + symlink to `/Applications`
- Current version: `Voice-3.2.dmg`
- Not notarized (requires Apple Developer ID)
- Static HTML at `website/` directory
- GitHub Pages with custom domain `faradaysoft.com`
- Pages: landing (`index.html`), privacy policy (`privacy.html`), terms (`terms.html`)
- `voice.sh` - Standalone CLI for recording + transcription (uses `rec` and `whisper-cli` directly)
- Symlinked to `~/bin/voice` by `install.sh`
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## Architecture: Swift App + Static C++ Engine
## Code Organization
## Naming Patterns
- `Voice.swift` -- the entire app (PascalCase)
- `voice.sh` -- CLI companion (lowercase)
- `install.sh`, `create-dmg.sh` -- build/distribution scripts (lowercase, hyphenated)
- PascalCase: `AppDelegate`, `InputMonitor`, `OverlayWindow`, `TextInjector`, `SpeechEngine`, `ModelCatalog`, `TextCleanup`
- Singletons use `static let shared`: `Settings.shared`, `SettingsWindowController.shared`
- PascalCase type names: `AppState`, `OverlayState`
- camelCase cases: `.idle`, `.recording`, `.popo`, `.processing`
- Associated values for data-carrying cases: `.done(String)`, `.error(String)`
- camelCase: `startRecording()`, `stopPopo()`, `transcribeAndProcess()`
- Callbacks use `on` prefix: `onRecordStart`, `onRecordStop`, `onCancel`, `onPopoStart`, `onPopoStop`
- Private helpers use `try` prefix for fallible operations: `tryAXInject(_:)`
- Boolean checks are verb-like: `healthCheck(completion:)`, `testConnection(completion:)`
- camelCase: `recProcess`, `audioFile`, `previousApp`, `statusItem`
- Private state uses simple names: `fnDown`, `fnDownTime`, `isRecording`, `isPopo`, `spaceHeld`
- Constants as `let` properties: `baseURL`, `recPath`, `afplayPath`, `minHoldDuration`
- camelCase strings matching property names: `"hotkeyIndex"`, `"soundsEnabled"`, `"aiModelOllama"`
## Code Style
- No external formatter (no .prettierrc, .swiftformat, .swiftlint)
- 4-space indentation throughout
- Opening braces on same line as declaration
- Single blank line between methods
- No trailing whitespace
- No enforced limit, but lines generally stay under ~130 characters
- Long guard chains break at each condition with aligned commas
## Import Organization
## Error Handling
- `try?` for non-critical operations (file deletion, JSON serialization, process launch):
- `guard` + early return for validation:
- AI client fallback: if cleanup fails, return original text unchanged:
- `do/catch` only for critical operations (process launch in recording):
## Async Patterns
- `URLSession.shared.dataTask` with completion handlers
- `DispatchQueue.main.async` for UI updates from background threads
- `DispatchQueue.main.asyncAfter` for timed delays
- `DispatchQueue.global(qos: .userInitiated).async` for background work
- `Timer.scheduledTimer` for periodic updates (pulse animation, POPO timeout)
## UI Construction
## Logging
## Comments
- Explain non-obvious design decisions (especially competitive references):
- Document workarounds for OS quirks:
- Explain timing constants:
## Singleton Pattern
## Protocol Usage
## Process Execution
## Shell Script Conventions (`voice.sh`, `install.sh`, `create-dmg.sh`)
- Shebang: `#!/usr/bin/env bash`
- `set -euo pipefail` at the top of every script
- Header comment block with usage instructions
- UPPER_CASE for script-level variables: `MODEL_DIR`, `AUDIO_FILE`, `REC_PID`
- `cleanup()` trap function for signal handling: `trap cleanup EXIT INT TERM`
- Preflight checks with `command -v` before using external tools
- User-facing output to stderr (`>&2`), data to stdout
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- App code in `Voice.swift` + `SpeechEngine.swift`; ML engine statically linked from `engine/`
- No Xcode project -- compiled directly with `swiftc` via shell scripts
- Runs as a menu bar accessory app (`NSApplication.setActivationPolicy(.accessory)`)
- Uses `CGEventTap` for global hotkey interception (requires Accessibility permission)
- Uses `AVAudioEngine` for recording; transcription and cleanup run in-process via the static engine (`SpeechEngine`), no subprocesses
- State machine driven by `AppState` enum: idle -> recording/popo -> processing -> idle
## Layers
- Purpose: Intercepts global keyboard events to trigger recording
- Location: `Voice.swift` lines 272-438 (`InputMonitor` class)
- Contains: CGEventTap setup, fn/modifier key tracking, push-to-talk and POPO mode logic
- Depends on: `Settings` for hotkey configuration
- Used by: `AppDelegate` (wires callbacks in `applicationDidFinishLaunching`)
- Purpose: Records audio via `AVAudioEngine`
- Location: `Voice.swift` lines 1860-2037 (methods on `AppDelegate`: `startRecording`, `stopRecording`, `startPopo`, `stopPopo`)
- Contains: `AVAudioEngine` lifecycle, WAV file writing, mic selection, and temp file handling
- Depends on: `AVFoundation`, `CoreAudio`
- Used by: InputMonitor callbacks
- Purpose: Converts recorded audio to text using whisper.cpp
- Location: `Voice.swift` lines 2039-2113 (`transcribeAndProcess` method on `AppDelegate`)
- Contains: WAV → float samples, `SpeechEngine.transcribe`, output normalization, `polishTranscript`
- Depends on: `SpeechEngine` + installed speech model (`Settings.speechModel`)
- Used by: `stopRecording()` and `stopPopo()` dispatch to this on a background queue
- Purpose: Cleans up raw transcription using LLM (remove filler words, fix grammar)
- Location: `Voice.swift` lines 264-1048
- Contains: `polishTranscript`, `cleanupSystemPrompt`, `TextCleanup` (in `SpeechEngine.swift`)
- Depends on: `SpeechEngine.generateCleanup` (in-process llama.cpp) and the Qwen GGUF model; `TextCleanup` guardrails
- Used by: `transcribeAndProcess()` after whisper output
- Purpose: Inserts transcribed text into the active application
- Location: `Voice.swift` lines 568-761 (`TextInjector` class, `DelayedClipboardProvider` class)
- Contains: AX API direct injection, clipboard paste fallback with Cmd+V simulation
- Depends on: macOS Accessibility API, `InputMonitor` (to temporarily disable event tap during paste)
- Used by: `refocusAndInject()` on `AppDelegate` (line 2137)
- Purpose: Visual feedback via menu bar icon and floating overlay window
- Location: `Voice.swift` lines 440-566 (`OverlayWindow`, `OverlayContentView`), lines 1783-1858 (icon/overlay methods on `AppDelegate`)
- Contains: Floating borderless window with pulsing animation, menu bar status icon state changes
- Depends on: `AppState` and `OverlayState` enums
- Used by: All state transitions in `AppDelegate`
- Purpose: User preferences and Settings UI
- Location: `Voice.swift` lines 39-187 (`Settings` singleton), lines 1050-1656 (`SettingsWindowController`, `SettingsViewController`)
- Contains: UserDefaults wrapper, tabbed NSWindow with General/AI/Transcription tabs, built-in AI settings, and custom prompt/vocabulary fields
- Depends on: `UserDefaults.standard`
- Used by: All other layers read from `Settings.shared`
## Data Flow
- `AppState` enum (line 7): `.idle`, `.recording`, `.popo`, `.processing` -- owned by `AppDelegate.appState`
- `OverlayState` enum (line 470): `.recording`, `.popo`, `.transcribing`, `.done(String)`, `.error(String)` -- owned by `OverlayContentView.overlayState`
- `InputMonitor` tracks its own `fnDown`, `isRecording`, `isPopo`, `spaceHeld` booleans
- State transitions are imperative (no reactive/binding framework)
## Key Abstractions
- Purpose: Local text cleanup and model health checks
- Definition: `Voice.swift`
- Implementation: `SpeechEngine.generateCleanup` guarded by `TextCleanup.acceptModelOutput`
- Pattern: Single local cleanup path with graceful fallback
- Purpose: Captures the active app/window/field context for AI tone guidance
- Definition: `Voice.swift` lines 191-246
- Pattern: Uses macOS Accessibility API (`AXUIElementCreateSystemWide`) to detect active app name, window title, and focused field role
- Used in: AI system prompt to adjust tone (professional for Mail, casual for Messages, technical for Xcode)
- Purpose: Centralized configuration with UserDefaults persistence
- Definition: `Voice.swift` lines 39-187
- Pattern: Singleton (`Settings.shared`) with computed properties wrapping UserDefaults
- Notable: `aiModel` wraps the legacy persisted `aiModelOllama` setting for compatibility
- Purpose: Lazy clipboard rendering to avoid clipboard conflicts
- Definition: `Voice.swift` lines 573-592
- Pattern: Implements `NSPasteboardItemDataProvider` -- text is provided on-demand when the target app reads the clipboard after Cmd+V
- Inspired by: Wispr Flow's approach (noted in code comments)
## Entry Points
- Location: `Voice.swift` lines 2217-2230
- Triggers: macOS launches the binary (directly or via LaunchAgent)
- Responsibilities: Disables window restoration, creates `NSApplication`, sets `.accessory` activation policy, creates `AppDelegate`, calls `app.run()`
- Location: `Voice.swift` lines 1693-1781
- Triggers: `NSApplication.run()` completes initialization
- Responsibilities: Prevents duplicate instances, requests notification permissions, creates menu bar item, wires InputMonitor callbacks, starts event tap, registers wake-from-sleep observer, runs preflight checks (whisper model, built-in AI model health)
- Location: `Voice.swift` lines 345-437 (`InputMonitor.eventTapCallback`)
- Triggers: Any keyboard event system-wide (flagsChanged, keyDown, keyUp)
- Responsibilities: Detects hotkey press/release, Space+hotkey combo, Escape cancel. Dispatches to `onRecordStart`/`onRecordStop`/`onPopoStart`/`onPopoStop`/`onCancel` closures on main thread
## Error Handling
- Recording failures: catch Process launch errors, reset to `.idle`, show notification via `UNUserNotificationCenter`
- Transcription failures: check file size (> 1000 bytes), check non-empty output, fallback to raw text if AI cleanup fails
- AI cleanup failures return the original (uncleaned) text on any error -- never block the pipeline
- Accessibility permission: on event tap creation failure, shows notification and opens System Settings to Accessibility pane
- Empty/short recordings: dedicated error paths with overlay feedback ("Recording too short", "Empty transcription")
## Cross-Cutting Concerns
<!-- GSD:architecture-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd:quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd:debug` for investigation and bug fixing
- `/gsd:execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd:profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
