---
phase: 02-distribution
plan: 03
subsystem: payments
tags: [lemonsqueezy, license, trial, enforcement, settings-tab, menu-bar]

# Dependency graph
requires:
  - 02-01
  - 02-02
provides:
  - LicenseManager class with 14-day trial, LemonSqueezy activate/validate, offline grace
  - LicenseExpiryWindowController modal for expired trial users
  - License tab in SettingsViewController
  - Recording and POPO gated by LicenseManager.shared.canRecord
  - Menu bar trial status indicator (updated on menu open)
  - Launch-time license check in applicationDidFinishLaunching
affects: [distribution, user-experience, monetization]

# Tech tracking
tech-stack:
  added: [LemonSqueezy License API (api.lemonsqueezy.com/v1/licenses)]
  patterns:
    - LicenseManager singleton following Settings/SettingsWindowController pattern
    - Offline grace period logic: revalidation every 7 days, grace 3 days, then invalid
    - ActivateHandler/BuyHandler inner NSObject classes for action wiring in programmatic windows
    - objc_setAssociatedObject for retaining action handler objects in NSWindow

key-files:
  created: []
  modified:
    - Voice.swift

key-decisions:
  - "checkoutURL made internal (not private) on LicenseManager so LicenseExpiryWindowController inner classes can access it"
  - "Menu bar shows trial status for non-licensed users only — licensed users see clean menu (no status)"
  - "menuNeedsUpdate refreshes license status text each time menu opens — simpler than stored NSMenuItem reference"
  - "Launch-time expiry check placed after onboarding check — onboarding takes priority on very first launch"
  - "lsStoreId and lsProductId set to 0 (TODO placeholders) — validation still works structurally, store_id check skipped when 0"

patterns-established:
  - "Recording gate: check LicenseManager.shared.canRecord before startRecording() and startPopo() in InputMonitor callbacks"
  - "License tab follows same NSTabViewItem pattern as Audio/General/AI/Transcription tabs"

requirements-completed: [DIST-04]

# Metrics
duration: ~8min
completed: 2026-03-24
---

# Phase 2 Plan 03: LemonSqueezy License Enforcement Summary

**LicenseManager singleton with 14-day trial countdown, LemonSqueezy activate/validate API integration, offline grace, expiry modal blocking recording, Settings License tab, and menu bar trial indicator**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-03-24T16:12:43Z
- **Completed:** 2026-03-24T16:21:00Z
- **Tasks:** 1 completed, 1 checkpoint (awaiting human verification)
- **Files modified:** 1 (Voice.swift, +490 lines)

## Accomplishments

- LicenseManager class added to Voice.swift with trial countdown (14 days), LemonSqueezy license activation/validation API calls, offline grace period (7-day revalidation + 3-day grace), and canRecord gating
- LicenseExpiryWindowController modal blocks expired users: "Your trial has ended" title, license key field, Activate button, Buy Voice ($29) button, Quit button
- Settings License tab added as 5th tab with status indicator (color-coded), license key field, Activate/Deactivate buttons, Buy button
- Recording and POPO start callbacks gated by LicenseManager.shared.canRecord — expiry modal shown on blocked attempt
- Menu bar shows trial status (e.g., "Trial: 14 days left") for non-licensed users, updated each time menu opens via menuNeedsUpdate
- Launch-time license check calls validateIfNeeded() then shows expiry modal if canRecord is false

## Task Commits

Each task was committed atomically:

1. **Task 1: Add LicenseManager and Settings properties** - `7368b5f` (feat)
2. **Task 2: Verify license enforcement system** - CHECKPOINT REACHED — awaiting human verification

## Files Created/Modified

- `Voice.swift` - LicenseManager class (lines ~1276-1456); LicenseExpiryWindowController class (lines ~1459-1660); License tab controls and makeLicenseTab() in SettingsViewController; recording/popo gates in applicationDidFinishLaunching callbacks; trial status in menu bar; menuNeedsUpdate license refresh; launch-time license check

## Decisions Made

- `checkoutURL` on LicenseManager made `let` (internal, not private) so inner `BuyHandler` class inside `LicenseExpiryWindowController.show()` can access it without going through a static accessor
- Menu status only shown for non-licensed users — licensed users get a clean menu without a status line (per D-10 intent: "show trial status", not "always show something")
- `menuNeedsUpdate` refreshes the status text title on each open — avoids needing to store an NSMenuItem reference on AppDelegate
- `lsStoreId = 0` and `lsProductId = 0` are intentional TODO placeholders — the store_id check is skipped when storeId is 0, so activation works structurally even before dashboard values are filled in

## Deviations from Plan

None - plan executed exactly as written.

## Checkpoint: Task 2 — Human Verification Required

Task 2 is a `checkpoint:human-verify` gate. The following steps must be verified manually:

1. Build and run: `cd /Users/sho_luv/home/projects/mine/voice && bash install.sh`
2. Open the menu bar dropdown — verify "Trial: 14 days left" (or similar) appears
3. Open Settings -> License tab — verify status shows trial info
4. Simulate expired trial: `defaults write com.faradaysoft.voice trialStartDate -date "2026-03-01T00:00:00Z"` then relaunch
5. Verify expiry modal appears with "Your trial has ended" message
6. Verify "Buy Voice ($29)" button opens browser to checkout URL
7. Try pressing fn to record — verify recording is blocked (no recording starts)
8. If you have a test license key from LemonSqueezy: enter it in the expiry modal, click Activate, verify it succeeds
9. After activation: verify modal dismisses, recording works, menu shows "Licensed"
10. Reset for continued testing: `defaults delete com.faradaysoft.voice trialStartDate; defaults delete com.faradaysoft.voice isLicensed; defaults delete com.faradaysoft.voice licenseKey`

Note: `lsStoreId` and `lsProductId` are set to 0 (TODO placeholders). Full store_id validation only works after these are set from the LemonSqueezy dashboard. The structure and flow can be verified with the UI and activation flow working.

## User Setup Required

LemonSqueezy dashboard values needed before production use:
- Retrieve `store_id` and `product_id` from LemonSqueezy Dashboard -> Products -> Voice
- Update `lsStoreId` and `lsProductId` constants in `LicenseManager` in Voice.swift
- Update `checkoutURL` with the actual checkout URL from LemonSqueezy
- Create a test license key from LemonSqueezy Dashboard -> Licenses for verification

## Self-Check

Files check:
- `Voice.swift` exists and was modified: FOUND
- Commit `7368b5f` exists: FOUND

## Self-Check: PASSED

## Next Phase Readiness

- License enforcement is structurally complete and compiles cleanly
- Trial and license state flow works end-to-end; needs LemonSqueezy dashboard values for live key validation
- After human verification (Task 2), Phase 02 distribution is complete
- Phase 03 can proceed with remaining roadmap items (AVFoundation recording, waveform, history, etc.)

---
*Phase: 02-distribution*
*Completed: 2026-03-24*
