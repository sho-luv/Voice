---
phase: 01-audio-visual
plan: "01"
subsystem: audio-recording
tags: [avfoundation, audio, recording, wav, popo]
dependency_graph:
  requires: []
  provides: [AVAudioEngine-recording, currentAudioLevel, writeWAVHeader]
  affects: [Voice.swift-startRecording, Voice.swift-stopRecording, Voice.swift-startPopo, Voice.swift-stopPopo]
tech_stack:
  added: [AVFoundation]
  patterns: [AVAudioEngine-tap, AVAudioConverter, RIFF-WAV-header]
key_files:
  created: []
  modified:
    - Voice.swift
decisions:
  - "Use AVAudioConverter with hardware format tap rather than target format tap directly — more compatible across macOS audio hardware variants"
  - "Write 44-byte placeholder header at file creation, finalize on stop — allows streaming writes without pre-knowing data size"
  - "Expose currentAudioLevel (Float RMS) as AppDelegate property for Plan 03 waveform overlay"
metrics:
  duration_minutes: 18
  completed_date: "2026-03-24"
  tasks_completed: 2
  files_modified: 1
requirements_satisfied: [AUD-01]
---

# Phase 01 Plan 01: AVAudioEngine Recording Infrastructure Summary

Replace sox/rec Process-based audio recording with native AVAudioEngine, producing 16kHz mono 16-bit WAV files compatible with whisper-cli and exposing RMS audio level for waveform visualization.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add AVAudioEngine recording infrastructure and WAV writer | df01c89 | Voice.swift |
| 2 | Build and verify AVAudioEngine recording (+ fix quitApp) | 2afdc08 | Voice.swift |

## What Was Built

### AVAudioEngine Recording Pipeline

`startRecording()` and `startPopo()` now:
1. Create a 44-byte placeholder WAV file
2. Open a `FileHandle` for streaming writes past the header
3. Create `AVAudioEngine`, tap the hardware input node at its native format
4. Use `AVAudioConverter` to downsample to 16kHz mono Int16 per callback
5. Write converted PCM bytes directly to file while accumulating `audioDataSize`
6. Calculate RMS level and post to `currentAudioLevel` on main thread

`stopRecording()` and `stopPopo()` now:
1. Remove tap, stop engine
2. Call `writeWAVHeader(to:dataSize:)` to finalize the RIFF header in-place
3. Close the file handle, dispatch transcription

`cancelRecording()` and `cancelPopo()` clean up engine, file handle, and temp file.

`quitApp()` also cleaned up to use engine teardown instead of recProcess.

### WAV Header Writer

`writeWAVHeader(to:dataSize:)` — top-level function that writes a standard 44-byte RIFF/WAVE header for 16kHz, 1-channel, 16-bit PCM. Seeks to offset 0 before writing, so the placeholder bytes are overwritten in place.

### Properties Added to AppDelegate

- `var audioEngine: AVAudioEngine?` — active engine, nil when idle
- `var audioFileHandle: FileHandle?` — open write handle during recording
- `var audioDataSize: UInt32` — byte count accumulated per recording session
- `var currentAudioLevel: Float` — RMS amplitude, updated in real time for Plan 03

### Properties Removed

- `var recProcess: Process?` — eliminated
- `let recPath = "/opt/homebrew/bin/rec"` — eliminated

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed residual recProcess reference in quitApp()**
- **Found during:** Task 2 (build failure)
- **Issue:** `quitApp()` method still referenced `recProcess` which was removed in Task 1
- **Fix:** Replaced with AVAudioEngine teardown (removeTap, stop, nil engine/handle)
- **Files modified:** Voice.swift
- **Commit:** 2afdc08

## Known Stubs

None — all recording paths are fully wired.

## Self-Check: PASSED

- [x] `Voice.swift` exists and contains `import AVFoundation`
- [x] `Voice.swift` contains `var audioEngine: AVAudioEngine?`
- [x] `Voice.swift` contains `var currentAudioLevel: Float`
- [x] `Voice.swift` contains `func writeWAVHeader`
- [x] `Voice.swift` does NOT contain `let recPath` or `var recProcess`
- [x] Commit df01c89 exists
- [x] Commit 2afdc08 exists
- [x] `swiftc -parse Voice.swift` exits with code 0
- [x] `bash install.sh` builds Voice.app without errors
