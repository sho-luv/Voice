---
phase: 01-audio-visual
plan: "03"
subsystem: overlay-visual
tags: [overlay, waveform, animation, avfoundation, app-context, settings]
dependency_graph:
  requires: [AVAudioEngine-recording, currentAudioLevel, writeWAVHeader]
  provides: [waveform-overlay, elapsed-timer, app-context-display, overlay-settings-properties]
  affects: [Voice.swift-OverlayContentView, Voice.swift-showOverlay, Voice.swift-hideOverlay]
tech_stack:
  added: []
  patterns: [Timer-animation-loop, NSBezierPath-rounded-bars, NSRunningApplication-icon]
key_files:
  created: []
  modified:
    - Voice.swift
decisions:
  - "Use pattern match (if case .recording = overlayState) instead of == comparison — OverlayState has associated values and cannot conform to Equatable without manual implementation"
  - "Add overlay Settings properties (overlayShowAppName/Icon/Timer) in this plan since Plan 02 runs in parallel — avoids blocking dependency"
  - "Waveform smoothing: shift-blend algorithm (70/30 weighting) with 8x amplification gives visually responsive bars without jitter"
metrics:
  duration_minutes: 7
  completed_date: "2026-03-24"
  tasks_completed: 2
  files_modified: 1
checkpoint_status: PENDING_HUMAN_VERIFY
requirements_satisfied: [VIS-01, VIS-02, AUD-04]
---

# Phase 01 Plan 03: Overlay Waveform, Timer, and App Context Summary

WhatsApp-inspired waveform overlay with animated audio-level bars, elapsed timer, and target app icon + name — replacing the old pulse animation with real-time visual feedback.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Redesign OverlayContentView with waveform bars, timer, and app context | f845736 | Voice.swift |
| 2 | Full build verification and cleanup | dac4a0a | Voice.swift |

## Task Pending Checkpoint

| Task | Name | Status |
|------|------|--------|
| 3 | Verify recording, waveform, mic selection, and app context | AWAITING_HUMAN_VERIFY |

## What Was Built

### Redesigned OverlayContentView

Replaced the old pulse-animation overlay with a rich recording overlay:

**Layout:** `[dot] [app icon] [app name] | [waveform bars] | [0:15]`

- **Waveform bars**: 6 rounded bars at 20fps. Each frame reads `AppDelegate.currentAudioLevel` (Float RMS from AVAudioEngine), applies 8x amplification for visual impact, smooths via shift-blend algorithm.
- **Elapsed timer**: Shows `M:SS` format. Updates every second. Controlled by `Settings.shared.overlayShowTimer`.
- **App icon**: 16px icon from `NSRunningApplication.icon` of `previousApp`. Controlled by `Settings.shared.overlayShowAppIcon`.
- **App name**: From `NSRunningApplication.localizedName`, capped at 60px width. Controlled by `Settings.shared.overlayShowAppName`.
- **Dot color**: Red for `.recording`, blue for `.popo`. Pattern-matched via `if case .recording = overlayState`.

### Properties Added to OverlayContentView

- `var audioLevels: [Float]` — 6-element array, updated at 20fps
- `var recordingStartTime: Date?` — set when animation starts
- `var targetAppName: String` — populated from previousApp
- `var targetAppIcon: NSImage?` — populated from previousApp.icon
- `weak var appDelegate: AppDelegate?` — reads currentAudioLevel
- `func startAnimation()` — starts waveform + elapsed timer loops
- `func stopAnimation()` — invalidates timers, resets levels

### Properties Removed

- `private var pulseTimer: Timer?` — eliminated
- `private var pulseAlpha: CGFloat` — eliminated
- `private var pulseDirection: CGFloat` — eliminated
- `func startPulse()` — eliminated
- `func stopPulse()` — eliminated

### Settings Properties Added (Plan 02 Dependency Auto-resolved)

Since Plan 02 runs in parallel, added these Settings properties in this plan to unblock:
- `var overlayShowAppName: Bool` — default `true`
- `var overlayShowAppIcon: Bool` — default `true`
- `var overlayShowWindowTitle: Bool` — default `false`
- `var overlayShowTimer: Bool` — default `true`

### Updated showOverlay / hideOverlay

`showOverlay()` now:
1. Sets `contentView.appDelegate = self` for audio level access
2. On `.recording` / `.popo`: reads `previousApp` for icon + name, calls `startAnimation()`
3. On other states: calls `stopAnimation()`, clears app context

`hideOverlay()` calls `stopAnimation()` (previously `stopPulse()`).

### OverlayWindow Resized

Changed from 220x44 to 280x64 to accommodate waveform bars + app context alongside dot and timer.

### AUD-04 Confirmed

`cleanupSystemPrompt(appContext:)` exists and uses `appContext.appName` and `appContext.toneGuidance`. Already implemented, no change needed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] OverlayState Equatable comparison failed compilation**
- **Found during:** Task 2 (full build)
- **Issue:** `drawRecordingOverlay()` used `overlayState == .recording` but `OverlayState` has associated values (`.done(String)`, `.error(String)`) and cannot synthesize `==`
- **Fix:** Replaced with `if case .recording = overlayState { isRecordingState = true } else { isRecordingState = false }`
- **Files modified:** Voice.swift
- **Commit:** dac4a0a

**2. [Rule 3 - Blocking] Plan 02 Settings properties missing**
- **Found during:** Task 1
- **Issue:** Plan 03 references `Settings.shared.overlayShowAppName/AppIcon/Timer` which Plan 02 was supposed to add, but Plan 02 runs in parallel and hadn't committed them yet
- **Fix:** Added the four overlay Settings properties directly in this plan (plus defaults registration)
- **Files modified:** Voice.swift
- **Commit:** f845736

## Known Stubs

None — waveform reads live audio level from `currentAudioLevel`, app context reads from `previousApp`, timer reads from `recordingStartTime`. All data sources are fully wired.

## Self-Check: PASSED (Tasks 1-2)

- [x] `Voice.swift` contains `var audioLevels: [Float]`
- [x] `Voice.swift` contains `var targetAppName: String`
- [x] `Voice.swift` contains `var targetAppIcon: NSImage?`
- [x] `Voice.swift` contains `weak var appDelegate: AppDelegate?`
- [x] `Voice.swift` contains `func startAnimation()`
- [x] `Voice.swift` contains `func stopAnimation()`
- [x] `Voice.swift` contains `func drawRecordingOverlay()`
- [x] `Voice.swift` does NOT contain `startPulse` or `pulseTimer`
- [x] `Voice.swift` does NOT contain `recProcess` or `recPath`
- [x] `Voice.swift` contains `cleanupSystemPrompt(appContext:`
- [x] `bash install.sh` builds Voice.app without errors
- [x] Commit f845736 exists
- [x] Commit dac4a0a exists

## Checkpoint Pending

Task 3 requires human verification of the running app. See checkpoint details returned to orchestrator.
