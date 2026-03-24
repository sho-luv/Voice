# Phase 2: Distribution - Context

**Gathered:** 2026-03-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Sign the app with Developer ID, notarize the DMG, guide first-time users through accessibility and microphone permissions via an onboarding wizard, auto-restart when accessibility permission is toggled, and enforce LemonSqueezy license keys after a 14-day trial. The app becomes sellable to paying customers.

</domain>

<decisions>
## Implementation Decisions

### Onboarding Flow
- **D-01:** Step-by-step wizard in a centered modal window (~480x360), one step per screen with progress indicator
- **D-02:** Steps: 1) Welcome, 2) Accessibility permission, 3) Microphone permission, 4) Quick test recording
- **D-03:** Accessibility step blocks advancement — explain why it's required ("Voice can't detect your hotkey without this"), offer button to open System Settings directly
- **D-04:** Final step records ~3 seconds of speech and shows transcription to confirm end-to-end functionality
- **D-05:** Onboarding runs on first launch only (detected via UserDefaults flag)

### License Enforcement
- **D-06:** 14-day free trial starting from first app launch. Store install date in UserDefaults.
- **D-07:** After trial expires: full block — no recording/transcription. App launches but refuses to record.
- **D-08:** New "License" tab in Settings window for license key entry. Text field + "Activate" button + status indicator (Trial: X days left / Licensed).
- **D-09:** LemonSqueezy API validation: validate online on activation + re-validate every 7 days. Cache result locally. If offline for 3+ days, show warning but keep working.
- **D-10:** Subtle "Trial: X days" text in menu bar dropdown. No popups, no daily notifications. Non-intrusive.

### Trial Expiry UX
- **D-11:** On launch when trial expired: modal window with "Your trial has ended" message
- **D-12:** Modal includes license key field for existing buyers
- **D-13:** "Buy Voice ($29)" button opens LemonSqueezy checkout URL in default browser for direct purchase
- **D-14:** After entering valid key, modal dismisses and app functions normally

### Signing & Notarization
- **D-15:** Unify bundle ID to `com.faradaysoft.voice` everywhere — LaunchAgent, saved state paths, code fallbacks. Migrate existing `com.local.voice` LaunchAgent on upgrade.
- **D-16:** Minimize entitlements — research and test which of the 3 relaxed entitlements (disable-library-validation, allow-unsigned-executable-memory, allow-dyld-environment-variables) whisper-cli actually needs. Sign whisper-cli separately. Only keep strictly required entitlements.
- **D-17:** Update install.sh and create-dmg.sh to use Developer ID Application certificate (Team ID: MWW7M2563A) as primary signing identity. Fall back to ad-hoc only if cert not found.
- **D-18:** create-dmg.sh includes notarization step (xcrun notarytool submit + staple)

### Auto-Restart
- **D-19:** Silent relaunch when accessibility permission is toggled. No user action needed.
- **D-20:** Detection via polling AXIsProcessTrusted() every 2-3 seconds with a Timer
- **D-21:** When permission changes: quit current instance, immediately launch new instance via NSWorkspace or Process before exiting

### DMG Installer
- **D-22:** Custom DMG background image with Voice logo and drag-to-Applications arrow visual
- **D-23:** DMG contains only Voice.app + /Applications symlink — no README, no extras. Onboarding wizard handles guidance.

### Claude's Discretion
- Onboarding wizard visual design (colors, typography, spacing)
- Exact DMG background image design/layout
- LemonSqueezy API integration details (endpoint URLs, request format)
- Timer interval for AXIsProcessTrusted polling (2-3 second range)
- Animation/transition between onboarding steps
- License key storage format in UserDefaults
- LaunchAgent migration logic details

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Signing & Entitlements
- `Voice.entitlements` — Current entitlement set (3 relaxed entitlements to audit)
- `Info.plist` — Bundle metadata, bundle ID (com.faradaysoft.voice), version 3.2
- `install.sh` — Current build/sign/install script (lines 119-123: signing logic)
- `create-dmg.sh` — Current DMG creation script (lines 71-98: signing + notarization placeholder)

### Bundle ID References (must unify)
- `Voice.swift` line 195 — LaunchAgent plist path uses com.local.voice
- `Voice.swift` line 205 — LaunchAgent label uses com.local.voice
- `Voice.swift` line 2050 — bundleID fallback uses com.local.voice
- `Voice.swift` line 2871 — savedStatePath uses com.local.voice

### Accessibility Permission
- `Voice.swift` lines 400-412 — Current event tap creation and permission check
- `Voice.swift` line 2135 — Current accessibility failure notification

### Settings UI
- `Voice.swift` lines 1050-1656 — SettingsWindowController (add License tab here)
- `Voice.swift` lines 39-187 — Settings singleton (add trial/license properties)

### State & Concerns
- `.planning/STATE.md` — Blockers: LemonSqueezy offline behavior, entitlement conflicts, bundle ID mismatch
- `.planning/codebase/CONCERNS.md` — Known issues including hardcoded paths

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `Settings` singleton (lines 39-187): Established pattern for adding UserDefaults-backed properties — add trialStartDate, licenseKey, isLicensed
- `SettingsWindowController` (lines 1050-1656): Tabbed NSWindow with existing tab pattern — add License tab following same structure
- `AppDelegate.applicationDidFinishLaunching` (line 1693): Launch sequence — insert onboarding check here
- Notification system via UNUserNotificationCenter: Already used for accessibility warnings

### Established Patterns
- `UserDefaults` for all settings persistence — use for trial/license state too
- `URLSession.shared.dataTask` with completion handlers — use for LemonSqueezy API calls
- `DispatchQueue.main.async` for UI updates from background
- `Process()` for launching external tools — use for self-relaunch
- NSWindow construction in code (no XIB/storyboard) — use for onboarding wizard window

### Integration Points
- `applicationDidFinishLaunching`: Check onboarding complete flag, check trial status, show appropriate UI
- `InputMonitor` callbacks: Check license validity before allowing recording
- Menu bar dropdown: Add "Trial: X days" status line
- `create-dmg.sh`: Add notarization commands after existing DMG creation
- LaunchAgent plist: Update bundle ID from com.local.voice to com.faradaysoft.voice

</code_context>

<specifics>
## Specific Ideas

- Onboarding wizard should feel like a native macOS setup assistant — centered modal, clean progress, one action per step
- Trial should be non-intrusive: subtle menu badge only, no popups until expiry
- Expired trial modal should make purchasing frictionless — direct link to LemonSqueezy checkout
- Auto-restart should be invisible to the user — they toggle the permission and the app just works

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 02-distribution*
*Context gathered: 2026-03-24*
