# Roadmap: Voice

## Overview

Voice v3.2 ships three phases: native audio pipeline to eliminate Homebrew dependencies and unlock waveform/mic-selection, then code signing and distribution so the app is sellable, then transcription history and voice editing commands to close the feature gap with competitors. Every phase ends with committed, working code.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Audio + Visual** - Replace sox with AVFoundation, add mic selector, waveform overlay, and active-app context (completed 2026-03-24)
- [ ] **Phase 2: Distribution** - Developer ID signing, notarization, first-launch onboarding, and LemonSqueezy license gate
- [ ] **Phase 3: History + Editing** - Transcription history window, custom dictionary, voice commands, and file transcription

## Phase Details

### Phase 1: Audio + Visual
**Goal**: Users record audio entirely through Apple system frameworks — no Homebrew dependency — with mic selection, waveform feedback, and per-app AI context
**Depends on**: Nothing (first phase)
**Requirements**: AUD-01, AUD-02, AUD-03, AUD-04, VIS-01, VIS-02
**Success Criteria** (what must be TRUE):
  1. User can press fn and record without sox or any Homebrew binary present on the machine
  2. User can select a specific microphone (including AirPods) from Settings and subsequent recordings use that device
  3. AirPods connected as input show a visible warning rather than silently producing empty transcriptions
  4. Recording overlay shows animated waveform bars that respond to voice amplitude in real time
  5. Recording overlay shows the name of the app that will receive the transcribed text
**Plans:** 3/3 plans complete

Plans:
- [x] 01-01-PLAN.md — Replace sox/rec with AVAudioEngine recording and WAV writer
- [x] 01-02-PLAN.md — Mic selector in Settings Audio tab + AirPods zero-signal detection
- [x] 01-03-PLAN.md — Waveform overlay, timer, app context display, and human verification

### Phase 2: Distribution
**Goal**: A signed, notarized DMG ships to paying customers with guided onboarding and license enforcement
**Depends on**: Phase 1
**Requirements**: DIST-01, DIST-02, DIST-03, DIST-04
**Success Criteria** (what must be TRUE):
  1. DMG passes Gatekeeper on a clean Mac without "unidentified developer" warning
  2. First launch walks a non-technical user through accessibility and microphone permission dialogs step by step
  3. App restarts itself automatically when the user toggles accessibility permission in System Settings
  4. App requires a valid LemonSqueezy license key after the trial period and refuses to transcribe without one
**Plans:** 1/3 plans executed

Plans:
- [x] 02-01-PLAN.md — Unify bundle ID, tighten entitlements, Developer ID signing + notarization pipeline
- [ ] 02-02-PLAN.md — First-launch onboarding wizard and accessibility auto-restart
- [ ] 02-03-PLAN.md — LemonSqueezy license enforcement with 14-day trial

### Phase 3: History + Editing
**Goal**: Users can review, search, and reuse past transcriptions, improve accuracy with custom vocabulary, control text with voice commands, and transcribe audio/video files
**Depends on**: Phase 1
**Requirements**: HIST-01, HIST-02, HIST-03, HIST-04
**Success Criteria** (what must be TRUE):
  1. User can open a History window (Cmd+H) listing past transcriptions, search by text, and re-inject any entry into the active app
  2. User can add domain-specific words in Settings that improve whisper transcription accuracy for those terms
  3. Speaking "scratch that" deletes the last injected text; "new paragraph" inserts a blank line; commands do not appear as literal text
  4. User can open an audio or video file (Cmd+O) and receive a transcription pasted into the active app
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Audio + Visual | 3/3 | Complete   | 2026-03-24 |
| 2. Distribution | 1/3 | In Progress|  |
| 3. History + Editing | 0/TBD | Not started | - |
