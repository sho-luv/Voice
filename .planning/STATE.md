---
gsd_state_version: 1.0
milestone: v3.2
milestone_name: milestone
status: Ready to execute
stopped_at: "Checkpoint: 02-distribution-02-PLAN.md Task 2 awaiting human verification"
last_updated: "2026-03-24T15:01:14.948Z"
progress:
  total_phases: 3
  completed_phases: 1
  total_plans: 6
  completed_plans: 5
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-24)

**Core value:** Local-only, instant dictation that works everywhere on macOS — press a key, speak, text appears. Privacy is non-negotiable.
**Current focus:** Phase 02 — distribution

## Current Position

Phase: 02 (distribution) — EXECUTING
Plan: 3 of 3

## Performance Metrics

**Velocity:**

- Total plans completed: 0
- Average duration: — min
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**

- Last 5 plans: —
- Trend: —

*Updated after each plan completion*
| Phase 01-audio-visual P01 | 18 | 2 tasks | 1 files |
| Phase 01-audio-visual P02 | 3 | 2 tasks | 2 files |
| Phase 02-distribution P01 | 12 | 2 tasks | 6 files |
| Phase 02-distribution P02 | 8 | 1 tasks | 1 files |

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Init: Replace sox with AVFoundation (eliminates Homebrew dep, unblocks waveform + mic selection)
- Init: Use JSON + Codable for history persistence (CoreData/SwiftData incompatible with swiftc-only build)
- Init: Commit after every discrete working unit (previous session lost all work via accidental git checkout)
- [Phase 01-audio-visual]: Use AVAudioConverter with hardware format tap for cross-hardware audio compatibility
- [Phase 01-audio-visual]: Expose currentAudioLevel Float RMS on AppDelegate for Plan 03 waveform overlay
- [Phase 01-audio-visual]: Use Unmanaged<CFString> with takeRetainedValue() for CoreAudio CFString properties — avoids unsafe pointer warnings
- [Phase 01-audio-visual]: Zero-signal detection: rms < 0.0001 after 8 buffers (~2s) triggers overlay warning, auto-dismisses after 3s
- [Phase 02-distribution]: Inside-out signing order (dylibs -> whisper-cli -> app) required for hardened runtime — --deep disabled in Developer ID path
- [Phase 02-distribution]: updateLaunchAgent changed from private to internal so AppDelegate migration code can call Settings.shared.updateLaunchAgent during first-launch upgrade
- [Phase 02-distribution]: OnboardingWindowController uses show/hide NSView pattern (not NSViewController stack) — simpler, follows D-01 decision
- [Phase 02-distribution]: AX polling timer dual-use: onboarding auto-advance + post-onboarding silent relaunch via NSWorkspace.openApplication

### Pending Todos

None yet.

### Blockers/Concerns

- Phase 1: CoreAudio mic selection uses low-level C API (kAudioOutputUnitProperty_CurrentDevice) — test on Apple Silicon before treating as done
- Phase 2: LemonSqueezy offline/grace-period behavior needs research before implementation
- Phase 2: Notarization entitlement review needed — three relaxed entitlements may conflict with hardened runtime tightening
- Phase 2: Bundle ID mismatch (com.faradaysoft.voice vs com.local.voice hardcoded) must be fixed before notarization

## Session Continuity

Last session: 2026-03-24T15:01:14.945Z
Stopped at: Checkpoint: 02-distribution-02-PLAN.md Task 2 awaiting human verification
Resume file: None
