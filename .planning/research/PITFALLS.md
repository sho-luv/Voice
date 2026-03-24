# Domain Pitfalls

**Domain:** macOS speech-to-text dictation app (Swift, AVFoundation, CGEvent tap, code signing)
**Researched:** 2026-03-24
**Confidence:** HIGH — several pitfalls are confirmed from actual lost work in this project; others verified against Apple Developer Forums and official documentation.

---

## Critical Pitfalls

Mistakes that cause data loss, rewrites, or permanently broken functionality.

---

### Pitfall 1: Uncommitted Work + `git checkout` = Total Loss

**What goes wrong:** Feature work is developed across a long session without intermediate commits. One bad `git checkout` (or `git restore`, `git reset --hard`) wipes everything. This already happened to this project — AVFoundation recording, waveform overlay, transcription history, and voice commands were all lost in a single command.

**Why it happens:** Large features feel unshippable until complete, so commits get deferred. Accidental destructive git commands are one keystroke away from an incomplete command.

**Consequences:** Hours or days of work gone. No recovery path. The feature must be rebuilt from scratch.

**Prevention:**
- Commit after every discrete, working unit — not after every feature is "done." A commit that says "WIP: AVAudioEngine records but no device selector yet" is infinitely better than no commit.
- Use a feature branch per phase so commits on the branch don't affect main.
- Never run `git checkout`, `git restore`, or `git reset` without first running `git status` and `git diff` to confirm what would be affected.

**Warning signs:** You've been working for more than 30 minutes without a commit. You're about to run a git destructive command "just to clean up."

**Phase relevance:** Every phase. Non-negotiable first-principle.

---

### Pitfall 2: Every Rebuild Invalidates TCC Accessibility Permission

**What goes wrong:** Each `swiftc` rebuild produces a binary with a different CDHash (code directory hash). macOS TCC uses the CDHash to identify which binary was granted Accessibility permission. When the hash changes, the permission entry no longer matches the new binary. The app can no longer inject keystrokes or monitor the fn key — silently, or with confusing "accessibility required" prompts that toggling in System Settings does not fix.

**Why it happens:** Ad-hoc signed builds (no `--options runtime`, no Developer ID) produce a new CDHash on every compile. TCC keyed to the old hash stops matching. Testing ad-hoc builds alongside Developer ID builds with the same bundle identifier causes TCC to get confused and treat permissions as revoked. (Source: Apple Developer Forums thread 703188)

**Consequences:** The core feature (push-to-talk paste) stops working. Developer wastes time debugging transcription, text injection, or audio — when the root cause is a stale TCC entry.

**Prevention:**
- Sign every build consistently with the same Developer ID certificate, not ad-hoc. Developer ID signing makes TCC recognize "this is the same app" across rebuilds.
- If using ad-hoc for local dev, reset TCC after each rebuild: `sudo tccutil reset Accessibility com.faradaysoft.voice`
- Never mix ad-hoc and Developer ID builds with the same bundle ID — TCC becomes permanently confused until you reset.
- Implement the auto-restart-on-permission-change pattern (like Wispr Flow): detect TCC state via `AXIsProcessTrusted()`, and when it transitions from false to true (user just granted), relaunch the app so the new binary registers cleanly.

**Warning signs:** Accessibility toggle in System Settings shows the app checked, but hotkey stops working. Toggling off and back on does not help. Adding `print(AXIsProcessTrusted())` returns `false` even though the UI shows it enabled.

**Phase relevance:** Code Signing phase and any phase that changes the compiled binary.

---

### Pitfall 3: AVAudioEngine Silent Failure with Bluetooth / AirPods

**What goes wrong:** `AVAudioEngine.inputNode.installTap()` works correctly with the built-in microphone but silently produces zero audio data (all 0.0 samples) when the user's default input device is a Bluetooth headset or AirPods. No error is thrown. The tap callback fires but the buffer contains silence. Transcription produces empty or garbage output.

**Why it happens:** Bluetooth headsets operate in two modes: high-quality stereo output (A2DP) and low-quality mono input/output (HFP/SCO). On macOS, AirPods expose two separate audio devices at different sample rates. `installTap` format negotiation fails silently when the format doesn't match the active Bluetooth profile. (Source: Apple Developer Forums, supermegaultragroovy.com AirPods analysis)

**Consequences:** App appears to record (waveform animates) but whisper-cli receives silence and transcribes nothing. User thinks transcription is broken. Very hard to reproduce in development if the dev machine uses the built-in mic.

**Prevention:**
- After AVFoundation migration, test immediately with: AirPods, a USB mic, and the built-in mic.
- Use `inputNode.outputFormat(forBus: 0)` for the tap format, NOT `inputNode.inputFormat(forBus: 0)` — the input format can return 0 channels when a Bluetooth device is connected.
- Register for `AVAudioEngineConfigurationChange` notification and rebuild the tap when the audio route changes.
- Validate the buffer in the tap callback: if all samples are zero for more than 0.5s, surface a warning.

**Warning signs:** Transcription returns empty string. `inputNode.inputFormat(forBus: 0).channelCount` returns 0 at startup.

**Phase relevance:** AVFoundation recording phase.

---

### Pitfall 4: Waveform Animation Breaks the App When Threaded Wrong

**What goes wrong:** Audio tap callbacks from `AVAudioEngine.installTap` run on an arbitrary background thread. Any attempt to update NSView, CALayer, or any AppKit UI directly from the tap callback causes undefined behavior — crashes, visual corruption, or deadlock. This is the exact failure mode that caused the previous session's waveform work to destabilize the app.

**Why it happens:** AppKit UI is not thread-safe. The tap callback is not on the main thread. Developers write `waveformView.update(levels: buffer)` in the tap closure thinking "it's just a view update" without dispatching to main.

**Consequences:** App crashes intermittently or on specific hardware. Crash logs point to AppKit internals, not the audio code. Hard to reproduce reliably.

**Prevention:**
- All UI updates from audio tap callbacks MUST go through `DispatchQueue.main.async { }`.
- Keep the tap callback lean: compute the RMS/peak value from the buffer in the callback (background thread is fine for math), then dispatch only the float value to the main thread to update the view.
- Never allocate new objects or call any AppKit method from inside the tap callback without a main queue dispatch.

**Warning signs:** App crashes after a few recordings but not the first one. Crash log shows `NSView` or `CALayer` in the stack trace alongside audio thread frames.

**Phase relevance:** Waveform overlay phase. Must be enforced from the first line of tap callback code.

---

### Pitfall 5: `disable-library-validation` Entitlement Conflicts with Notarization

**What goes wrong:** The app currently uses `disable-library-validation`, `allow-unsigned-executable-memory`, and `allow-dyld-environment-variables` entitlements to load the Homebrew-built whisper-cli dylibs. These entitlements are accepted by notarization today but they weaken the hardened runtime. Apple has been tightening these gates — macOS Sequoia (15) introduced stricter runtime protections.

**Why it happens:** Homebrew whisper-cli links against dylibs that are not signed by Apple or the app developer. The only way to load them without code-signing each dylib is to disable library validation.

**Consequences:** Future macOS versions may reject apps with these entitlements at notarization or Gatekeeper check time. The current entitlement set also flags the app in security scanners, which will concern privacy-conscious buyers.

**Prevention:**
- The long-term fix is to build whisper.cpp from source as part of the project build and sign all dylibs with the Developer ID certificate. This makes the entitlements unnecessary.
- For the immediate code signing phase: use the entitlements as-is (they work today), but document this as tech debt to address in a subsequent milestone.
- Sign every dylib bundled in the app using `codesign --sign "Developer ID Application: ..."` before notarizing.

**Warning signs:** Notarization succeeds but App Notary log reports warnings about unsigned dylibs. Gatekeeper quarantine message shown to users on first launch.

**Phase relevance:** Code signing phase and any future whisper.cpp refactor.

---

## Moderate Pitfalls

### Pitfall 6: Bundle Identifier Mismatch Breaks Duplicate-Instance Check and LaunchAgent

**What goes wrong:** `Info.plist` declares `com.faradaysoft.voice` but `Voice.swift` hardcodes `com.local.voice` in two places (duplicate-instance check and saved-state cleanup). The LaunchAgent also uses `com.local.voice`. When the signed DMG-distributed version runs, the duplicate-instance guard may not fire, allowing two instances to run simultaneously. The LaunchAgent may not launch the correct bundle.

**Why it happens:** The bundle identifier was changed in Info.plist during the branding transition from `com.local.voice` to `com.faradaysoft.voice` without a global find-replace across the codebase.

**Prevention:**
- Replace every hardcoded bundle ID string with `Bundle.main.bundleIdentifier ?? "com.faradaysoft.voice"`.
- Fix this before the code signing phase. A mismatched bundle ID during notarization causes subtle signing failures.

**Warning signs:** Two Voice instances appear in Activity Monitor simultaneously. LaunchAgent does not auto-start after login.

**Phase relevance:** Code signing phase (must be fixed before first notarization).

---

### Pitfall 7: AVAudioEngine Route Change Causes Silent Recording Stop

**What goes wrong:** If the user plugs in or unplugs headphones, connects AirPods, or changes audio devices while Voice is recording, `AVAudioEngine` silently stops the tap. The recording indicator stays active but audio capture has stopped. The resulting audio file is truncated or empty.

**Why it happens:** `AVAudioEngineConfigurationChange` notification fires when the audio graph changes. If the app does not handle this notification, the tap is silently invalidated.

**Prevention:**
- Register `NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange ...)` immediately after engine setup.
- In the handler: stop the tap, stop the engine, reconstruct the tap on the new format, restart the engine.
- Add a user-visible indicator if route change occurs mid-recording ("Audio device changed — recording stopped").

**Warning signs:** Test by plugging in headphones while recording. If the transcription produces shortened output or silence, route-change handling is missing.

**Phase relevance:** AVFoundation recording phase.

---

### Pitfall 8: CGEvent Tap Left Disabled After Exception in Critical Section

**What goes wrong:** The paste simulation code explicitly disables the CGEvent tap before injecting keystrokes (to avoid triggering itself) and re-enables it after. If an exception, early return, or crash occurs between disable and re-enable, the event tap stays disabled. The hotkey stops working for the rest of the session. There is no timeout or watchdog.

**Why it happens:** Error paths in the disable/re-enable critical section do not guarantee re-enable. This pattern already exists in the codebase (lines 735-760) with no `defer` guard.

**Prevention:**
- Wrap the disable/re-enable section in a Swift `defer { CGEvent.tapEnable(...) }` immediately after the disable call. `defer` runs even if an exception propagates or early return fires.
- Add a timer-based watchdog: if the tap has been disabled for more than 2 seconds, force-re-enable it.

**Warning signs:** After a paste that threw an error, fn key stops responding. Restarting the app restores it.

**Phase relevance:** Existing bug — fix in any phase that touches text injection or recording.

---

### Pitfall 9: Transcription History Storage Choice Regret

**What goes wrong:** Choosing Core Data or SwiftData for transcription history introduces schema migration complexity as the history model evolves (adding metadata, search indexes, audio file references). SwiftData specifically has documented pitfalls: array ordering is non-deterministic, relationships serialize incorrectly on reload, and debugging requires direct SQLite inspection. (Source: wadetregaskis.com SwiftData pitfalls)

**Why it happens:** SwiftData/Core Data feel like "the right macOS way" for persistence, but for a simple append-only log of text records they are significant overhead.

**Prevention:**
- Use plain SQLite via the system `sqlite3` library or a thin Swift wrapper (SQLite.swift). Schema is explicit, queries are trivial, migration is a single `ALTER TABLE`.
- Alternatively: a JSONL file (one JSON object per line) is sufficient for history up to tens of thousands of entries and requires zero dependencies.
- Decision rule: if history records are purely flat (text, timestamp, duration, language), SQLite is the right call. If relations become complex later, migrate then — not upfront.

**Warning signs:** You find yourself writing a Core Data `NSMigrationManager` before the feature ships.

**Phase relevance:** Transcription history phase.

---

### Pitfall 10: Waveform Rendering on Main Thread Causes Audio Recording Glitches

**What goes wrong:** Heavy drawing (using `NSBezierPath` to render dozens of waveform bars on every audio buffer, 44100 samples/sec) on the main thread introduces enough latency to starve the audio tap callback. This causes buffer overruns, clicks in the audio, and occasionally drops recording frames. The transcription quality degrades.

**Why it happens:** Audio taps have strict timing requirements. Any main-thread work that takes more than a few milliseconds between tap callbacks can cause the system to drop audio buffers.

**Prevention:**
- Compute waveform geometry (bar heights from RMS) in the tap callback on the background thread.
- Throttle UI updates: do not redraw on every buffer — redraw at 30fps using a `CADisplayLink` or `Timer` that reads the latest computed value.
- Keep `draw(_:)` in the waveform view trivially fast: just iterate pre-computed float values and draw rectangles.

**Warning signs:** Audio recordings have intermittent clicks or pops that go away when you hide the waveform overlay.

**Phase relevance:** Waveform overlay phase.

---

## Minor Pitfalls

### Pitfall 11: Hardcoded `/opt/homebrew` Paths Break Intel Macs

**What goes wrong:** `recPath`, `whisperPath` fallback, and the Ollama install paths all hardcode `/opt/homebrew/`. Intel Macs install Homebrew at `/usr/local/`. The app fails to record or transcribe on any Intel Mac.

**Prevention:** Use `Process` + `/usr/bin/which` to locate binaries dynamically, or ensure all binaries are bundled so no Homebrew path is needed at runtime.

**Phase relevance:** AVFoundation phase eliminates the `rec` path. Whisper bundling (already done for DMG) eliminates the whisper fallback.

---

### Pitfall 12: `notarytool submit --wait` Can Hang Indefinitely

**What goes wrong:** `xcrun notarytool submit ... --wait` sometimes hangs for 30+ minutes without output, making CI or scripted builds appear frozen. The submission itself succeeded; only the polling is broken.

**Prevention:** Submit without `--wait`, then poll with `xcrun notarytool info <submission-id>` every 30 seconds. Build this into `create-dmg.sh` rather than relying on `--wait`.

**Phase relevance:** Code signing and DMG distribution phase.

---

### Pitfall 13: Duplicate Bundling Logic in `install.sh` and `create-dmg.sh` Drifts

**What goes wrong:** Both scripts contain nearly identical dylib-path-fixing and whisper-cli copy logic. A fix applied to one is not applied to the other. Production DMGs end up with different dylib paths than locally-installed builds.

**Prevention:** Extract shared logic into a `bundle-whisper.sh` helper sourced by both scripts. Fix this before the code signing phase — dylib path issues are caught by notarization and are painful to debug after signing.

**Phase relevance:** Code signing phase.

---

### Pitfall 14: API Keys in UserDefaults Are Readable by Any User Process

**What goes wrong:** OpenAI and Anthropic API keys are stored in `~/Library/Preferences/com.faradaysoft.voice.plist` as plaintext strings. Any process running as the same macOS user (including malware) can `defaults read com.faradaysoft.voice` to extract them.

**Prevention:** Store API keys in the macOS Keychain via `SecItemAdd` / `SecItemCopyMatching`. Migration path: on first launch after the fix, read from UserDefaults, write to Keychain, delete from UserDefaults.

**Phase relevance:** Defer to a Security hardening phase unless the code signing phase happens to touch Settings. Not blocking for MVP.

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|----------------|------------|
| AVFoundation recording | Bluetooth silence (Pitfall 3) | Test with AirPods on day one of implementation |
| AVFoundation recording | Route change silent stop (Pitfall 7) | Register AVAudioEngineConfigurationChange in same PR as engine setup |
| Waveform overlay | Thread safety crash (Pitfall 4) | All UI from tap MUST be dispatched to main queue — enforce in code review |
| Waveform overlay | Main thread audio glitch (Pitfall 10) | Throttle draw calls to 30fps; never draw in tap callback |
| Code signing | TCC CDHash mismatch (Pitfall 2) | Sign with Developer ID before any TCC testing |
| Code signing | Bundle ID mismatch (Pitfall 6) | Fix all `com.local.voice` strings first |
| Code signing | Entitlement conflicts (Pitfall 5) | Sign all bundled dylibs; document remaining entitlements as tech debt |
| Code signing | DMG notarization hang (Pitfall 12) | Don't use `--wait`; poll `notarytool info` |
| Code signing | Dylib script drift (Pitfall 13) | Extract bundle-whisper.sh before signing anything |
| Transcription history | Storage choice regret (Pitfall 9) | Use SQLite directly; avoid Core Data / SwiftData |
| Any refactor | Git data loss (Pitfall 1) | Commit after every discrete working unit |
| Any phase touching paste | Event tap left disabled (Pitfall 8) | Add `defer { CGEvent.tapEnable(...) }` |

---

## Sources

- Apple Developer Forums thread 703188 — TCC and code signing identity: https://developer.apple.com/forums/thread/703188
- Apple Developer Forums — AVAudioEngine configuration change: https://developer.apple.com/forums/thread/122526
- Apple Developer Forums — installTap input node format issue: https://forums.developer.apple.com/forums/thread/695974
- supermegaultragroovy.com — AirPods and AVAudioEngine analysis: https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/
- wadetregaskis.com — SwiftData pitfalls: https://wadetregaskis.com/swiftdata-pitfalls/
- Apple Developer Documentation — Resolving common notarization issues: https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- jano.dev — Accessibility Permission in macOS (2025): https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html
- rsms gist — macOS distribution: code signing, notarization, quarantine: https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5
- Dolthub blog — How to publish a Mac desktop app outside the App Store (2024): https://www.dolthub.com/blog/2024-10-22-how-to-publish-a-mac-desktop-app-outside-the-app-store/
- Project CONCERNS.md — Direct codebase audit (2026-03-24)
- Project PROJECT.md — Lost work history and known constraints (2026-03-24)
