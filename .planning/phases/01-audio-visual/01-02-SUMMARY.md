---
phase: 01-audio-visual
plan: "02"
subsystem: audio-input
tags: [coreaudio, mic-selector, settings, zero-signal-detection, airpods]
dependency_graph:
  requires: [AVAudioEngine-recording, currentAudioLevel]
  provides: [mic-selector-UI, CoreAudio-device-enumeration, zero-signal-detection, overlay-display-settings]
  affects: [Voice.swift-startRecording, Voice.swift-startPopo, Voice.swift-SettingsViewController]
tech_stack:
  added: [CoreAudio]
  patterns: [AudioObjectGetPropertyData, AudioUnitSetProperty, AudioObjectAddPropertyListenerBlock, kAudioOutputUnitProperty_CurrentDevice]
key_files:
  created: []
  modified:
    - Voice.swift
    - install.sh
decisions:
  - "Use Unmanaged<CFString> with takeRetainedValue() for CoreAudio CFString properties — avoids unsafe pointer warnings from naive CFString approach"
  - "Zero-signal threshold of rms < 0.0001 after 8 consecutive buffers (~2 seconds at 16kHz/4096 buffer size) — enough to catch AirPods silence without false positives from quiet speech"
  - "Overlay warning auto-dismisses after 3 seconds and returns to recording/popo state — non-blocking UX, user can keep recording"
  - "Register CoreAudio device change listener in viewDidLoad (not makeAudioTab) so listener is always active once Settings window opens"
metrics:
  duration_minutes: 3
  completed_date: "2026-03-24"
  tasks_completed: 2
  files_modified: 2
requirements_satisfied: [AUD-02, AUD-03]
---

# Phase 01 Plan 02: Microphone Selector and Zero-Signal Detection Summary

Add CoreAudio-backed microphone device selector in Settings Audio tab with live device list updates, wired to AVAudioEngine for recording, plus zero-signal detection that warns users when AirPods or Bluetooth mics produce no audio.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add mic selector Settings properties and Audio tab UI | 7891998 | Voice.swift |
| 2 | Wire mic selection to AVAudioEngine and add zero-signal detection | 7891998 | Voice.swift |
| - | Add CoreAudio framework to build script | 41359a8 | install.sh |

## What Was Built

### CoreAudio Device Enumeration

`listInputDevices() -> [AudioDevice]` — top-level function using `AudioObjectGetPropertyDataSize` / `AudioObjectGetPropertyData` to enumerate all system audio devices, filter to input-only (checking `kAudioDevicePropertyStreamConfiguration` on input scope for non-zero channels), and return `AudioDevice` structs with UID, display name, and `AudioDeviceID`.

Uses `Unmanaged<CFString>` with `takeRetainedValue()` for property fetches to avoid unsafe pointer warnings.

### Audio Tab in Settings

New "Audio" tab inserted between General and AI tabs in `SettingsViewController`:
- **Microphone dropdown** (`NSPopUpButton`) with "System Default" + all input devices by name
- **Status label** showing "Preferred device not available" in orange when saved device is gone
- **Overlay display toggles**: Show app name, show app icon, show window title, show recording timer (for Plan 03 waveform overlay)
- Live refresh via `AudioObjectAddPropertyListenerBlock` on `kAudioHardwarePropertyDevices` — mic list updates automatically when devices connect/disconnect

### Mic Selection Wired to AVAudioEngine

Both `startRecording()` and `startPopo()` now:
1. Look up `Settings.shared.micDeviceUID`
2. If non-empty, call `AudioUnitSetProperty(..., kAudioOutputUnitProperty_CurrentDevice, ...)` on the engine's inputNode AudioUnit
3. Fall back to system default silently if device not found (per D-07)

### Zero-Signal Detection

Both `startRecording()` and `startPopo()` now:
1. Reset `zeroBufferCount = 0` and `zeroSignalWarningShown = false` on start
2. In the audio tap callback, after computing RMS: if `rms < 0.0001` for 8+ consecutive buffers (~2 seconds), show `.error("No audio detected — check your microphone")` overlay
3. Auto-dismiss warning after 3 seconds and return to `.recording` / `.popo` overlay state
4. Reset `zeroBufferCount` to 0 whenever signal is detected

### Settings Properties Added

Added to `Settings` class:
- `micDeviceUID: String` — UID of selected mic, empty = system default
- `overlayShowAppName: Bool` — for Plan 03 overlay
- `overlayShowAppIcon: Bool` — for Plan 03 overlay
- `overlayShowWindowTitle: Bool` — for Plan 03 overlay
- `overlayShowTimer: Bool` — for Plan 03 overlay

All registered in `defaults.register` with sensible defaults (mic = system default, overlays = on except window title).

### AppDelegate Properties Added

- `var zeroBufferCount: Int = 0` — consecutive silent buffer count
- `var zeroSignalWarningShown: Bool = false` — prevents repeated warnings per session

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed unsafe CFString pointer usage in listInputDevices()**
- **Found during:** Task 1 (compiler warning during build)
- **Issue:** Plan specified `var name: CFString = "" as CFString` then `&name` as `UnsafeMutableRawPointer` — Swift compiler warns this is likely incorrect for object reference types
- **Fix:** Used `Unmanaged<CFString>?` with `takeRetainedValue()` pattern — correct ownership semantics for CoreAudio CFString properties
- **Files modified:** Voice.swift
- **Commit:** 7891998

## Known Stubs

The overlay display settings (overlayShowAppName, overlayShowAppIcon, overlayShowWindowTitle, overlayShowTimer) are registered and saved but not yet consumed by the overlay UI — that wiring is Plan 03's responsibility. This is intentional per the plan ("register now" for Plan 03).

## Self-Check: PASSED

- [x] `Voice.swift` contains `import CoreAudio`
- [x] `Voice.swift` contains `struct AudioDevice`
- [x] `Voice.swift` contains `func listInputDevices() -> [AudioDevice]`
- [x] `Voice.swift` contains `var micDeviceUID: String` in Settings
- [x] `Voice.swift` contains `var overlayShowAppName: Bool` in Settings
- [x] `Voice.swift` contains `var overlayShowTimer: Bool` in Settings
- [x] `Voice.swift` contains `func makeAudioTab() -> NSTabViewItem`
- [x] `Voice.swift` contains `AudioObjectAddPropertyListenerBlock`
- [x] `Voice.swift` `viewDidLoad` calls `makeAudioTab()`
- [x] `Voice.swift` `startRecording()` contains `kAudioOutputUnitProperty_CurrentDevice`
- [x] `Voice.swift` `startPopo()` contains `kAudioOutputUnitProperty_CurrentDevice`
- [x] `Voice.swift` contains `var zeroBufferCount: Int = 0`
- [x] `Voice.swift` contains `var zeroSignalWarningShown: Bool = false`
- [x] `Voice.swift` audio tap callback contains `rms < 0.0001`
- [x] `Voice.swift` contains `"No audio detected"` overlay warning
- [x] `install.sh` build command includes `-framework CoreAudio`
- [x] `bash install.sh` exits with code 0 (verified)
- [x] Commit 7891998 exists
- [x] Commit 41359a8 exists
