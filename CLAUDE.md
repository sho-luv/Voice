<!-- GSD:project-start source:PROJECT.md -->
## Project

**Voice**

Voice is a privacy-first macOS speech-to-text app by Faraday Soft (Enfrosec LLC). Press fn, talk, release — transcribed text is pasted into whatever app you're using. Audio transcription and cleanup happen locally using whisper.cpp and Ollama. No cloud transcription, no remote AI providers, no accounts. Sold as a one-time $29 purchase via LemonSqueezy.

**Core Value:** Local-only, instant dictation that works everywhere on macOS — press a key, speak, text appears. Privacy is non-negotiable.

### Constraints

- **No Xcode**: Build with swiftc directly — keeps it simple, no project file complexity
- **Single file**: Voice.swift monolith — may need to split if it grows past ~3000 lines
- **Privacy**: Audio and transcripts stay local; network access is limited to LemonSqueezy license flows and optional localhost Ollama calls
- **Self-contained**: App bundle must include everything (whisper-cli, dylibs, model) — no homebrew dependencies at runtime
- **macOS only**: Target macOS 13+ (Ventura and later)
- **Accessibility permission**: Required for global hotkey — UX must handle permission flow gracefully
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages
- Swift - Single-file macOS app (`Voice.swift`, ~2230 lines). All application logic: UI, audio recording, transcription orchestration, AI text cleanup, settings, menu bar, overlay window.
- Bash - Build/install tooling (`install.sh`, `create-dmg.sh`, `voice.sh`). CLI companion tool and packaging scripts.
- HTML/CSS - Marketing website (`website/index.html`, `website/privacy.html`, `website/terms.html`). Static site hosted on GitHub Pages at `faradaysoft.com`.
## Runtime
- macOS native (AppKit/Cocoa). No iOS, no cross-platform.
- Apple Silicon (arm64) primary target. Uses `/opt/homebrew/bin/` paths (Homebrew on Apple Silicon).
- Bundle identifier: `com.faradaysoft.voice`
- Homebrew - External dependency installation (`whisper-cpp`, `sox`, optionally `ollama`)
- No Swift Package Manager, no CocoaPods, no Xcode project file
## Frameworks
- Cocoa - AppKit UI: `NSStatusBar`, `NSMenu`, `NSWindow`, `NSViewController`, `NSView`
- ApplicationServices - `CGEvent` tap for global hotkey monitoring, accessibility API
- UserNotifications - `UNUserNotificationCenter` for native macOS notifications
- AVFoundation - Imported but audio recording uses `rec` (sox) via `Process`, not AVFoundation directly
- `swiftc` (Swift compiler) - Direct compilation, no Xcode project or SPM
- `codesign` - Ad-hoc or "Voice Dev" certificate signing
- `hdiutil` - DMG creation for distribution
- `install_name_tool` / `otool` - Dylib rebasing for self-contained app bundle
## Key Dependencies
- `whisper-cpp` (via Homebrew `whisper-cli`) - Local speech-to-text engine. Bundled into `Voice.app/Contents/Resources/whisper-cli` with dylibs in `Contents/Frameworks/`. Falls back to `/opt/homebrew/bin/whisper-cli` if not bundled.
- `sox` (`rec` command) - Audio recording from microphone. Used at `/opt/homebrew/bin/rec`. Records 16kHz mono 16-bit WAV files.
- Whisper model file - `ggml-large-v3-turbo-q5_0.bin` (~574 MB). Stored at `~/Library/Application Support/Voice/Models/`. Downloaded from Hugging Face during install.
- `ollama` (via Homebrew) - Local LLM inference for text cleanup. Default model: `llama3.2:3b`. Runs as a background service on `localhost:11434`.
## Configuration
- `hotkeyIndex` - Push-to-talk key (fn, Right Option, Left Option, Right Cmd)
- `soundsEnabled` - Audio feedback on record start/stop
- `autoStartOnLogin` - LaunchAgent management
- `popoTimeout` - POPO mode timeout (1-30 minutes)
- `clipboardRestore` - Restore clipboard after paste
- `aiEnabled` - Enable/disable AI text cleanup
- `aiModelOllama` - Ollama model used for local text cleanup
- `whisperModel` - Whisper model variant name
- `Info.plist` - App metadata, version (`3.2`), bundle ID, microphone usage description
- `Voice.entitlements` - Audio input, Apple Events automation, disable library validation, allow unsigned executable memory, allow dyld env vars
- Prefers "Voice Dev" certificate from Keychain if available
- Falls back to ad-hoc signing (`codesign --force --deep --sign -`)
- Entitlements in `Voice.entitlements`
## Platform Requirements
- macOS with Xcode Command Line Tools (for `swiftc`)
- Homebrew
- `whisper-cpp` formula installed (`brew install whisper-cpp`)
- `sox` installed (`brew install sox`) - required for `rec` binary used in audio recording
- macOS (Apple Silicon preferred, paths hardcoded to `/opt/homebrew/`)
- Accessibility permission (for global hotkey event tap via `CGEvent`)
- Microphone permission (for audio recording)
- App bundles `whisper-cli` + dylibs for self-contained operation
- Whisper model downloaded on first use or bundled
- LaunchAgent at `~/Library/LaunchAgents/com.local.voice.plist`
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

## Architecture: Single-File Swift App
## Code Organization
## Naming Patterns
- `Voice.swift` -- the entire app (PascalCase)
- `voice.sh` -- CLI companion (lowercase)
- `install.sh`, `create-dmg.sh` -- build/distribution scripts (lowercase, hyphenated)
- PascalCase: `AppDelegate`, `InputMonitor`, `OverlayWindow`, `TextInjector`, `OllamaClient`
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
- Entire app lives in one file: `Voice.swift` (2230 lines)
- No Xcode project -- compiled directly with `swiftc` via shell scripts
- Runs as a menu bar accessory app (`NSApplication.setActivationPolicy(.accessory)`)
- Uses `CGEventTap` for global hotkey interception (requires Accessibility permission)
- Delegates to external CLI tools (`rec` from SoX, `whisper-cli`) via `Process` for audio recording and transcription
- State machine driven by `AppState` enum: idle -> recording/popo -> processing -> idle
## Layers
- Purpose: Intercepts global keyboard events to trigger recording
- Location: `Voice.swift` lines 272-438 (`InputMonitor` class)
- Contains: CGEventTap setup, fn/modifier key tracking, push-to-talk and POPO mode logic
- Depends on: `Settings` for hotkey configuration
- Used by: `AppDelegate` (wires callbacks in `applicationDidFinishLaunching`)
- Purpose: Records audio via external `rec` (SoX) process
- Location: `Voice.swift` lines 1860-2037 (methods on `AppDelegate`: `startRecording`, `stopRecording`, `startPopo`, `stopPopo`)
- Contains: Process lifecycle management for `rec`, temp file handling
- Depends on: `/opt/homebrew/bin/rec` (SoX)
- Used by: InputMonitor callbacks
- Purpose: Converts recorded audio to text using whisper.cpp
- Location: `Voice.swift` lines 2039-2113 (`transcribeAndProcess` method on `AppDelegate`)
- Contains: whisper-cli Process invocation, output parsing
- Depends on: whisper-cli binary (bundled in app or at `/opt/homebrew/bin/whisper-cli`), Whisper GGML model file
- Used by: `stopRecording()` and `stopPopo()` dispatch to this on a background queue
- Purpose: Cleans up raw transcription using LLM (remove filler words, fix grammar)
- Location: `Voice.swift` lines 264-1048
- Contains: `OllamaClient` local cleanup implementation
- Depends on: Local Ollama server
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
- Contains: UserDefaults wrapper, tabbed NSWindow with General/AI/Transcription tabs, Ollama install flow
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
- Implementation: `OllamaClient`
- Pattern: Single local cleanup path with graceful fallback
- Purpose: Captures the active app/window/field context for AI tone guidance
- Definition: `Voice.swift` lines 191-246
- Pattern: Uses macOS Accessibility API (`AXUIElementCreateSystemWide`) to detect active app name, window title, and focused field role
- Used in: AI system prompt to adjust tone (professional for Mail, casual for Messages, technical for Xcode)
- Purpose: Centralized configuration with UserDefaults persistence
- Definition: `Voice.swift` lines 39-187
- Pattern: Singleton (`Settings.shared`) with computed properties wrapping UserDefaults
- Notable: `aiModel` wraps the persisted `aiModelOllama` setting
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
- Responsibilities: Prevents duplicate instances, requests notification permissions, creates menu bar item, wires InputMonitor callbacks, starts event tap, registers wake-from-sleep observer, runs preflight checks (whisper model, Ollama health)
- Location: `Voice.swift` lines 345-437 (`InputMonitor.eventTapCallback`)
- Triggers: Any keyboard event system-wide (flagsChanged, keyDown, keyUp)
- Responsibilities: Detects hotkey press/release, Space+hotkey combo, Escape cancel. Dispatches to `onRecordStart`/`onRecordStop`/`onPopoStart`/`onPopoStop`/`onCancel` closures on main thread
## Error Handling
- Recording failures: catch Process launch errors, reset to `.idle`, show notification via `UNUserNotificationCenter`
- Transcription failures: check file size (> 1000 bytes), check non-empty output, fallback to raw text if AI cleanup fails
- Ollama cleanup failures return the original (uncleaned) text on any error -- never block the pipeline
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
