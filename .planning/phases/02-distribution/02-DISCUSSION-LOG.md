# Phase 2: Distribution - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-03-24
**Phase:** 02-distribution
**Areas discussed:** Onboarding flow, License enforcement, Signing & notarization, Auto-restart behavior, Trial countdown UX, DMG installer experience

---

## Onboarding Flow

| Option | Description | Selected |
|--------|-------------|----------|
| Step-by-step wizard | Dedicated window walks through Welcome, Accessibility, Microphone, Test recording | ✓ |
| Inline prompts | No dedicated window, system dialogs appear naturally with overlay hints | |
| You decide | Claude picks best approach | |

**User's choice:** Step-by-step wizard
**Notes:** None

| Option | Description | Selected |
|--------|-------------|----------|
| Centered modal window | Fixed-size window centered on screen, one step per screen with progress indicator | ✓ |
| Sheet attached to menu | Small panel dropping from menu bar icon | |
| You decide | Claude picks | |

**User's choice:** Centered modal window

| Option | Description | Selected |
|--------|-------------|----------|
| Block with explanation | Stay on step, explain why required, offer System Settings button | ✓ |
| Allow skip with warning | Let them continue with persistent warning | |
| You decide | Claude picks | |

**User's choice:** Block with explanation

| Option | Description | Selected |
|--------|-------------|----------|
| Yes — quick test | Final step records 3 seconds, shows transcription | ✓ |
| No — just permissions | End after permissions granted | |
| You decide | Claude picks | |

**User's choice:** Yes — quick test

---

## License Enforcement

| Option | Description | Selected |
|--------|-------------|----------|
| 7 days | Short trial, creates urgency | |
| 14 days | Balanced, enough to form habit | ✓ |
| 30 days | Generous, may lower conversion | |
| You decide | Claude picks | |

**User's choice:** 14 days

| Option | Description | Selected |
|--------|-------------|----------|
| Full block — no transcription | App launches but refuses to record/transcribe | ✓ |
| Nag + time limit | Still works but limited to 30s, nag screen | |
| You decide | Claude picks | |

**User's choice:** Full block

| Option | Description | Selected |
|--------|-------------|----------|
| Settings tab | New License tab in Settings window | ✓ |
| Dedicated activation window | Separate modal window | |
| You decide | Claude picks | |

**User's choice:** Settings tab

| Option | Description | Selected |
|--------|-------------|----------|
| Cache validation — 3-day grace | Validate online + periodic re-check, 3-day offline grace | ✓ |
| Validate once, trust forever | Single online validation, never re-check | |
| You decide | Claude picks | |

**User's choice:** Cache validation — 3-day grace

---

## Signing & Notarization

| Option | Description | Selected |
|--------|-------------|----------|
| Keep all 3 — justify to Apple | Hardened runtime + all 3 relaxed entitlements | |
| Minimize — test which are needed | Research and test each entitlement, only keep required | ✓ |
| You decide | Claude researches and decides | |

**User's choice:** Minimize — test which are needed

| Option | Description | Selected |
|--------|-------------|----------|
| Unify to com.faradaysoft.voice | Use real bundle ID everywhere, migrate LaunchAgent | ✓ |
| You decide | Claude handles | |

**User's choice:** Unify to com.faradaysoft.voice

| Option | Description | Selected |
|--------|-------------|----------|
| Yes — Developer ID default | Use Developer ID cert as primary, fall back to ad-hoc | ✓ |
| Keep ad-hoc for dev, separate release script | Leave install.sh as-is, create release.sh | |
| You decide | Claude picks | |

**User's choice:** Developer ID default

---

## Auto-Restart Behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Silent relaunch | Quit and immediately relaunch, no user action | ✓ |
| Notification + manual relaunch | Show notification, user relaunches manually | |
| You decide | Claude picks | |

**User's choice:** Silent relaunch

| Option | Description | Selected |
|--------|-------------|----------|
| Poll AXIsProcessTrusted | Timer checks every 2-3 seconds | ✓ |
| DistributedNotificationCenter | Listen for system notification | |
| You decide | Claude picks | |

**User's choice:** Poll AXIsProcessTrusted

---

## Trial Countdown UX

| Option | Description | Selected |
|--------|-------------|----------|
| Subtle badge in menu + settings | Small "Trial: X days" in dropdown, shown in License tab | ✓ |
| Daily notification + settings | Push notification once per day starting day 10 | |
| You decide | Claude picks | |

**User's choice:** Subtle badge in menu + settings

| Option | Description | Selected |
|--------|-------------|----------|
| Modal on launch | Modal window on launch: "Your trial has ended" with key field + purchase button | ✓ |
| License prompt on hotkey press | Overlay on fn press instead of recording | |
| You decide | Claude picks | |

**User's choice:** Modal on launch

| Option | Description | Selected |
|--------|-------------|----------|
| Yes — direct purchase link | "Buy Voice ($29)" opens LemonSqueezy checkout in browser | ✓ |
| No — just license key field | Only show key entry field | |
| Both | Key field + "Don't have a key? Buy Voice" link | |

**User's choice:** Yes — direct purchase link

| Option | Description | Selected |
|--------|-------------|----------|
| First launch | 14-day countdown starts on first app launch | ✓ |
| First recording | Trial starts on first successful transcription | |
| You decide | Claude picks | |

**User's choice:** First launch

---

## DMG Installer Experience

| Option | Description | Selected |
|--------|-------------|----------|
| Yes — branded background | Custom DMG background with logo and drag-to-Applications arrow | ✓ |
| Plain DMG | Default macOS DMG, no custom background | |
| You decide | Claude picks | |

**User's choice:** Branded background

| Option | Description | Selected |
|--------|-------------|----------|
| Just the app | Voice.app + /Applications symlink only | ✓ |
| Include quick-start PDF | Add Quick Start guide alongside app | |
| You decide | Claude picks | |

**User's choice:** Just the app

---

## Claude's Discretion

- Onboarding wizard visual design (colors, typography, spacing)
- Exact DMG background image design/layout
- LemonSqueezy API integration details
- Timer interval for AXIsProcessTrusted polling (2-3s range)
- Animation/transition between onboarding steps
- License key storage format
- LaunchAgent migration logic details

## Deferred Ideas

None — discussion stayed within phase scope
