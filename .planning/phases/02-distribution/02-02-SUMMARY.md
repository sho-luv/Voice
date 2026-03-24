---
phase: 02-distribution
plan: 02
subsystem: onboarding
tags: [onboarding, accessibility, permissions, wizard, auto-restart, av-foundation]

# Dependency graph
requires:
  - 02-01
provides:
  - OnboardingWindowController class with 4-step wizard in Voice.swift
  - onboardingComplete UserDefaults flag in Settings
  - startAccessibilityPolling() + relaunchSilently() for post-onboarding AX toggling
  - First-launch onboarding gate in applicationDidFinishLaunching
affects: [02-03, distribution, user-experience]

# Tech tracking
tech-stack:
  added: [AXIsProcessTrustedWithOptions (system prompt trigger), AVCaptureDevice.requestAccess, NSWorkspace.openApplication (silent relaunch)]
  patterns:
    - OnboardingWindowController singleton following SettingsWindowController pattern
    - Show/hide NSView steps in single NSWindow (no NSViewController stack per D-01)
    - 2-second Timer polling AXIsProcessTrusted() for both onboarding auto-advance and post-onboarding auto-restart
    - relaunchSilently() opens new instance via NSWorkspace then terminates after 0.5s delay

key-files:
  created: []
  modified:
    - Voice.swift

key-decisions:
  - "OnboardingWindowController uses show/hide NSView pattern (not NSViewController stack) — simpler, follows D-01 decision for 480x360 single window"
  - "Accessibility step triggers AXIsProcessTrustedWithOptions with prompt on view creation (not button click) — reduces friction"
  - "Test step polls delegate.lastTranscription (0.5s intervals, 10s max) rather than hooking transcription pipeline — zero coupling"
  - "onboardingComplete NOT added to defaults.register() — bool(forKey:) default false is correct first-launch behavior"

patterns-established:
  - "Step-based wizard with show/hide NSView pattern for lightweight multi-step UI without NSViewController"
  - "AX polling timer dual-use: onboarding auto-advance + post-onboarding silent relaunch"

requirements-completed: [DIST-02, DIST-03]

# Metrics
duration: ~8min
completed: 2026-03-24
---

# Phase 2 Plan 02: Onboarding Wizard + Accessibility Auto-Restart Summary

**4-step onboarding wizard (Welcome, Accessibility, Microphone, Test) with AX permission polling, auto-advance, and silent app relaunch when accessibility permission is toggled post-onboarding**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-03-24T14:57:00Z
- **Completed:** 2026-03-24T15:00:12Z
- **Tasks:** 1 completed, 1 checkpoint (awaiting human verification)
- **Files modified:** 1 (Voice.swift, +503 lines)

## Accomplishments

- OnboardingWindowController class added to Voice.swift (lines ~1252-1760) with 4-step wizard: Welcome, Accessibility, Microphone, Test Recording
- Settings.onboardingComplete property added (no default registration — bool(forKey:) returns false, correct for first launch)
- Accessibility step calls AXIsProcessTrustedWithOptions with prompt on display, then polls every 2s; auto-advances and enables Next when granted
- Microphone step calls AVCaptureDevice.requestAccess and auto-advances on grant; shows appropriate UI for denied/not-determined/authorized states
- Test step records 3 seconds via AppDelegate.startRecording/stopRecording, polls lastTranscription, shows result with success/failure feedback
- startAccessibilityPolling() added to AppDelegate; polls every 2s post-launch; triggers relaunchSilently() when AX state changes
- applicationDidFinishLaunching wired: shows onboarding if !onboardingComplete, calls startAccessibilityPolling(), skips AX notification during onboarding

## Task Commits

Each task was committed atomically:

1. **Task 1: Add Settings properties and OnboardingWindowController** - `e47cd97` (feat)
2. **Task 2: Verify onboarding wizard and auto-restart** - CHECKPOINT REACHED — awaiting human verification

## Files Created/Modified

- `Voice.swift` - OnboardingWindowController class (4-step wizard, 2s AX polling, mic permission, test recording flow); Settings.onboardingComplete property; startAccessibilityPolling() and relaunchSilently() on AppDelegate; applicationDidFinishLaunching wired for onboarding + AX polling

## Decisions Made

- Show/hide NSView steps in a single NSWindow (per D-01) — no NSViewController stack needed; simpler code that follows the same SettingsWindowController singleton pattern
- AXIsProcessTrustedWithOptions with prompt triggered on Accessibility step creation (not on button click) — more natural UX, matches what other Mac apps do
- Test step polls delegate.lastTranscription at 0.5s intervals (max 10s) rather than hooking the transcription pipeline directly — zero coupling to AppDelegate internals

## Deviations from Plan

None - plan executed exactly as written.

## Checkpoint: Task 2 — Human Verification Required

Task 2 is a `checkpoint:human-verify` gate. The following steps must be verified manually:

1. Reset onboarding flag: `defaults delete com.faradaysoft.voice onboardingComplete 2>/dev/null`
2. Build and run: `cd /Users/sho_luv/home/projects/mine/voice && bash install.sh`
3. Verify onboarding wizard appears with "Welcome to Voice" title
4. Verify 4 progress dots at bottom
5. Click "Get Started" — verify Accessibility step appears
6. Verify "Next" button disabled until accessibility granted
7. Click "Open System Settings" — verify it opens to correct pane
8. Grant accessibility permission — verify step auto-advances
9. On Microphone step — verify permission prompt or status display
10. On Test step — click "Start Test", speak for 3 seconds, verify transcription
11. Click "Finish" — verify wizard closes
12. Quit and relaunch — verify onboarding does NOT appear again
13. Test auto-restart: revoke accessibility in System Settings, then re-grant — verify app restarts silently

## Self-Check

Files check:
- `Voice.swift` exists and was modified: FOUND
- Commit `e47cd97` exists: FOUND

## Self-Check: PASSED
