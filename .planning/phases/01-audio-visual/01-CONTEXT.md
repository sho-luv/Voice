# Phase 1: Audio + Visual - Context

**Gathered:** 2026-03-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace sox/rec with native AVFoundation audio recording, add microphone device selector in Settings, add WhatsApp-inspired waveform overlay with timer during recording, and display target app context (icon + name) in the overlay. Eliminates the Homebrew sox dependency for the GUI app.

</domain>

<decisions>
## Implementation Decisions

### AVFoundation Recording
- **D-01:** Use `AVAudioEngine` for audio capture — provides real-time audio buffer callbacks (needed for waveform) and easy mic switching via `inputNode`
- **D-02:** Record raw PCM from AVAudioEngine, write minimal WAV header (44 bytes) + PCM data to produce 16kHz mono 16-bit WAV files compatible with whisper-cli
- **D-03:** Remove sox/rec code path entirely — no fallback. Clean break from Homebrew dependency. If AVFoundation fails, treat it as a bug to fix.
- **D-04:** Leave `voice.sh` CLI as-is — it keeps using sox/rec. Phase 1 scope is the GUI app only.

### Microphone Selector
- **D-05:** Add a new **Audio tab** in Settings (alongside General, AI, Transcription) for microphone selection
- **D-06:** Mic list updates **live** via CoreAudio device change notifications — dropdown refreshes automatically when devices connect/disconnect
- **D-07:** If selected mic disappears (e.g., AirPods disconnected), **fall back to system default** input silently. Show subtle note in Settings that preferred device isn't available.
- **D-08:** AirPods/Bluetooth zero-signal detection: if recording starts and audio buffer levels are consistently zero/near-zero, show **overlay warning** ("No audio detected — check your microphone")

### Waveform Overlay
- **D-09:** **WhatsApp-inspired** vertical rounded bars that animate with voice amplitude — compact, smooth animation, timer beside/below the waveform
- **D-10:** 5-7 vertical bars responding to real-time audio levels from AVAudioEngine buffer callbacks
- **D-11:** Color scheme matches existing overlay theme (dark semi-transparent background, white/accent elements)
- **D-12:** Keep existing overlay position (floating window near menu bar) — no position change
- **D-13:** Show **elapsed recording timer** (0:03, 0:15, etc.) alongside the waveform

### Active App Context
- **D-14:** Display **app icon (16-20px) + app name** in the overlay to show which app will receive transcribed text
- **D-15:** Use `NSWorkspace` to retrieve app icon; `AppContext` (lines 191-246) already detects app name

### Overlay Configuration (Settings)
- **D-16:** Multiple configurable toggles in Settings for overlay display: app name, app icon, window title, timer — each independently toggleable
- **D-17:** Waveform always shown during recording (not configurable — core visual feedback)

### Claude's Discretion
- WAV header implementation details (standard RIFF format)
- Exact number of waveform bars (5-7 range)
- Animation smoothing/interpolation approach for bars
- Overlay layout spacing and sizing details

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Audio Recording
- `Voice.swift` lines 1860-2037 — Current sox/rec recording implementation to be replaced
- `Voice.swift` line 1672 — `recPath` hardcoded constant to remove
- `Voice.swift` lines 2039-2113 — `transcribeAndProcess` method (consumes the WAV file)

### Overlay UI
- `Voice.swift` lines 440-566 — Existing `OverlayWindow` and `OverlayContentView` to be enhanced
- `Voice.swift` lines 1783-1858 — Icon/overlay methods on `AppDelegate`

### App Context Detection
- `Voice.swift` lines 191-246 — `AppContext` class (already detects app name, window title, field role)

### Settings UI
- `Voice.swift` lines 1050-1656 — `SettingsWindowController` and `SettingsViewController` (add Audio tab here)
- `Voice.swift` lines 39-187 — `Settings` singleton (add new UserDefaults properties)

### Concerns
- `.planning/codebase/CONCERNS.md` — Documents sox dependency issue, hardcoded paths, and force casts in AX code

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `OverlayWindow` (lines 440-566): Floating borderless window with existing animation — enhance with waveform bars instead of replacing entirely
- `AppContext` (lines 191-246): Already detects active app name, window title, focused field role — reuse for overlay display
- `Settings` singleton (lines 39-187): Established pattern for adding new UserDefaults-backed properties
- `SettingsWindowController` (lines 1050-1656): Tabbed NSWindow — add Audio tab following existing tab pattern
- `InputMonitor` callbacks: `onRecordStart`/`onRecordStop` already exist — wire AVAudioEngine start/stop here

### Established Patterns
- External process via `Process()` for whisper-cli — keep this pattern for transcription, only replace for recording
- `DispatchQueue.main.async` for UI updates from background threads
- `UserDefaults` for all settings persistence
- Sound feedback via `/usr/bin/afplay` Process (could switch to NSSound but not required for Phase 1)
- State machine: `AppState` enum drives all transitions

### Integration Points
- `startRecording()` / `stopRecording()` on `AppDelegate` — replace Process-based rec with AVAudioEngine
- `startPopo()` / `stopPopo()` — same AVAudioEngine integration for POPO mode
- `OverlayContentView.overlayState` — extend to pass audio levels for waveform rendering
- `Settings.shared` — add micDeviceID, overlay toggle properties
- Build command in `install.sh` and `create-dmg.sh` — AVFoundation already linked, no change needed

</code_context>

<specifics>
## Specific Ideas

- **WhatsApp voice recording UI** as primary visual reference for the waveform overlay — compact rounded bars, smooth animation, timer alongside
- User wants the overlay to feel like WhatsApp's voice message recording, adapted for macOS floating window context

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-audio-visual*
*Context gathered: 2026-03-24*
