---
phase: 02-distribution
plan: 01
subsystem: infra
tags: [codesign, notarization, entitlements, dmg, bundle-id, launchagent, whisper, developer-id]

# Dependency graph
requires: []
provides:
  - com.faradaysoft.voice bundle ID unified across Voice.swift and install.sh
  - LaunchAgent migration on first launch (unloads com.local.voice, creates com.faradaysoft.voice)
  - WhisperMinimal.entitlements for whisper-cli binary (minimal 1-entitlement set)
  - Voice.entitlements tightened to 4 entitlements (removed allow-dyld-environment-variables)
  - dmg-background.png (660x400 gradient with arrow, for custom DMG installer appearance)
  - create-dmg.sh with Developer ID inside-out signing + notarytool submit + stapler staple
  - install.sh with Developer ID > Voice Dev > ad-hoc signing priority + inside-out signing
affects: [02-02, 02-03, distribution, notarization]

# Tech tracking
tech-stack:
  added: [xcrun notarytool, xcrun stapler, create-dmg CLI (optional), WhisperMinimal.entitlements]
  patterns:
    - Inside-out signing order (dylibs -> whisper-cli -> app bundle) for hardened runtime compliance
    - Graceful fallback chain (Developer ID -> Voice Dev -> ad-hoc) in both scripts
    - Keychain profile "voice-notarize" for notarytool credentials (xcrun notarytool store-credentials)

key-files:
  created:
    - WhisperMinimal.entitlements
    - dmg-background.png
  modified:
    - Voice.swift
    - Voice.entitlements
    - install.sh
    - create-dmg.sh

key-decisions:
  - "Inside-out signing order (dylibs, then whisper-cli with WhisperMinimal, then app bundle) required for hardened runtime — --deep flag disabled in Developer ID path"
  - "LaunchAgent migration runs in applicationDidFinishLaunching before duplicate-instance check to ensure clean upgrade path"
  - "updateLaunchAgent changed from private to internal so AppDelegate migration code can call it"
  - "dmg-background.png existence check in create-dmg.sh before using --background flag — graceful fallback, not a hard error"
  - "WhisperMinimal.entitlements: only allow-unsigned-executable-memory (GGML runtime requirement); no disable-library-validation needed for whisper-cli"

patterns-established:
  - "Signing script pattern: check Developer ID first, then Voice Dev, then ad-hoc — never hard-fail on missing cert"
  - "Notarization gate: check for voice-notarize keychain profile before submitting — print setup instructions if missing"

requirements-completed: [DIST-01]

# Metrics
duration: 12min
completed: 2026-03-24
---

# Phase 2 Plan 01: Bundle ID Unification + Production Signing Summary

**Bundle ID unified to com.faradaysoft.voice with automatic LaunchAgent migration, tightened entitlements (4 total, removed dyld override), WhisperMinimal.entitlements for whisper-cli, and a complete Developer ID inside-out signing + notarization pipeline in create-dmg.sh**

## Performance

- **Duration:** 12 min
- **Started:** 2026-03-24T14:52:26Z
- **Completed:** 2026-03-24T14:55:18Z
- **Tasks:** 2
- **Files modified:** 6 (Voice.swift, Voice.entitlements, install.sh, create-dmg.sh, + 2 created)

## Accomplishments
- All com.local.voice references replaced with com.faradaysoft.voice in Voice.swift and install.sh; LaunchAgent migration code added in applicationDidFinishLaunching for seamless upgrades
- Voice.entitlements tightened from 5 to 4 entitlements (removed allow-dyld-environment-variables); WhisperMinimal.entitlements created with single entitlement for whisper-cli binary
- dmg-background.png generated (660x400 gradient PNG with arrow indicator per D-22); create-dmg.sh rewritten with Developer ID inside-out signing, notarytool submit+staple pipeline, graceful dmg-background fallback

## Task Commits

Each task was committed atomically:

1. **Task 1: Unify bundle ID and add LaunchAgent migration** - `7a8a9ac` (feat)
2. **Task 2: DMG background, tightened entitlements, signing/notarization scripts** - `99d5738` (feat)

## Files Created/Modified
- `Voice.swift` - com.faradaysoft.voice bundle ID throughout; updateLaunchAgent made internal; LaunchAgent migration block in applicationDidFinishLaunching; fallback exec path changed to /Applications/Voice.app
- `Voice.entitlements` - Removed allow-dyld-environment-variables (now 4 entitlements)
- `WhisperMinimal.entitlements` (new) - Single entitlement for whisper-cli: allow-unsigned-executable-memory
- `dmg-background.png` (new) - 660x400 RGBA PNG gradient with right-pointing arrow
- `create-dmg.sh` - Full rewrite: VERSION=3.2, Developer ID primary cert, inside-out signing, notarytool+staple, create-dmg with background check, hdiutil fallback
- `install.sh` - Updated signing: Developer ID > Voice Dev > ad-hoc priority, inside-out order, WhisperMinimal.entitlements for whisper-cli

## Decisions Made
- Changed `updateLaunchAgent` from `private` to `internal` (removed `private` keyword) so AppDelegate migration code can call `Settings.shared.updateLaunchAgent(enabled:)` during first-launch migration. This is an accessibility change not a visibility leak — the method is on Settings which is already a shared singleton.
- Inside-out signing order is required for hardened runtime: each binary must be individually signed before its parent bundle. Using `--deep` bypasses this order and causes notarization rejection.
- WhisperMinimal.entitlements has only `allow-unsigned-executable-memory` because GGML/whisper.cpp JIT-compiles on ARM — it doesn't need `disable-library-validation` since its dylibs are signed by the same Developer ID cert.
- `notarytool history` used as a probe to check if the "voice-notarize" keychain profile exists before submitting — avoids a hard failure if credentials aren't configured yet.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

Notarization requires one-time credential setup (when ready to distribute):
```bash
xcrun notarytool store-credentials voice-notarize \
  --apple-id YOUR_APPLE_ID \
  --team-id MWW7M2563A \
  --password APP_SPECIFIC_PASSWORD
```

After setup, re-run `./create-dmg.sh` to get a notarized+stapled DMG.

## Next Phase Readiness
- Bundle ID is now consistent — notarization will not fail due to ID mismatch
- Signing pipeline is complete; only remaining gate is actual Developer ID certificate presence + notarization credentials
- Ready for Plan 02 (LemonSqueezy license validation) and Plan 03 (first-launch onboarding)

---
*Phase: 02-distribution*
*Completed: 2026-03-24*
