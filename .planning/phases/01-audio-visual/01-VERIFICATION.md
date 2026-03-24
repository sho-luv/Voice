---
phase: 01-audio-visual
verified: 2026-03-24T00:00:00Z
status: human_needed
score: 5/5 must-haves verified
human_verification:
  - test: "Press fn, speak, release — text appears without sox/rec installed"
    expected: "Recording works, text transcribed and pasted into active app"
    why_human: "Cannot programmatically invoke microphone hardware or simulate recording session"
  - test: "Open Settings > Audio tab, change mic dropdown to AirPods or external mic, record a phrase"
    expected: "Recording uses the selected device; pasted text is from that mic"
    why_human: "Requires hardware device selection and live audio routing — not testable from static analysis"
  - test: "Connect AirPods, select them as mic in Settings, hold fn but don't speak for ~3 seconds"
    expected: "Overlay shows 'No audio detected — check your microphone' warning, then returns to recording overlay"
    why_human: "Requires AirPods hardware and real-time zero-signal path; cannot simulate from code"
  - test: "Hold fn while in Xcode, speak a few words, release"
    expected: "Recording overlay shows Xcode's app icon, the app name 'Xcode', animated waveform bars moving with voice, and an elapsed timer counting up"
    why_human: "Requires visual inspection of the live overlay UI and microphone signal"
  - test: "Record while in Messages app, then record while in Mail — compare AI-cleaned text quality"
    expected: "Messages transcription uses casual tone guidance; Mail uses professional tone (per appContext.toneGuidance in cleanupSystemPrompt)"
    why_human: "Requires subjective evaluation of AI output quality across two different app contexts"
---

# Phase 1: Audio + Visual Verification Report

**Phase Goal:** Users record audio entirely through Apple system frameworks — no Homebrew dependency — with mic selection, waveform feedback, and per-app AI context
**Verified:** 2026-03-24
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (from ROADMAP.md Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | User can press fn and record without sox or any Homebrew binary present | VERIFIED | `recProcess` and `recPath` fully removed (grep returns 0 matches); `AVAudioEngine` + `installTap` + `writeWAVHeader` present in `startRecording()` and `startPopo()`; `install.sh` comment: "sox is no longer required — audio recording uses native AVFoundation" |
| 2 | User can select a specific microphone from Settings and recordings use that device | VERIFIED | `Settings.micDeviceUID` stored/loaded; `makeAudioTab()` builds mic dropdown with `listInputDevices()`; `startRecording()` and `startPopo()` call `AudioUnitSetProperty(..., kAudioOutputUnitProperty_CurrentDevice, ...)` before installing tap |
| 3 | AirPods connected as input show a visible warning rather than silently producing empty transcriptions | VERIFIED | `zeroBufferCount` and `zeroSignalWarningShown` reset on each recording start; audio tap callback checks `rms < 0.0001` after 8+ consecutive buffers and calls `showOverlay(state: .error("No audio detected — check your microphone"))`; auto-dismiss after 3 seconds |
| 4 | Recording overlay shows animated waveform bars that respond to voice amplitude in real time | VERIFIED | `startAnimation()` fires Timer at 30fps reading `appDelegate.currentAudioLevel`; `drawRecordingOverlay()` draws 12 rounded bars via `NSBezierPath(roundedRect: barRect, ...)` scaling by `audioLevels`; `currentAudioLevel` is written by the AVAudioEngine tap callback on each buffer |
| 5 | Recording overlay shows the name of the app that will receive the transcribed text | VERIFIED | `showOverlay()` sets `contentView.targetAppName = app.localizedName` and `contentView.targetAppIcon = app.icon` from `previousApp`; `drawRecordingOverlay()` renders name (controlled by `Settings.shared.overlayShowAppName`) and icon at 16px |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `Voice.swift` | AVAudioEngine recording replacing Process-based rec | VERIFIED | `import AVFoundation`, `var audioEngine: AVAudioEngine?`, `func writeWAVHeader(to:dataSize:)`, all 6 recording paths use engine |
| `Voice.swift` | CoreAudio mic selector and zero-signal detection | VERIFIED | `import CoreAudio`, `struct AudioDevice`, `func listInputDevices()`, `func makeAudioTab()`, `var zeroBufferCount` |
| `Voice.swift` | Enhanced OverlayContentView with waveform, timer, app context | VERIFIED | `func drawRecordingOverlay()`, `var audioLevels: [Float]` (12 samples), `var recordingStartTime: Date?`, `var targetAppName`, `var targetAppIcon`, `weak var appDelegate: AppDelegate?` |
| `install.sh` | Build includes AVFoundation and CoreAudio frameworks | VERIFIED | Line 63: `-framework AVFoundation -framework CoreAudio` both present |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `Voice.swift (startRecording)` | `AVAudioEngine` | `engine.inputNode` + WAV file write | WIRED | `audioEngine?.inputNode.installTap(...)`, writes to `audioFileHandle` |
| `Voice.swift (stopRecording)` | `transcribeAndProcess` | stop engine, finalize WAV, dispatch | WIRED | `audioEngine?.stop()`, `writeWAVHeader(to: handle, dataSize: audioDataSize)`, dispatch to `transcribeAndProcess()` |
| `Voice.swift (Settings.micDeviceUID)` | `AVAudioEngine inputNode` | `kAudioOutputUnitProperty_CurrentDevice` | WIRED | Both `startRecording()` and `startPopo()` call `AudioUnitSetProperty` with device ID before tap installation |
| `Voice.swift (CoreAudio listener)` | Settings Audio tab mic popup | `kAudioHardwarePropertyDevices` notification | WIRED | `AudioObjectAddPropertyListenerBlock` in `viewDidLoad()` calls `self?.refreshMicList()` on device change |
| `Voice.swift (audio tap callback)` | overlay warning | zero-level detection after 8 consecutive buffers | WIRED | `rms < 0.0001` check increments `zeroBufferCount`; threshold triggers `showOverlay(state: .error(...))` |
| `Voice.swift (OverlayContentView)` | `AppDelegate.currentAudioLevel` | Timer callback at 30fps reads level and updates bars | WIRED | `startAnimation()` Timer reads `delegate.currentAudioLevel`, shifts `audioLevels` array, sets `needsDisplay = true` |
| `Voice.swift (OverlayContentView)` | `previousApp.icon` | App icon from `NSRunningApplication.icon` | WIRED | `showOverlay()` sets `contentView.targetAppIcon = app.icon` from `previousApp` |
| `Voice.swift (showOverlay)` | `OverlayContentView` | Passes app context info | WIRED | `contentView.targetAppName`, `contentView.targetAppIcon`, `contentView.appDelegate = self`, `contentView.startAnimation()` |
| `Voice.swift (transcribeAndProcess)` | AI cleanup prompt | `AppContext.current()` per-app context | WIRED | Line 2679: `let context = AppContext.current()`, passed to `client.cleanupText(rawText, appContext: context)`; `cleanupSystemPrompt` uses `appContext.appName` and `appContext.toneGuidance` |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| AUD-01 | 01-01-PLAN.md | AVAudioEngine replaces sox/rec | SATISFIED | `recPath`/`recProcess` gone; `audioEngine`, `installTap`, `writeWAVHeader` present; `install.sh` comment confirms sox no longer required |
| AUD-02 | 01-02-PLAN.md | Mic selector in Settings | SATISFIED | `makeAudioTab()` in `viewDidLoad`, `micDeviceUID` setting, `kAudioOutputUnitProperty_CurrentDevice` wired in both recording paths |
| AUD-03 | 01-02-PLAN.md | AirPods/Bluetooth zero-signal graceful handling | SATISFIED | `zeroBufferCount` + `rms < 0.0001` check + "No audio detected" overlay warning |
| AUD-04 | 01-03-PLAN.md | Per-app AI context in cleanup prompt | SATISFIED | `AppContext.current()` called in `transcribeAndProcess()`; `cleanupSystemPrompt(appContext:)` uses `appContext.appName` and `appContext.toneGuidance` |
| VIS-01 | 01-03-PLAN.md | Animated waveform bars responding to voice levels | SATISFIED | 12 bars, 30fps animation loop reading `currentAudioLevel`, `NSBezierPath` rounded bars |
| VIS-02 | 01-03-PLAN.md | Overlay shows which app will receive text | SATISFIED | App name and icon from `previousApp` set in `showOverlay()`, rendered in `drawRecordingOverlay()` |

No orphaned requirements — all 6 requirement IDs from all 3 plans are accounted for and confirmed in the REQUIREMENTS.md traceability table (all marked Phase 1, status Complete).

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `Voice.swift` | 2242, 2437 | Comment "Create WAV file with 44-byte placeholder header" | Info | Intentional design — placeholder header is overwritten on stop; documented in 01-01-SUMMARY.md decisions |
| `Voice.swift` | 604 | `fatalError("init(coder:) not implemented")` | Info | Standard NSView/NSWindow coder init stub — not user-visible, required boilerplate |

No blockers. No stubs hiding in data flow. Old pulse animation code (`startPulse`, `stopPulse`, `pulseTimer`, `pulseAlpha`, `pulseDirection`) fully removed — grep returns 0 matches.

### Human Verification Required

All automated checks pass. The following items require a running app with hardware:

#### 1. End-to-end recording without sox

**Test:** Rename or remove `/opt/homebrew/bin/rec`, press fn in any app, speak, release
**Expected:** Text appears; no error about missing sox
**Why human:** Cannot invoke microphone hardware or simulate absence of a binary path in static analysis

#### 2. Microphone selection routes to correct device

**Test:** Open Settings > Audio tab, select AirPods or an external USB mic from the dropdown, record a phrase
**Expected:** Transcription reflects audio from the selected device, not the built-in mic
**Why human:** Requires hardware routing verification — CoreAudio device selection cannot be confirmed without live recording

#### 3. AirPods zero-signal overlay warning

**Test:** Connect AirPods, select them as the input mic, hold fn without speaking for 3+ seconds
**Expected:** "No audio detected — check your microphone" overlay appears after ~2 seconds, auto-dismisses after 3 seconds, recording overlay returns
**Why human:** Requires AirPods hardware producing a zero-level signal condition

#### 4. Waveform overlay visual behavior

**Test:** Hold fn in any app, speak a sentence, observe the overlay
**Expected:** Overlay (280x64 pill) shows: red dot, app icon (16px), app name, 12 animated waveform bars reacting to voice volume, and an elapsed timer counting up in M:SS format
**Why human:** Visual animation and real-time bar response require human observation

#### 5. Per-app AI context tone adjustment

**Test:** Record the same phrase while in Messages and then in Mail, compare AI-cleaned output
**Expected:** Tone differs — casual/conversational for Messages, professional for Mail (per `appContext.toneGuidance`)
**Why human:** Subjective output quality evaluation across AI providers

### Gaps Summary

No gaps — all 5 success criteria truths are verified, all 6 requirement IDs are satisfied in code, all key links are wired, and the build compiles cleanly. The pending items are human-only runtime/hardware verifications that cannot be resolved through static analysis. The 01-03-SUMMARY.md correctly flags `checkpoint_status: PENDING_HUMAN_VERIFY`.

---

_Verified: 2026-03-24_
_Verifier: Claude (gsd-verifier)_
