# Technology Stack

**Project:** Voice — macOS dictation app (milestone additions)
**Researched:** 2026-03-24
**Scope:** AVFoundation recording, waveform visualization, transcription history, voice commands, mic device selection, code signing/notarization

---

## Current Stack Baseline

The existing app is a single-file Swift monolith (`Voice.swift`, ~2230 lines) compiled with `swiftc` directly. No Xcode project, no SPM. All external processes are invoked via `Process`. The only framework additions needed for this milestone are already imported (`AVFoundation` is linked but unused for recording today). This stack document covers only the additions needed for milestone features.

---

## Feature Stack Decisions

### 1. AVFoundation Audio Recording (replacing sox/rec)

**Use:** `AVAudioEngine` with `installTap(onBus:bufferSize:format:block:)` — NOT `AVAudioRecorder`

**Rationale:**
- `AVAudioRecorder` writes directly to a file and has no callback for live samples. It cannot power waveform visualization without a polling timer — a workaround that's worse than the alternative.
- `AVAudioEngine` exposes `installTap` on its input node, delivering `AVAudioPCMBuffer` callbacks on a real-time thread. The same buffer stream feeds both the WAV file write AND the waveform animation — one data path for two features.
- `AVAudioEngine` also allows setting the underlying CoreAudio input device unit (see mic selection below), which `AVAudioRecorder` does not support cleanly.
- The existing `rec` process writes 16kHz mono 16-bit WAV. `AVAudioEngine` with `installTap` can write the same format by converting the input node's native format to a `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)` output.

**API surface:**
```swift
// Framework: AVFAudio (part of AVFoundation, already linked)
import AVFoundation

let engine = AVAudioEngine()
let inputNode = engine.inputNode
let inputFormat = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, time in
    // Write buffer samples to file, compute metering
}
try engine.start()
```

**WAV file writing:** Use `AVAudioFile` with `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)` — writes standard PCM WAV. Drop-in replacement for the temp file that whisper-cli already reads.

**Do NOT use:**
- `AVAudioRecorder` — can't do live metering callbacks without `isMeteringEnabled` polling (fires on timer, not per-buffer)
- `Process` + `rec` (sox) — eliminates external Homebrew dependency, which is the whole point of this feature

**Confidence:** HIGH — AVFoundation is system-provided, version-stable, officially documented by Apple

---

### 2. Microphone Input Device Selection

**Use:** CoreAudio `AudioObjectGetPropertyData` to enumerate devices + `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` to activate a specific device on AVAudioEngine's input node

**Rationale:**
On macOS, `AVAudioEngine.inputNode` always reads from the system default input device. There is no AVFoundation-level API to select a different device. The solution is two-part:
1. Enumerate devices using CoreAudio's `AudioObjectGetPropertyData` with `kAudioHardwarePropertyDevices` + `kAudioDevicePropertyScopeInput`
2. Force AVAudioEngine's underlying input Audio Unit to use the selected device ID via `AudioUnitSetProperty`

This is the established pattern documented in Apple Developer Forums and the AudioKit community. It requires importing `CoreAudio` (already a macOS system framework, zero new dependencies).

**API surface:**
```swift
// Framework: CoreAudio (system, no new dependency)
import CoreAudio

// Enumerate input devices
var propAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
// ... AudioObjectGetPropertyDataSize + AudioObjectGetPropertyData

// Set device on AVAudioEngine input node
let inputUnit = engine.inputNode.audioUnit!
var deviceID: AudioDeviceID = selectedDeviceID
AudioUnitSetProperty(inputUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0,
    &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
```

**Settings UI:** `NSPopUpButton` in the existing Settings window (Transcription tab) listing device names from CoreAudio enumeration. Persist selected device UID (string, survives device reconnect) to `UserDefaults`.

**Do NOT use:**
- `AVCaptureDevice.devices(for: .audio)` — this is a capture session API designed for video + audio together; it enumerates devices but does not connect to AVAudioEngine without an `AVCaptureSession`, which is unnecessary overhead
- Changing the system default input device with `kAudioHardwarePropertyDefaultInputDevice` — invasive, changes device for all apps, not just Voice

**Confidence:** MEDIUM — The `kAudioOutputUnitProperty_CurrentDevice` approach is confirmed in multiple Apple Developer Forum threads and the AudioKit issue tracker. The API is low-level C but stable. Requires engine stop/restart when switching devices.

---

### 3. Waveform Visualization

**Use:** `AVAudioEngine` tap buffer analysis + `CALayer`/`NSView` with `setNeedsDisplay` — pure AppKit, no third-party libraries

**Rationale:**
- The existing overlay (`OverlayWindow`, `OverlayContentView` in Voice.swift) is already an AppKit `NSView` with a custom pulsing animation drawn using `NSBezierPath`
- Extending this view to draw waveform bars requires only: reading RMS values from the AVAudioEngine tap buffer (computed on the tap thread), storing a rolling array of ~40 samples, triggering `setNeedsDisplay()` on the main thread at display refresh rate via `CADisplayLink` or a 60Hz `Timer`
- Drawing is 40 `NSBezierPath` rectangles — trivial, no frameworks needed

**Signal processing:**
```swift
// In the installTap callback — compute RMS from PCM samples
let channelData = buffer.floatChannelData![0]
let frameLength = Int(buffer.frameLength)
let rms = sqrt(channelData[..<frameLength].map { $0 * $0 }.reduce(0, +) / Float(frameLength))
// Map to display height, push to circular buffer
```

Use `Accelerate.vDSP_rmsqv` for the RMS computation if buffer sizes get large — it's 10x faster than a Swift loop and Accelerate is a system framework. For 4096-frame buffers at 44.1kHz it is not necessary; add it only if profiling shows CPU pressure.

**Do NOT use:**
- DSWaveformImage (Swift package) — for visualizing static audio files, not live metering
- EZAudio — last commit 2018, effectively abandoned
- Metal shaders — overkill for 40 bars at 60Hz; CALayer rendering is sufficient

**Confidence:** HIGH — Standard AppKit pattern. No external dependencies.

---

### 4. Transcription History

**Use:** JSON file persistence in `~/Library/Application Support/Voice/History/` — NOT Core Data, NOT SwiftData

**Rationale:**
- The project has a hard constraint: single-file Swift compiled with `swiftc`, no Xcode project. Core Data requires `.xcdatamodeld` bundle resources and code generation tooling that only exist in Xcode. SwiftData (macOS 14+) similarly requires Xcode-generated model types and drops macOS 13 support.
- Transcription history has a flat, simple schema: `id`, `timestamp`, `rawText`, `cleanedText`, `durationSeconds`, `appName`. This is a `Codable` struct — no relationships, no migrations needed.
- A `JSONEncoder`/`JSONDecoder` + `FileManager` approach handles hundreds of entries with negligible performance impact (dictation produces at most ~100 entries/day for heavy users; 10,000 entries = ~5MB JSON).
- Search is a simple `filter` on the in-memory array. No SQL needed.

**Schema:**
```swift
struct TranscriptionEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let rawText: String
    let cleanedText: String?
    let durationSeconds: Double
    let appName: String?          // target app name from AppContext
}
```

**Storage path:** `~/Library/Application Support/Voice/history.json` — single file, atomic write via `Data.write(to:options:.atomic)`. Load once at startup into an in-memory array, append + rewrite on each new transcription.

**History UI:** New `NSWindow` (`HistoryWindowController`) with an `NSTableView` displaying entries, an `NSSearchField` for filtering, and a "Copy" button. Opened via `Cmd+H` menu item (matches PROJECT.md spec).

**Do NOT use:**
- `UserDefaults` — documented 1MB practical limit; transcription history will exceed this
- Core Data — requires Xcode, .xcdatamodeld, generated classes; incompatible with swiftc-only build
- SwiftData — requires macOS 14+, breaks macOS 13 support requirement, requires Xcode project
- SQLite directly — unnecessary complexity for a flat list of 100–10,000 entries

**Confidence:** HIGH — Standard Codable + FileManager pattern, well understood, zero new dependencies.

---

### 5. Voice Commands

**Use:** Text matching on the whisper transcription output — NO additional speech recognition framework

**Rationale:**
- Voice commands like "scratch that", "new paragraph", "select all" need to be detected from the transcription result, not as a parallel speech recognition stream.
- The existing pipeline already produces a transcribed string. Pre-process it: check for command keywords before injecting text.
- `NaturalLanguage.framework` or `Speech.framework`'s `SFSpeechRecognizer` would add a real-time parallel recognition pipeline — massive complexity, battery impact, and latency for commands that are just string literals.
- String matching with `lowercased()` + a predefined command dictionary is sufficient. Whisper's accuracy with command phrases is high.

**Implementation pattern:**
```swift
let commands: [String: () -> Void] = [
    "scratch that":   { self.textInjector.deleteLastInjection() },
    "new paragraph":  { self.textInjector.injectText("\n\n") },
    "new line":       { self.textInjector.injectText("\n") },
    "select all":     { self.simulateKeypress(key: "a", modifiers: .command) },
    "undo that":      { self.simulateKeypress(key: "z", modifiers: .command) },
    "period":         { self.textInjector.injectText(".") },
    "comma":          { self.textInjector.injectText(",") },
]
```

Run command matching before AI cleanup. If the transcription matches a command exactly (or with minor whitespace variation), execute the command instead of injecting text.

**Do NOT use:**
- `SFSpeechRecognizer` — requires network for non-on-device recognition; on-device mode has limited vocabulary and adds complexity
- `NSSpeechRecognizer` — AppKit's legacy API, triggers a separate macOS speech recognition system, conflicts with whisper dictation
- `NaturalLanguage.framework` — appropriate for intent classification in conversational apps; overkill for a static command vocabulary of ~10 phrases

**Confidence:** HIGH — Proven by Whisper Flow competitors using the same approach; no Apple API needed.

---

### 6. Code Signing and Notarization

**Use:** `codesign` + `xcrun notarytool` + `xcrun stapler` — existing toolchain, no new tools

**Rationale:**
The project already has `Voice.entitlements` and a Team ID (`MWW7M2563A`). The missing piece is enabling hardened runtime and using `notarytool` (the modern replacement for the deprecated `altool`, required since November 2023).

**Required entitlements for hardened runtime notarization:**
The existing `Voice.entitlements` contains entitlements that conflict with hardened runtime out of the box:
- `com.apple.security.cs.allow-unsigned-executable-memory` — required for whisper.cpp's JIT
- `com.apple.security.cs.disable-library-validation` — required for bundled dylibs
- `com.apple.security.cs.allow-dyld-environment-variables` — may be required for bundled dylibs

These are all accepted notarization exceptions and Apple reviews them. They will not cause rejection.

**Full signing + notarization workflow (shell, no Xcode):**
```bash
# 1. Sign all bundled binaries first (bottom-up)
codesign --force --sign "Developer ID Application: Enfrosec LLC (MWW7M2563A)" \
    --options runtime \
    --entitlements Voice.entitlements \
    Voice.app/Contents/Resources/whisper-cli

# 2. Sign all dylibs
for dylib in Voice.app/Contents/Frameworks/*.dylib; do
    codesign --force --sign "Developer ID Application: Enfrosec LLC (MWW7M2563A)" \
        --options runtime "$dylib"
done

# 3. Sign the main app bundle
codesign --force --deep --sign "Developer ID Application: Enfrosec LLC (MWW7M2563A)" \
    --options runtime \
    --entitlements Voice.entitlements \
    Voice.app

# 4. Package for submission (use ditto, not zip)
ditto -c -k --keepParent Voice.app Voice.app.zip

# 5. Submit to Apple notary service
xcrun notarytool submit Voice.app.zip \
    --keychain-profile "VoiceNotarize" \
    --wait

# 6. Staple the ticket to the app
xcrun stapler staple Voice.app

# 7. Build signed DMG (after stapling)
hdiutil create -volname Voice -srcfolder Voice.app -ov -format UDZO Voice-3.x.dmg
codesign --sign "Developer ID Application: Enfrosec LLC (MWW7M2563A)" Voice-3.x.dmg
```

**One-time keychain profile setup:**
```bash
xcrun notarytool store-credentials "VoiceNotarize" \
    --apple-id "your@email.com" \
    --team-id MWW7M2563A \
    --password "app-specific-password"
```

**CDHash stability problem:** Every `swiftc` recompile produces a different binary, which changes the CDHash and invalidates TCC accessibility permissions. Two mitigations exist:
1. **Preferred:** Use `com.apple.security.cs.allow-unsigned-executable-memory` + stable identity signing — TCC permissions are tied to bundle ID (`com.faradaysoft.voice`) and Developer ID, not CDHash, when Hardened Runtime is enabled with a proper Developer ID certificate. Ad-hoc signing (current) uses CDHash. This is why notarization fixes the problem, not just signs it differently.
2. **Fallback pattern (Wispr Flow approach):** On launch, detect if TCC permission is missing, prompt user to re-grant, and restart the app. Implement as `applicationDidFinishLaunching` preflight check.

**Do NOT use:**
- Ad-hoc signing (`--sign -`) for distribution — TCC ties to CDHash, breaks on every rebuild
- `altool` — deprecated November 2023, Apple notary service rejects uploads from it

**Confidence:** HIGH for the notarytool workflow; MEDIUM for the CDHash/TCC relationship with Developer ID (confirmed in PROJECT.md notes as observed behavior, consistent with Apple documentation on TCC and hardened runtime)

---

### 7. API Key Storage (Security Improvement — Not a New Feature, But Prerequisite)

**Use:** macOS Keychain via `SecItemAdd` / `SecItemCopyMatching` — replace current `UserDefaults` storage

**Rationale:**
Current `UserDefaults` storage of OpenAI/Anthropic API keys is unencrypted plist data readable by any process with user-level access. Keychain storage is encrypted by the OS and scoped to the app. This is the correct pattern for credentials on macOS.

This is a maintenance item, not a new feature, but it is a prerequisite for any future notarization review (reviewers flag plaintext secrets in UserDefaults).

**Do NOT use:**
- UserDefaults for API keys (current, must be replaced)
- Third-party Keychain wrappers (KeychainAccess, etc.) — the raw Security framework API is 4-5 lines per operation; no wrapper needed for this use case

**Confidence:** HIGH — Standard macOS security pattern.

---

## Consolidated Recommended Stack

| Feature | API/Framework | Notes |
|---------|--------------|-------|
| Audio recording | `AVAudioEngine` + `installTap` (AVFoundation) | System framework, already imported |
| WAV file write | `AVAudioFile` (AVFoundation) | System framework |
| Mic enumeration | `AudioObjectGetPropertyData` (CoreAudio) | System framework |
| Mic selection | `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` (CoreAudio) | System framework |
| Waveform drawing | `NSView` + `NSBezierPath` (AppKit) | No new dependency |
| RMS computation | Swift inline or `Accelerate.vDSP_rmsqv` | System framework |
| Transcription history | `Codable` structs + `JSONEncoder` + `FileManager` | Zero new dependency |
| History UI | `NSTableView` + `NSSearchField` (AppKit) | System framework |
| Voice commands | String matching on whisper output | Zero new dependency |
| Code signing | `codesign --options runtime` | Xcode CLI tools |
| Notarization | `xcrun notarytool` + `xcrun stapler` | Xcode CLI tools |
| API key storage | `SecItemAdd` / `SecItemCopyMatching` (Security.framework) | System framework |

**New frameworks to add to `swiftc` build command:** None — all features use frameworks already linked (`AVFoundation`, `CoreAudio`, `AppKit`, `Security`). The `CoreAudio` framework is implicitly available but should be added explicitly:

```bash
swiftc -O -o Voice Voice.swift \
    -framework Cocoa -framework ApplicationServices \
    -framework UserNotifications -framework AVFoundation \
    -framework CoreAudio -framework Security
```

---

## Alternatives Considered

| Decision | Alternative | Why Not |
|----------|-------------|---------|
| AVAudioEngine for recording | AVAudioRecorder | No live buffer callbacks; can't power waveform without polling |
| CoreAudio for mic selection | AVCaptureDevice | Needs AVCaptureSession; AVAudioEngine uses AudioUnit internally, not AVCaptureSession |
| JSON + Codable for history | Core Data | Requires .xcdatamodeld and Xcode codegen; incompatible with swiftc-only build |
| JSON + Codable for history | SwiftData | macOS 14+ only; drops macOS 13 support |
| String matching for voice commands | SFSpeechRecognizer | Parallel recognition pipeline adds complexity/battery; static command vocab doesn't need ML |
| String matching for voice commands | NSSpeechRecognizer | Legacy AppKit API; conflicts with system dictation |
| NSView + NSBezierPath for waveform | DSWaveformImage | Static file waveforms only; not live metering |
| Raw Security.framework for Keychain | KeychainAccess (SPM) | Would require SPM setup; 4-5 line raw API is sufficient |

---

## Sources

- [AVAudioRecorder — Apple Developer Documentation](https://developer.apple.com/documentation/avfaudio/avaudiorecorder)
- [installTap(onBus:bufferSize:format:block:) — Apple Developer Documentation](https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:))
- [AVFoundation Audio Playback, Recording, and Processing — Apple](https://developer.apple.com/documentation/avfoundation/audio-playback-recording-and-processing)
- [Select the audio device for AVAudioEngine — Apple Developer Forums](https://developer.apple.com/forums/thread/71008)
- [Enumerate audio input and output devices using Swift on macOS — GitHub Gist](https://gist.github.com/SteveTrewick/c0668ee438eb784cbc5fb4674f0c2cd1)
- [AudioObjectGetPropertyData — Apple Developer Documentation](https://developer.apple.com/documentation/coreaudio/1422524-audioobjectgetpropertydata)
- [Customizing the notarization workflow — Apple Developer Documentation](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Notarizing macOS software before distribution — Apple Developer Documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [macOS distribution — code signing, notarization, quarantine — GitHub Gist](https://gist.github.com/rsms/929c9c2fec231f0cf843a1a746a416f5)
- [Notarize a Command Line Tool with notarytool — Scripting OS X](https://scriptingosx.com/2021/07/notarize-a-command-line-tool-with-notarytool/)
- [Storing Keys in the Keychain — Apple Developer Documentation](https://developer.apple.com/documentation/security/storing-keys-in-the-keychain)

---

*Research confidence: HIGH for all core framework choices (all use Apple system frameworks with stable documented APIs). MEDIUM for CoreAudio mic selection (lower-level API, pattern confirmed in forums but no official high-level alternative exists).*

*Stack analysis: 2026-03-24*
