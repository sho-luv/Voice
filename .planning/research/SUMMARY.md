# Project Research Summary

**Project:** Voice — macOS push-to-talk dictation app (v3.2 milestone additions)
**Domain:** macOS native speech-to-text, single-file Swift, swiftc-only build
**Researched:** 2026-03-24
**Confidence:** HIGH

## Executive Summary

Voice is a macOS push-to-talk dictation app built as a single-file Swift monolith (~2230 lines) compiled directly with `swiftc` — no Xcode project, no SPM. This constraint is deliberate and governs every technical decision in the milestone. The recommended approach for all new features is to extend the existing monolith using Apple system frameworks already linked to the binary: `AVFoundation`, `CoreAudio`, `AppKit`, and `Security`. No new third-party dependencies are needed or appropriate for this milestone. The core recording layer must migrate from the external `rec` (SoX) binary to `AVAudioEngine` with `installTap` first, since mic selection, waveform visualization, and several other features all depend on having a native recording pipeline.

The competitive landscape shows that Voice is functionally solid but not yet sellable. Of the 13 table-stakes features users expect in this category, Voice currently meets 7. The four highest-priority gaps — animated waveform overlay, microphone selector, error recovery, and robust code signing/notarization — are all polish and reliability items, not new feature categories. Research confirms that users in this segment will forgive missing per-app context modes but will not forgive a stuck transcription or a broken install experience. The path to a shippable v3.2 is closing these reliability and distribution gaps, then layering in differentiators like transcription history and voice commands.

The critical risks are not technical complexity — the APIs are well-documented — but operational: thread safety in audio tap callbacks (every UI update from a tap must dispatch to main queue), TCC accessibility permission invalidation on every ad-hoc build (solved permanently by Developer ID signing), and git discipline to prevent another total work loss. The previous session lost AVFoundation recording, waveform overlay, transcription history, and voice commands in a single accidental `git checkout`. This milestone must commit after every discrete working unit.

## Key Findings

### Recommended Stack

All features for this milestone use Apple system frameworks already linked to the binary. The only build script change needed is explicitly adding `-framework CoreAudio` and `-framework Security` to the `swiftc` invocation — both are system frameworks with zero new dependencies. `AVAudioEngine` with `installTap` is the correct recording primitive: it delivers per-buffer PCM callbacks that simultaneously power WAV file writing and waveform amplitude computation, whereas `AVAudioRecorder` only supports polling-based metering and cannot cleanly support mic device selection. Transcription history must use JSON + `Codable` rather than Core Data or SwiftData — both require Xcode-generated model types incompatible with the swiftc-only build, and SwiftData additionally requires macOS 14+ which breaks the macOS 13 support requirement.

**Core technologies:**
- `AVAudioEngine` + `installTap` (AVFoundation): native audio recording — replaces SoX, enables waveform, required for mic selection
- `AudioObjectGetPropertyData` + `AudioUnitSetProperty` (CoreAudio): mic device enumeration and selection — the only correct macOS approach; `AVAudioSession` is iOS-only
- `NSView` + `NSBezierPath` (AppKit): waveform visualization — no third-party library needed; 40 bars at 60Hz is trivial for AppKit
- `Codable` + `JSONEncoder` + `FileManager`: transcription history persistence — zero new dependency, handles thousands of records
- `SecItemAdd` / `SecItemCopyMatching` (Security.framework): API key storage — replaces current UserDefaults plaintext storage
- `codesign --options runtime` + `xcrun notarytool` + `xcrun stapler`: distribution signing — required before any public release

### Expected Features

Voice competes in a crowded space where local processing and basic accuracy are commoditized. The differentiators that drive purchases in 2026 are price ($29 one-time vs. Wispr Flow at $200/year), simplicity, and verifiable privacy claims. The app must close reliability gaps before adding differentiating features.

**Must have (table stakes — required before charging $29):**
- AVFoundation recording migration — eliminates SoX dependency, unblocks waveform and mic selection
- Animated waveform overlay — 2025 standard; static indicator is now below expectations
- Microphone input selector — blocks professional users; every competitor has this
- Error recovery / transcription timeout — whisper-cli hang causes soft-lock; unacceptable in a paid tool
- First-launch onboarding with permission flow — non-technical users abandon without it
- Developer ID code signing + notarization — required for distribution; fixes TCC permission instability
- LemonSqueezy license key validation — required for revenue

**Should have (competitive — v3.3 targets):**
- Language selection (remove "en" hardcode) — opens international market immediately
- Transcription history with search — high retention value; was already built and lost
- Custom vocabulary via `--prompt` flag — addresses top Whisper accuracy complaint at near-zero implementation cost
- Model download progress indicator — 574MB downloads need progress UX
- Keychain storage for API keys — privacy-claiming app must not store secrets in UserDefaults

**Differentiators (v3.4+):**
- Per-app context mode — reads active app via accessibility API; VoiceInk's killer feature
- Voice commands ("scratch that", "new paragraph") — local, no Pro paywall; competitive vs. Wispr Flow
- File transcription (audio/video import) — expands use case; independent of push-to-talk pipeline

**Defer:**
- Account/login system (contradicts privacy positioning)
- Subscription pricing (target segment explicitly rejects it)
- Cloud transcription fallback (contradicts local privacy value prop)
- App Store version (sandbox breaks global hotkey and accessibility injection)
- Real-time streaming transcription (whisper.cpp is batch-based; faking it degrades quality)

### Architecture Approach

The architecture recommendation is "extend in place, extract only when necessary." The monolith is well-organized with MARK sections and current + new features land at approximately 2800-2900 lines — within the documented 3500-line threshold for extraction. Each new feature is added as a class or struct within `Voice.swift`. If the file exceeds 3500 lines, extraction order is: `VoiceAI.swift` first (AI clients, self-contained), then `VoiceHistory.swift`, then `VoiceAudio.swift`. The state machine remains: `idle -> recording/popo -> processing -> idle`. The `AVRecorder` class is a drop-in replacement for the SoX `Process` spawn — `startRecording(to:)` and `stopRecording()` return the same `/tmp/voice_*.wav` path that `transcribeAndProcess()` already reads.

**Major components:**
1. `AVRecorder` — `AVAudioEngine` recording, device selection, WAV output, amplitude callbacks; replaces SoX Process calls
2. `WaveformView` — subscribes to `AVRecorder.onAmplitude`, maintains circular buffer of RMS values, renders bars via SwiftUI Canvas inside existing `OverlayContentView`
3. `HistoryStore` — append-only JSON persistence in `~/Library/Application Support/Voice/history.json`; loaded once at launch; capped at 1000 records
4. `HistoryWindowController` — `NSWindowController` + `NSTableView` or SwiftUI List; opened via `Cmd+H`; calls `refocusAndInject()` for re-inject action
5. `VoiceCommandProcessor` — string pattern matching on whisper output before AI cleanup; replaces text with `\n\n` or suppresses injection for "scratch that"

**Full pipeline with new components:**
```
Hotkey -> AVRecorder -> (onAmplitude -> WaveformView)
       -> stopRecording -> transcribeAndProcess
          -> VoiceCommandProcessor -> AIClient -> HistoryStore.append -> refocusAndInject
```

### Critical Pitfalls

1. **Git data loss** — the previous session lost AVFoundation recording, waveform, history, and voice commands in a single accidental `git checkout`. Commit after every discrete working unit. Use feature branches per phase. Never run destructive git commands without first checking `git status` and `git diff`.

2. **TCC accessibility permission invalidated by ad-hoc builds** — every `swiftc` rebuild on an ad-hoc signed binary changes the CDHash; TCC stops recognizing the app; hotkey silently stops working. Fix: sign all builds consistently with Developer ID certificate. During dev, reset TCC with `sudo tccutil reset Accessibility com.faradaysoft.voice` after each rebuild. This is why notarization is a prerequisite, not just a distribution step.

3. **AVAudioEngine silent failure with Bluetooth/AirPods** — `installTap` fires but delivers all-zero samples when a Bluetooth device is the input; no error thrown; waveform animates but transcription produces nothing. Fix: use `inputNode.outputFormat(forBus: 0)` for tap format (not `inputFormat`); validate buffer in tap callback; test with AirPods on day one of AVFoundation implementation.

4. **Waveform animation thread safety crash** — audio tap callbacks run on a background thread; any AppKit UI update from the callback without `DispatchQueue.main.async` causes crashes that appear in AppKit internals, not audio code. Fix: compute RMS in the tap callback (background thread is fine for math), then dispatch only the float value to main. This rule must be enforced from the first line of tap code.

5. **Bundle ID mismatch breaks signing** — `Info.plist` uses `com.faradaysoft.voice` but Swift source hardcodes `com.local.voice` in the duplicate-instance check and LaunchAgent. Must be fixed before notarization. Replace all hardcoded strings with `Bundle.main.bundleIdentifier ?? "com.faradaysoft.voice"`.

## Implications for Roadmap

Research establishes a clear dependency order. AVFoundation migration is the critical path — it unblocks mic selection, waveform, and Bluetooth-safe recording. Code signing must happen before any meaningful user testing because TCC instability makes ad-hoc builds unreliable for the app's core feature. History and voice commands are independent of each other but both depend on a stable recording pipeline.

### Phase 1: AVFoundation Recording Migration + Mic Selection

**Rationale:** Everything else depends on this. SoX removal eliminates the only external Homebrew dependency and is required for mic selection and waveform. This is the highest-risk phase technically because CoreAudio device selection is lower-level C API — get it right first.
**Delivers:** Self-contained recording with device selection; no SoX required; stable WAV output for whisper-cli
**Addresses:** Microphone input selector (table stakes), Intel Mac compatibility (hardcoded `/opt/homebrew` paths), audio route change handling
**Avoids:** Pitfall 3 (Bluetooth silence — test AirPods on day one), Pitfall 7 (route change silent stop — register AVAudioEngineConfigurationChange immediately)

### Phase 2: Waveform Overlay

**Rationale:** Directly depends on Phase 1 (needs `AVRecorder.onAmplitude`). Once the amplitude callback exists, the waveform is a pure UI addition with no pipeline changes. Short phase.
**Delivers:** Animated waveform during recording — brings the app to 2025 visual standard
**Uses:** SwiftUI Canvas in existing `OverlayContentView`; `Accelerate.vDSP_rmsqv` optional optimization
**Avoids:** Pitfall 4 (thread safety — all UI from tap dispatched to main), Pitfall 10 (throttle draws to 30fps via `CADisplayLink`, never draw in tap callback)

### Phase 3: Code Signing + Notarization + Distribution

**Rationale:** Must happen before public user testing. TCC instability on ad-hoc builds makes the app unreliable for QA. Notarization gates the DMG release. Bundle ID mismatches must be fixed here. This is also where Keychain API key migration belongs.
**Delivers:** Signed, notarized DMG; stable TCC permissions across rebuilds; API keys in Keychain; LemonSqueezy license key validation
**Avoids:** Pitfall 2 (TCC CDHash — Developer ID signing fixes permanently), Pitfall 5 (sign all bundled dylibs before notarization), Pitfall 6 (fix `com.local.voice` before first notarytool run), Pitfall 12 (use `notarytool info` polling instead of `--wait`), Pitfall 13 (extract `bundle-whisper.sh` before signing anything)

### Phase 4: First-Launch Onboarding + Error Recovery

**Rationale:** These two features gate paid user conversion. Non-technical users abandon at the permission screen. The whisper-cli hang with no timeout is a known dealbreaker for a paid tool. Both are independent of each other but logically grouped as the "reliability and conversion" phase.
**Delivers:** Guided permission setup for new users; automatic timeout and recovery for hung transcriptions
**Avoids:** Pitfall 8 (add `defer { CGEvent.tapEnable(...) }` for event tap re-enable; watchdog timer if tap stays disabled >2s)

### Phase 5: Transcription History

**Rationale:** Depends on a stable recording pipeline (Phase 1) to have records worth storing. Independent of voice commands. The HistoryWindowController follows the existing SettingsWindowController pattern exactly — low-risk implementation.
**Delivers:** Searchable log of past transcriptions with copy and re-inject actions; `Cmd+H` menu item
**Uses:** JSON flat file in `~/Library/Application Support/Voice/history.json`; `NSTableView` or SwiftUI List inside `NSHostingView`
**Avoids:** Pitfall 9 (do not use CoreData or SwiftData — use JSON Codable; for longer-term consider SQLite if records approach 10K)

### Phase 6: Voice Commands

**Rationale:** Depends on Phase 1 (reliable recording) and Phase 5 (history, needed for "scratch that" to know what to delete). String pattern matching on whisper output — zero new frameworks.
**Delivers:** "Scratch that", "new paragraph", "new line", and punctuation commands handled locally; toggle in Settings
**Uses:** `VoiceCommandProcessor` struct inserted into `transcribeAndProcess()` before AI cleanup step
**Avoids:** Pitfall 4 (voice command execution is synchronous post-processing, no threading complexity)

### Phase Ordering Rationale

- Phase 1 before everything because mic selection and waveform cannot exist without `AVRecorder.onAmplitude`
- Phase 3 (code signing) before any public release testing because ad-hoc TCC instability will be confused for bugs in Phase 1/2 features
- Phase 4 (onboarding + error recovery) before shipping because these are explicit conversion gates for paid users
- Phase 5 before Phase 6 because voice commands' "scratch that" behavior depends on knowing the last injection record
- Phase 2 can swap with Phase 3 without consequences — they share no dependencies

### Research Flags

Phases needing deeper research during planning:
- **Phase 3 (Code Signing):** Entitlement conflicts with hardened runtime may require whisper.cpp source build and dylib signing — validate current entitlement set is still accepted by notarization before assuming the existing `Voice.entitlements` works as-is
- **Phase 3 (LemonSqueezy):** Integration with license key validation needs API research specific to LemonSqueezy's offline/grace-period behavior

Phases with standard well-documented patterns (skip research-phase):
- **Phase 1 (AVFoundation):** Apple docs + AudioKit source provide a complete reference implementation
- **Phase 2 (Waveform):** SwiftUI Canvas live waveform is thoroughly documented
- **Phase 5 (History):** JSON + Codable is a zero-research pattern
- **Phase 6 (Voice Commands):** String matching on whisper output — no API surface at all

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All choices use Apple system frameworks with stable official APIs; alternatives clearly ruled out by documented constraints (swiftc-only, macOS 13+) |
| Features | MEDIUM | Competitive analysis from review sites and official competitor pages; one-time pricing preference from community consensus rather than direct survey data |
| Architecture | HIGH | Build order derived from confirmed framework dependencies; component designs based on existing codebase review + official Apple documentation |
| Pitfalls | HIGH | Several pitfalls (git loss, TCC CDHash, bundle ID mismatch) are confirmed from this project's own history; Bluetooth/AVAudioEngine silence confirmed by Apple Developer Forums and supermegaultragroovy.com analysis |

**Overall confidence:** HIGH

### Gaps to Address

- **CoreAudio mic selection API stability:** The `kAudioOutputUnitProperty_CurrentDevice` approach is confirmed in Apple Developer Forums and AudioKit but is low-level C API with no high-level Swift alternative. Test on both Apple Silicon and Intel (if available) before treating it as done.
- **LemonSqueezy offline behavior:** What happens when a license key cannot be validated due to no network? Research needed before Phase 3 implementation begins.
- **Notarization entitlement review:** The three relaxed entitlements (`allow-unsigned-executable-memory`, `disable-library-validation`, `allow-dyld-environment-variables`) are currently accepted but Apple has been tightening runtime protections. Validate against a test submission before building DMG release automation.
- **AVAudioConverter 16kHz downsampling:** Medium-confidence finding that AVAudioConverter correctly handles the native mic rate (44.1kHz or 48kHz) to 16kHz conversion in the tap callback. Validate with actual whisper-cli output quality before committing to this approach.

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation — AVAudioEngine, installTap, AVAudioFile, AVAudioConverter
- Apple Developer Documentation — AudioObjectGetPropertyData, kAudioOutputUnitProperty_CurrentDevice
- Apple Developer Documentation — Notarizing macOS software, Resolving common notarization issues
- Apple Developer Documentation — Storing Keys in the Keychain
- Apple Developer Forums thread 71008 — AVAudioEngine device selection
- Apple Developer Forums thread 703188 — TCC and code signing identity
- AudioKit source — AVAudioEngine+Devices.swift (battle-tested device selection reference)
- Project CONCERNS.md — direct codebase audit (2026-03-24)
- Project PROJECT.md — lost work history and known constraints (2026-03-24)

### Secondary (MEDIUM confidence)
- SuperWhisper official site + reviews — feature benchmark
- VoiceInk official site + open source GitHub — Power Mode architecture reference
- MacWhisper official Gumroad page — file transcription feature set
- tldv.io + afadingthought.substack.com — Wispr Flow feature and pricing analysis
- supermegaultragroovy.com — AirPods and AVAudioEngine Bluetooth analysis
- createwithswift.com — SwiftUI Canvas live waveform tutorial
- reiterate.app blog — AVAudioEngine WAV file writing at 16kHz

### Tertiary (LOW confidence)
- wadetregaskis.com — SwiftData pitfalls (informed SQLite recommendation for history)
- zackproser.com best-mac-dictation-app-2026 — user pain point aggregation
- onresonant.com Reddit summary — subscription fatigue / one-time pricing preference

---
*Research completed: 2026-03-24*
*Ready for roadmap: yes*
