# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-24)

**Core value:** Local-only, instant dictation that works everywhere on macOS — press a key, speak, text appears. Privacy is non-negotiable.
**Current focus:** Phase 1 — Audio + Visual

## Current Position

Phase: 1 of 3 (Audio + Visual)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-03-24 — Roadmap created

Progress: [░░░░░░░░░░] 0%

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

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Init: Replace sox with AVFoundation (eliminates Homebrew dep, unblocks waveform + mic selection)
- Init: Use JSON + Codable for history persistence (CoreData/SwiftData incompatible with swiftc-only build)
- Init: Commit after every discrete working unit (previous session lost all work via accidental git checkout)

### Pending Todos

None yet.

### Blockers/Concerns

- Phase 1: CoreAudio mic selection uses low-level C API (kAudioOutputUnitProperty_CurrentDevice) — test on Apple Silicon before treating as done
- Phase 2: LemonSqueezy offline/grace-period behavior needs research before implementation
- Phase 2: Notarization entitlement review needed — three relaxed entitlements may conflict with hardened runtime tightening
- Phase 2: Bundle ID mismatch (com.faradaysoft.voice vs com.local.voice hardcoded) must be fixed before notarization

## Session Continuity

Last session: 2026-03-24
Stopped at: Roadmap created — ready to plan Phase 1
Resume file: None
