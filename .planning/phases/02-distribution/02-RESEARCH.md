# Phase 2: Distribution - Research

**Researched:** 2026-03-24
**Domain:** macOS code signing, notarization, license enforcement, onboarding UX
**Confidence:** HIGH (all major claims verified via official docs or direct source inspection)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Onboarding Flow**
- D-01: Step-by-step wizard in a centered modal window (~480x360), one step per screen with progress indicator
- D-02: Steps: 1) Welcome, 2) Accessibility permission, 3) Microphone permission, 4) Quick test recording
- D-03: Accessibility step blocks advancement — explain why required, offer button to open System Settings directly
- D-04: Final step records ~3 seconds of speech and shows transcription to confirm end-to-end functionality
- D-05: Onboarding runs on first launch only (detected via UserDefaults flag)

**License Enforcement**
- D-06: 14-day free trial starting from first app launch. Store install date in UserDefaults.
- D-07: After trial expires: full block — no recording/transcription. App launches but refuses to record.
- D-08: New "License" tab in Settings window for license key entry. Text field + "Activate" button + status indicator.
- D-09: LemonSqueezy API validation: validate online on activation + re-validate every 7 days. Cache result locally. If offline for 3+ days, show warning but keep working.
- D-10: Subtle "Trial: X days" text in menu bar dropdown. No popups, no daily notifications.

**Trial Expiry UX**
- D-11: On launch when trial expired: modal window with "Your trial has ended" message
- D-12: Modal includes license key field for existing buyers
- D-13: "Buy Voice ($29)" button opens LemonSqueezy checkout URL in default browser
- D-14: After entering valid key, modal dismisses and app functions normally

**Signing & Notarization**
- D-15: Unify bundle ID to `com.faradaysoft.voice` everywhere — LaunchAgent, saved state paths, code fallbacks. Migrate existing `com.local.voice` LaunchAgent on upgrade.
- D-16: Minimize entitlements — research and test which of the 3 relaxed entitlements whisper-cli actually needs. Sign whisper-cli separately. Only keep strictly required.
- D-17: Update install.sh and create-dmg.sh to use Developer ID Application (Team ID: MWW7M2563A) as primary. Fall back to ad-hoc only if cert not found.
- D-18: create-dmg.sh includes notarization step (xcrun notarytool submit + staple)

**Auto-Restart**
- D-19: Silent relaunch when accessibility permission is toggled. No user action needed.
- D-20: Detection via polling AXIsProcessTrusted() every 2-3 seconds with a Timer
- D-21: When permission changes: quit current instance, immediately launch new instance via NSWorkspace or Process before exiting

**DMG Installer**
- D-22: Custom DMG background image with Voice logo and drag-to-Applications arrow visual
- D-23: DMG contains only Voice.app + /Applications symlink — no README, no extras

### Claude's Discretion
- Onboarding wizard visual design (colors, typography, spacing)
- Exact DMG background image design/layout
- LemonSqueezy API integration details (endpoint URLs, request format)
- Timer interval for AXIsProcessTrusted polling (2-3 second range)
- Animation/transition between onboarding steps
- License key storage format in UserDefaults
- LaunchAgent migration logic details

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DIST-01 | App is signed with Developer ID and DMG is notarized | Signing order, notarytool workflow, entitlement audit findings |
| DIST-02 | First launch guides user through accessibility and microphone permissions | NSWindow wizard pattern, AVCaptureDevice.requestAccess, AXIsProcessTrustedWithOptions |
| DIST-03 | App auto-restarts when accessibility permission is toggled | AXIsProcessTrusted polling + NSWorkspace.openApplication relaunch pattern |
| DIST-04 | App validates LemonSqueezy license key (gate after trial period) | LemonSqueezy License API endpoints, activate/validate flow, offline caching |
</phase_requirements>

---

## Summary

Phase 2 spans four distinct technical domains: (1) Apple Developer ID signing and notarization, (2) a native macOS onboarding wizard, (3) accessibility permission polling with silent app relaunch, and (4) LemonSqueezy license activation and enforcement. All four are achievable in pure Swift + shell script within the project's no-Xcode constraint.

The signing and notarization work is well-understood and mechanically straightforward once the signing order is correct: sign inside-out (dylibs first, then whisper-cli, then the app bundle), use `--timestamp --options runtime` for Developer ID signing, then submit the DMG to `xcrun notarytool submit --wait` and staple. The three relaxed entitlements in the current `Voice.entitlements` require careful auditing: `allow-unsigned-executable-memory` and `allow-dyld-environment-variables` are the candidates to drop; `disable-library-validation` is the one most likely required for a bundled whisper-cli binary.

LemonSqueezy provides a lightweight License API with no authentication header required — just POST form fields to `https://api.lemonsqueezy.com/v1/licenses/activate` and `/validate`. The flow is: activate on first use (returns `instance.id`), store `instance.id` in UserDefaults, validate every 7 days with `license_key + instance_id`. Offline caching via UserDefaults + a "last validated" timestamp covers the 3-day grace period the user specified.

**Primary recommendation:** Implement in wave order — signing/notarization first (unblocks real-device testing), then onboarding wizard, then accessibility polling/relaunch, then license enforcement. Each wave is independently testable.

---

## Standard Stack

### Core
| Library / API | Version / Source | Purpose | Why Standard |
|---------------|-----------------|---------|--------------|
| `codesign` CLI | macOS Xcode CLT | Sign all Mach-O binaries and app bundle | Only official Apple tool for Developer ID signing |
| `xcrun notarytool` | macOS Xcode CLT (Xcode 13+) | Submit and poll notarization | Replaced `altool`; required for all current macOS notarization |
| `xcrun stapler` | macOS Xcode CLT | Staple notarization ticket to DMG | Required for Gatekeeper to work offline |
| `create-dmg` | `brew install create-dmg` | DMG with background image + icon layout | Only maintained shell-script tool for custom DMG layouts without Xcode |
| LemonSqueezy License API | `https://api.lemonsqueezy.com/v1/licenses/*` | License activation and validation | Project is already on LemonSqueezy; no SDK needed — plain HTTP |
| `AXIsProcessTrusted()` | ApplicationServices (already imported) | Poll accessibility permission state | The only macOS API to check Accessibility TCC status at runtime |
| `AVCaptureDevice.requestAccess(for: .audio)` | AVFoundation (already imported) | Request microphone permission | Standard AVFoundation API; works from any thread |
| `NSWorkspace.shared.openApplication(at:configuration:)` | AppKit | Launch new app instance for relaunch | Modern replacement for deprecated `launchApplication` |

### Supporting
| Library | Purpose | When to Use |
|---------|---------|-------------|
| `UserDefaults.standard` | Store trial start date, license key, instance ID, last validation timestamp | All license/trial state — consistent with rest of app |
| `URLSession.shared.dataTask` | LemonSqueezy API calls | Consistent with existing AI client pattern in Voice.swift |
| `Timer.scheduledTimer` | AXIsProcessTrusted polling loop | Same pattern used for overlay pulse animation |
| `NSRunningApplication.runningApplications(withBundleIdentifier:)` | Detect duplicate instances after relaunch | Already used in `applicationDidFinishLaunching` |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `create-dmg` (brew) | Raw `hdiutil` + AppleScript | hdiutil can't set icon positions without AppleScript; create-dmg wraps this cleanly |
| `xcrun notarytool --wait` | Poll notarytool status separately | `--wait` blocks until done; simpler for a build script with no CI timeout concern |
| `Timer` polling for AXIsProcessTrusted | NSDistributedNotificationCenter "com.apple.accessibility.api" | Notification approach is undocumented/private; Timer is simple and reliable |

**Installation (create-dmg):**
```bash
brew install create-dmg
```

**Version verification:**
```bash
# notarytool is bundled with Xcode CLT — no version to pin separately
xcrun notarytool --version
create-dmg --version
```

---

## Architecture Patterns

### Signing Order (Inside-Out)

Apple requires signing from innermost to outermost. For Voice.app:

```
1. Sign each .dylib in Contents/Frameworks/
2. Sign whisper-cli in Contents/Resources/
3. Sign the app bundle (Voice.app) — this seals the entire bundle
4. Create DMG
5. Sign the DMG
6. Submit DMG to notarytool
7. Staple ticket to DMG
```

**Critical:** Do NOT use `codesign --deep` for the final distribution build. It signs in the wrong order and produces warnings during notarization. Sign each component explicitly.

### Pattern 1: Developer ID Signing with Entitlements (Inside-Out)

**What:** Each Mach-O binary gets signed separately with `--timestamp --options runtime`. Entitlements go on the main executable only (or on whisper-cli if it specifically needs them).

**When to use:** Any binary that runs as a process — whisper-cli is a subprocess, so it needs its own signature.

```bash
# Source: Apple Developer Documentation - Customizing the notarization workflow
CERT="Developer ID Application: Faraday Soft (MWW7M2563A)"

# Step 1: Sign dylibs (no entitlements needed for dylibs)
for dylib in Voice.app/Contents/Frameworks/*.dylib; do
    codesign --force --sign "$CERT" --timestamp --options runtime "$dylib"
done

# Step 2: Sign whisper-cli (minimal entitlements — test which are required)
codesign --force --sign "$CERT" --timestamp --options runtime \
    --entitlements WhisperMinimal.entitlements \
    Voice.app/Contents/Resources/whisper-cli

# Step 3: Sign the app bundle with full entitlements
codesign --force --sign "$CERT" --timestamp --options runtime \
    --entitlements Voice.entitlements \
    Voice.app

# Verify
codesign --verify --deep --strict --verbose=2 Voice.app
spctl --assess --type execute -vvvv Voice.app
```

### Pattern 2: Notarization Workflow

```bash
# Source: Apple Developer Documentation - Customizing the notarization workflow

# Store credentials once (use app-specific password, not Apple ID password)
xcrun notarytool store-credentials "voice-notarize" \
    --apple-id "YOUR_APPLE_ID" \
    --team-id "MWW7M2563A" \
    --password "APP_SPECIFIC_PASSWORD"

# Submit and wait
xcrun notarytool submit Voice-3.2.dmg \
    --keychain-profile "voice-notarize" \
    --wait

# Staple the ticket
xcrun stapler staple Voice-3.2.dmg

# Verify Gatekeeper accepts it
spctl --assess --type open --context context:primary-signature -v Voice-3.2.dmg
```

### Pattern 3: create-dmg for Custom Background

```bash
# Source: https://github.com/create-dmg/create-dmg
create-dmg \
    --volname "Voice" \
    --background "dmg-background.png" \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "Voice.app" 180 195 \
    --app-drop-link 480 195 \
    "Voice-3.2.dmg" \
    ".dmg-staging/"
```

### Pattern 4: LemonSqueezy License Flow

**What:** Activate on first key entry (creates instance), validate periodically with cached instance_id.

**Step 1 — Activate (first time only):**
```swift
// Source: https://docs.lemonsqueezy.com/api/license-api/activate-license-key
// POST https://api.lemonsqueezy.com/v1/licenses/activate
// Content-Type: application/x-www-form-urlencoded
// Body: license_key=<key>&instance_name=<machineName>
//
// Response fields used:
//   activated: Bool
//   instance.id: String  <- store this in UserDefaults
//   license_key.status: String  <- verify "active"
//   meta.store_id / product_id  <- verify match your hardcoded IDs
```

**Step 2 — Validate (every 7 days or on launch):**
```swift
// Source: https://docs.lemonsqueezy.com/api/license-api/validate-license-key
// POST https://api.lemonsqueezy.com/v1/licenses/validate
// Body: license_key=<key>&instance_id=<stored_instance_id>
//
// Response fields used:
//   valid: Bool
//   license_key.status: String
```

**Offline grace logic:**
```swift
// Pseudocode — fits existing URLSession pattern in Voice.swift
func checkLicense(completion: (LicenseState) -> Void) {
    guard let key = Settings.shared.licenseKey, !key.isEmpty else {
        completion(trialState())  // no key — fall through to trial logic
        return
    }
    let lastCheck = Settings.shared.lastLicenseValidation  // Date in UserDefaults
    let daysSince = Date().timeIntervalSince(lastCheck) / 86400
    if daysSince < 7 {
        completion(.licensed)  // cached result still valid
        return
    }
    validateOnline(key: key, instanceId: Settings.shared.licenseInstanceId) { result in
        if result.valid {
            Settings.shared.lastLicenseValidation = Date()
            completion(.licensed)
        } else if daysSince < 3 {
            completion(.offlineGrace)  // show warning, keep working
        } else {
            completion(.expired)
        }
    }
}
```

### Pattern 5: AXIsProcessTrusted Polling + Silent Relaunch

**What:** Poll every 2 seconds. When permission appears, relaunch silently.

```swift
// Source: Apple Developer Documentation - AXIsProcessTrusted
private var wasAccessibilityGranted = false
private var accessibilityPollTimer: Timer?

func startAccessibilityPolling() {
    wasAccessibilityGranted = AXIsProcessTrusted()
    accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
        let isNowGranted = AXIsProcessTrusted()
        guard let self = self, isNowGranted != self.wasAccessibilityGranted else { return }
        self.wasAccessibilityGranted = isNowGranted
        if isNowGranted {
            self.relaunchSilently()
        }
    }
}

func relaunchSilently() {
    guard let bundleURL = Bundle.main.bundleURL else { return }
    // Launch new instance before quitting
    NSWorkspace.shared.openApplication(
        at: bundleURL,
        configuration: NSWorkspace.OpenConfiguration()
    ) { _, _ in }
    // Brief delay so new instance can start before we exit
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        NSApp.terminate(nil)
    }
}
```

**Integration point:** Start polling in `applicationDidFinishLaunching` immediately after `inputMonitor.start()` fails OR after onboarding navigates to the Accessibility step.

### Pattern 6: Onboarding Wizard Window

**What:** Modal NSWindow with step pages shown/hidden. No NSViewController stack — just show/hide page views.

```swift
// Source: existing SettingsWindowController pattern in Voice.swift (lines 1247-1276)
class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private var currentStep = 0

    func show() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled],  // no close button — user must complete or skip
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to Voice"
        w.center()
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        // Load step 1 view
        showStep(0)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
```

### Pattern 7: Bundle ID Unification + LaunchAgent Migration

**What:** Replace all `com.local.voice` references in Voice.swift and install.sh. Add one-time migration that removes the old plist and registers the new one.

**Files to update:**
- `Voice.swift` line 195: `plistPath` — change `com.local.voice` to `com.faradaysoft.voice`
- `Voice.swift` line 205: plist `<Label>` string — change to `com.faradaysoft.voice`
- `Voice.swift` line 2050: `bundleID` fallback — change to `com.faradaysoft.voice`
- `Voice.swift` line 2871: `savedStatePath` — change to `com.faradaysoft.voice`
- `install.sh` lines 142-159: LaunchAgent plist creation — change both label and plist filename

**Migration logic (run once on launch):**
```swift
// In applicationDidFinishLaunching, before duplicate-instance check
let oldPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.local.voice.plist"
let newPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.faradaysoft.voice.plist"
if FileManager.default.fileExists(atPath: oldPlist) && !FileManager.default.fileExists(atPath: newPlist) {
    // Unload old agent, write new plist, load new agent
    let unload = Process(); unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    unload.arguments = ["unload", oldPlist]; try? unload.run(); unload.waitUntilExit()
    try? FileManager.default.removeItem(atPath: oldPlist)
    Settings.shared.updateLaunchAgent(enabled: Settings.shared.autoStartOnLogin)
}
```

### Anti-Patterns to Avoid
- **`codesign --deep` on the bundle:** Signs in wrong order; use explicit per-binary signing instead
- **Storing license key in plain UserDefaults without verification:** Always verify `meta.store_id` and `meta.product_id` match your hardcoded values on activate
- **Blocking main thread during LemonSqueezy API call:** Use `URLSession.dataTask` (completion handler) or `async/await` — never call synchronously
- **Polling AXIsProcessTrusted on a background thread:** CGEvent APIs are main-thread only; poll on main via `Timer.scheduledTimer`
- **Hardcoded notarization credentials in script:** Use `xcrun notarytool store-credentials` to store in Keychain; reference by profile name in scripts
- **Using `--deep` sign on DMG:** DMGs must be signed after creation with a separate `codesign` call, not `--deep`

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Custom DMG layout with background | Shell script using raw hdiutil + AppleScript | `create-dmg` (brew) | AppleScript DMG layout is fragile and timing-sensitive; create-dmg handles `.DS_Store` tricks reliably |
| License key format/generation | Custom UUID-based key system | LemonSqueezy generated keys | LemonSqueezy keys are pre-validated server-side; custom systems require your own key database |
| Notarization workflow | Manual `xcrun altool` steps | `xcrun notarytool --wait` | `altool` is deprecated; `notarytool` is async by default but `--wait` makes it synchronous — one command |
| Microphone permission prompt | Custom permission dialog | `AVCaptureDevice.requestAccess(for: .audio)` | macOS ignores custom dialogs; only the system API triggers the TCC prompt |

**Key insight:** The notarization, DMG, and microphone permission flows are all solved problems with official macOS APIs or maintained open-source tools. The only custom implementation needed is the onboarding wizard UI and license enforcement logic.

---

## Entitlement Audit

This is the most uncertain technical area. Current entitlements:

| Entitlement | What It Allows | Likely Required For Voice? |
|-------------|----------------|---------------------------|
| `com.apple.security.device.audio-input` | Microphone access | YES — required for AVFoundation recording |
| `com.apple.security.automation.apple-events` | Send Apple Events to other apps | YES — TextInjector uses AX API |
| `com.apple.security.cs.disable-library-validation` | Load unsigned dylibs | PROBABLY — whisper-cli bundles dylibs; must test |
| `com.apple.security.cs.allow-unsigned-executable-memory` | Writable+executable memory pages | UNKNOWN — whisper.cpp uses JIT-style memory for GGML; must test without it |
| `com.apple.security.cs.allow-dyld-environment-variables` | Override DYLD env vars at launch | PROBABLY NOT — only needed if whisper-cli uses `DYLD_LIBRARY_PATH`; rebasing via `install_name_tool` should eliminate this need |

**Research finding (MEDIUM confidence):** The `install_name_tool` rebasing that the existing build scripts already do (converting `@rpath/` references to `@executable_path/../Frameworks/`) is specifically designed to eliminate the need for `DYLD_LIBRARY_PATH` overrides. If rebasing is correct, `allow-dyld-environment-variables` can likely be dropped. `allow-unsigned-executable-memory` is needed if whisper.cpp GGML allocates writable executable pages (it does on x86; Apple Silicon may not require it). The safe approach: test notarization with all three removed one at a time.

**Recommended whisper-cli entitlements file (start with this, test):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC ...>
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
```

**Recommended main app entitlements (keep these, test removing the rest):**
```xml
com.apple.security.device.audio-input     — required
com.apple.security.automation.apple-events — required
com.apple.security.cs.disable-library-validation — test: may be required for bundled dylibs
```

---

## Common Pitfalls

### Pitfall 1: Signing Order Breaks Notarization
**What goes wrong:** `codesign --deep Voice.app` signs dylibs after the app, invalidating the bundle signature. Notarization rejects with "The signature is invalid."
**Why it happens:** `--deep` recurses but signs in incorrect order (outer-in instead of inner-out).
**How to avoid:** Sign each dylib and whisper-cli explicitly before signing the bundle. Never use `--deep` in the production signing script.
**Warning signs:** `codesign --verify --deep Voice.app` passes but `spctl --assess` fails.

### Pitfall 2: Notarization Rejects Relaxed Entitlements
**What goes wrong:** Apple notarization rejects the app with "The executable requests the com.apple.security.cs.allow-unsigned-executable-memory entitlement" warning/error.
**Why it happens:** Apple's notarization service flags relaxed entitlements as security concerns and may reject without justification.
**How to avoid:** Drop `allow-dyld-environment-variables` entirely. Test `allow-unsigned-executable-memory` against whisper-cli at runtime before keeping it. Each removed entitlement reduces rejection risk.
**Warning signs:** `xcrun notarytool log` shows entitlement-related issues in the notarization report.

### Pitfall 3: LemonSqueezy instance_id Not Stored After Activate
**What goes wrong:** Activation succeeds but `instance.id` is discarded. Next validation call (without `instance_id`) returns `"instance": null` and does not validate the specific installation.
**Why it happens:** The response structure has nested `instance.id` — easy to miss if parsing the top-level response only.
**How to avoid:** Immediately after successful activation, store `response["instance"]["id"]` to UserDefaults. Verify it is non-empty before calling validate.
**Warning signs:** Re-validating shows `valid: false` even with a correct key.

### Pitfall 4: Relaunch Creates Duplicate Running Instance
**What goes wrong:** `NSWorkspace.openApplication` launches a second instance before the first exits, then the second instance detects the first and quits immediately (existing duplicate-instance guard at line 2050-2056).
**Why it happens:** The existing guard in `applicationDidFinishLaunching` kills the newer instance if it detects an older one still running.
**How to avoid:** In the relaunch path, the old instance must terminate first. Use `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)` AFTER calling `openApplication`, not before. The new instance starts while the old one is still alive — but with a 0.5s delay the old one exits before the new one reaches the duplicate check.
**Warning signs:** App appears to vanish immediately after toggling accessibility permission.

### Pitfall 5: LaunchAgent Still Pointing to Old Path After Bundle ID Rename
**What goes wrong:** User upgrades from dev build. Old `com.local.voice.plist` still launches the old app location. New app installs to `/Applications/Voice.app` but LaunchAgent points elsewhere.
**Why it happens:** LaunchAgent plist hardcodes `<Program>` path to wherever the binary was at install time. Renaming bundle ID without migrating the plist leaves the old agent active.
**How to avoid:** The migration logic in `applicationDidFinishLaunching` (described in Pattern 7) unloads the old plist and writes a fresh one with the new bundle ID and current executable path.
**Warning signs:** Two Voice processes visible in Activity Monitor after login.

### Pitfall 6: Onboarding Accessibility Step Advances Before Permission Is Actually Granted
**What goes wrong:** User clicks "Open System Settings," grants permission, returns to the app — but the onboarding wizard has no way to know the permission was granted and still shows the "Open Settings" button.
**Why it happens:** macOS does not send a notification when Accessibility TCC state changes; polling is the only mechanism.
**How to avoid:** Start the `AXIsProcessTrusted()` polling timer when the Accessibility step is shown. When the timer fires and `AXIsProcessTrusted()` returns `true`, automatically advance to the next onboarding step and stop the timer. The relaunch (D-19) is separate — it applies only when the app is fully running after onboarding, not during onboarding.
**Warning signs:** Accessibility step never auto-advances; user is stuck.

---

## Code Examples

Verified patterns from official sources and existing codebase:

### Open System Settings to Accessibility Pane
```swift
// Source: existing Voice.swift line 2136 pattern
NSWorkspace.shared.open(
    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
)
```

### Request Microphone Permission
```swift
// Source: AVFoundation - AVCaptureDevice.requestAccess
AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
        if granted {
            self.advanceOnboardingStep()
        } else {
            self.showMicPermissionDeniedMessage()
        }
    }
}
```

### Check Microphone Permission Status (without prompting)
```swift
// Source: AVFoundation
let status = AVCaptureDevice.authorizationStatus(for: .audio)
// .authorized, .denied, .restricted, .notDetermined
```

### LemonSqueezy Activate (matches existing URLSession pattern)
```swift
// Source: https://docs.lemonsqueezy.com/api/license-api/activate-license-key
func activateLicense(key: String, completion: @escaping (Bool, String?) -> Void) {
    guard let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let machineName = Host.current().localizedName ?? "Mac"
    let body = "license_key=\(key)&instance_name=\(machineName)"
    request.httpBody = body.data(using: .utf8)
    request.timeoutInterval = 15

    URLSession.shared.dataTask(with: request) { data, _, error in
        guard error == nil, let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            completion(false, nil); return
        }
        let activated = json["activated"] as? Bool ?? false
        let instanceId = (json["instance"] as? [String: Any])?["id"] as? String
        // CRITICAL: verify store_id and product_id match hardcoded values
        let meta = json["meta"] as? [String: Any]
        let storeId = meta?["store_id"] as? Int
        guard storeId == YOUR_STORE_ID else { completion(false, nil); return }
        completion(activated, instanceId)
    }.resume()
}
```

### Signing Script Pattern (Developer ID, inside-out)
```bash
# Source: Apple Developer Documentation - Customizing the notarization workflow
CERT="Developer ID Application: Faraday Soft (MWW7M2563A)"

# 1. Sign dylibs
for dylib in Voice.app/Contents/Frameworks/*.dylib; do
    codesign --force --sign "$CERT" --timestamp --options runtime "$dylib"
done

# 2. Sign helper binary
codesign --force --sign "$CERT" --timestamp --options runtime \
    --entitlements WhisperMinimal.entitlements \
    Voice.app/Contents/Resources/whisper-cli

# 3. Sign app bundle
codesign --force --sign "$CERT" --timestamp --options runtime \
    --entitlements Voice.entitlements \
    Voice.app

# 4. Sign DMG
codesign --force --sign "$CERT" --timestamp Voice-3.2.dmg
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `xcrun altool --notarize-file` | `xcrun notarytool submit --wait` | Xcode 13 (2021), altool deprecated Xcode 14 (2022) | Must use notarytool; altool no longer works |
| `--deep` flag for signing app bundles | Explicit inside-out per-binary signing | Guidance tightened ~2019-2022 | `--deep` still works for dev builds but fails notarization for complex bundles |
| LemonSqueezy v1 API (pre-2023) | Same `v1/licenses/*` endpoints | No breaking change — current as of 2026 | API is stable |

**Deprecated/outdated:**
- `xcrun altool`: Removed from Xcode 14+; use `notarytool`
- `--deep` codesign flag: Use only for ad-hoc dev signing; never for notarized distribution

---

## Open Questions

1. **Which relaxed entitlements does whisper-cli actually require?**
   - What we know: `allow-dyld-environment-variables` is likely removable because `install_name_tool` rebasing replaces DYLD path overrides. `allow-unsigned-executable-memory` may be required for GGML on Apple Silicon.
   - What's unclear: whisper.cpp GGML ARM backend behavior under hardened runtime without this entitlement.
   - Recommendation: Wave 1 of implementation — test notarization with progressively stripped entitlements. Start with all three on whisper-cli, then remove one at a time and verify runtime behavior.

2. **LemonSqueezy store_id and product_id values**
   - What we know: These must be hardcoded in the Swift source as constants to prevent cross-product key use.
   - What's unclear: The actual numeric IDs — not in any source file yet.
   - Recommendation: Retrieve from LemonSqueezy dashboard before implementing license validation and hardcode as `let LS_STORE_ID: Int = ...` and `let LS_PRODUCT_ID: Int = ...` in Settings.

3. **LemonSqueezy checkout URL**
   - What we know: D-13 requires a "Buy Voice ($29)" button that opens the checkout URL.
   - What's unclear: The exact LemonSqueezy checkout URL for the Voice product.
   - Recommendation: Hardcode the checkout URL as a constant; retrieve from LemonSqueezy dashboard.

4. **App-specific password for notarytool**
   - What we know: `xcrun notarytool store-credentials` requires an app-specific password generated at appleid.apple.com (not the Apple ID password).
   - What's unclear: Whether this credential is already set up in the developer's Keychain.
   - Recommendation: Document the one-time setup step in create-dmg.sh as a prerequisite comment; don't block the build if credentials are missing.

---

## Runtime State Inventory

> Included because D-15 involves a rename/unification of bundle ID.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | `UserDefaults` for `com.faradaysoft.voice` domain — no rename needed (UserDefaults uses bundle ID automatically; app already uses `com.faradaysoft.voice` bundle ID in Info.plist) | Code edit only — change the strings in Voice.swift that hardcode `com.local.voice` |
| Live service config | LaunchAgent plist at `~/Library/LaunchAgents/com.local.voice.plist` — one file per developer/user machine, not in git | Migration: unload old plist, write new `com.faradaysoft.voice.plist`, reload |
| OS-registered state | `launchctl` has `com.local.voice` registered as a service if autostart was enabled | Data migration: `launchctl unload` old, `launchctl load` new — handled by migration code in applicationDidFinishLaunching |
| Secrets/env vars | None — no secrets reference the bundle ID string | None |
| Build artifacts | No egg-info/compiled artifacts embed the bundle ID string. install.sh creates the LaunchAgent plist fresh each run. | install.sh update: change plist filename and label from `com.local.voice` to `com.faradaysoft.voice` |

---

## Sources

### Primary (HIGH confidence)
- `https://docs.lemonsqueezy.com/api/license-api/activate-license-key` — Activate endpoint URL, POST body, response structure
- `https://docs.lemonsqueezy.com/api/license-api/validate-license-key` — Validate endpoint URL, POST body, response fields
- `https://docs.lemonsqueezy.com/guides/tutorials/license-keys` — Recommended activation/validation flow, instance_id storage, product verification
- `https://github.com/create-dmg/create-dmg` — Installation command, `--background`, `--icon`, `--app-drop-link` options
- `Voice.swift` lines 39-220, 1247-1276, 2042-2162 — Direct inspection of Settings pattern, SettingsWindowController pattern, applicationDidFinishLaunching integration points
- `Voice.entitlements` — Direct inspection of current 5 entitlements
- `install.sh`, `create-dmg.sh` — Direct inspection of current signing and DMG creation scripts

### Secondary (MEDIUM confidence)
- `https://developer.apple.com/documentation/security/resolving-common-notarization-issues` — Entitlement-related notarization rejections
- `https://tuist.dev/blog/2024/12/31/signing-macos-clis` (2024) — Inside-out signing order for bundled CLIs
- `https://dennisbabkin.com/blog/?t=how-to-get-certificate-code-sign-notarize-macos-binaries-outside-apple-app-store` — Entitlements syntax for `codesign`
- `https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:)` — NSWorkspace.openApplication API

### Tertiary (LOW confidence)
- WebSearch results on `allow-unsigned-executable-memory` for GGML/whisper.cpp — multiple forum sources agree it's needed for JIT-style memory but not verified against whisper.cpp ARM64 specifically

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — LemonSqueezy API verified from official docs; signing tools from Apple docs; create-dmg from direct GitHub inspection
- Architecture: HIGH for signing/notarization/LemonSqueezy; MEDIUM for entitlement minimization (requires runtime testing)
- Pitfalls: HIGH for signing order and relaunch duplicate-instance (based on existing code inspection); MEDIUM for entitlement rejection (common pattern, not specifically tested for this app)

**Research date:** 2026-03-24
**Valid until:** 2026-06-24 (LemonSqueezy API stable; Apple notarization tools change rarely)
