# Architecture Patterns

**Domain:** macOS push-to-talk dictation app (single-file Swift monolith)
**Researched:** 2026-03-24
**Overall confidence:** HIGH — based on official Apple docs, AudioKit source, Apple Developer Forums, and existing codebase analysis

---

## Current Architecture (Baseline)

The app is a 2230-line single-file Swift monolith (`Voice.swift`) with six logical layers, all owned by `AppDelegate`. The state machine is imperative:

```
idle -> recording/popo -> processing -> idle
```

Recording is currently delegated to the external `rec` (SoX) binary via `Process`. Everything else — hotkey interception, transcription dispatch, text injection, settings, overlay UI — is native Swift.

The monolith is well-organized with MARK sections and clear class boundaries. `swiftc` handles multi-file compilation cleanly, so splitting is an option if the file grows past ~3000 lines, but is not required for the features in scope.

---

## Recommended Architecture for New Features

### Core Principle: Extend in Place, Extract Only When Necessary

The monolith pattern is a deliberate constraint (`PROJECT.md`). Each new feature should be added as a class or struct within `Voice.swift`, following the existing MARK section pattern. Only extract to a new file if the total line count approaches 3500+.

---

## Component Boundaries

### Proposed Components for New Features

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| `AVRecorder` (new class) | AVFoundation audio recording, device selection, WAV output | `AppDelegate` (replaces SoX `Process` call) |
| `WaveformView` (new class) | Real-time amplitude visualization during recording | `AVRecorder` (subscribes to sample buffer), `OverlayContentView` (embedded) |
| `HistoryStore` (new class) | Persists transcription records (timestamp, text, duration, app) | `AppDelegate` writes on finish, `HistoryWindowController` reads |
| `HistoryWindowController` (new class) | Browse and search past transcriptions | `HistoryStore` |
| `VoiceCommandProcessor` (new struct) | Post-processes transcribed text for voice commands | `transcribeAndProcess()` pipeline (called before injection) |

---

## Detailed Component Designs

### 1. AVRecorder (Replace SoX Recording Layer)

**What:** Native AVFoundation recording using `AVAudioEngine` + `installTap`.

**Why AVAudioEngine over AVAudioRecorder:**
AVAudioRecorder is simpler but does not expose per-buffer audio samples. `AVAudioEngine.inputNode.installTap` provides both the WAV file output AND per-buffer amplitude data needed for the waveform. One engine serves both purposes. (HIGH confidence — Apple Developer Documentation, AudioKit source)

**Device selection on macOS:**
`AVAudioSession` is iOS-only. On macOS, device selection requires dropping to Core Audio:
```swift
AudioUnitSetProperty(
    engine.inputNode.audioUnit!,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
```
Device enumeration uses `AVCaptureDevice.devices(for: .audio)` (or `AudioObjectGetPropertyData` for pure CoreAudio). (HIGH confidence — Apple Developer Forums thread 71008, AudioKit AVAudioEngine+Devices.swift)

**Format handling:**
The microphone's native sample rate (typically 44100 or 48000 Hz) does not match whisper.cpp's expected input (16000 Hz). Two options:
- Write at native rate, let whisper-cli resample (whisper.cpp handles this internally — current SoX approach writes at 16000 Hz explicitly, so whisper already receives 16kHz)
- Use AVAudioConverter within the tap callback to downsample in real-time before writing

Recommendation: write WAV at 16000 Hz using `AVAudioConverter` inside the tap block. This matches what SoX currently produces and requires no whisper-cli changes. (MEDIUM confidence — confirmed via reiterate.app blog, Apple Developer Forums thread 698535)

**Interface to AppDelegate:**
```swift
class AVRecorder {
    var onAmplitude: ((Float) -> Void)?  // drives WaveformView
    func startRecording(to url: URL) throws
    func stopRecording() -> URL?         // returns finalized WAV path
    func availableDevices() -> [AudioDevice]
    func setInputDevice(_ id: AudioDeviceID) throws
}
```

**Drop-in replacement:** `startRecording` replaces the SoX `Process` spawn in `AppDelegate.startRecording()`. `stopRecording()` returns the same `/tmp/voice_*.wav` path that `transcribeAndProcess()` already expects. No changes to transcription pipeline.

---

### 2. WaveformView (Recording Feedback)

**What:** Animated waveform bars rendered during recording, embedded in `OverlayContentView`.

**How:** `AVRecorder.onAmplitude` fires on each audio buffer (every ~100ms). `WaveformView` maintains a circular buffer of recent amplitude values and redraws using `CAShapeLayer` or `NSBezierPath` in an `NSView`.

**Why not SwiftUI/Charts:** The existing overlay is AppKit (`NSWindow`, `NSView`, `NSHostingView` wrapping SwiftUI only for the overlay content). The waveform view fits cleanly as a subview within the existing `OverlayContentView` SwiftUI hierarchy. Use a SwiftUI `Canvas` with a `Timer` or Combine publisher to redraw — same pattern as the existing pulsing animation. (MEDIUM confidence — createwithswift.com live waveform tutorial confirms Canvas approach; no AppKit requirement verified)

**Data flow:**
```
AVAudioEngine tap buffer
  -> AVRecorder.onAmplitude callback (background audio thread)
  -> DispatchQueue.main.async
  -> @State var amplitudes: [Float] in OverlayContentView
  -> Canvas redraws bars
```

**No external dependencies needed.** Accelerate framework can compute RMS from buffer samples for smoother visualization, but is optional. (HIGH confidence — Apple Accelerate docs, SwiftUI Canvas docs)

---

### 3. HistoryStore (Transcription Persistence)

**What:** Lightweight persistence for past transcriptions (text, timestamp, source app, duration).

**Storage choice: JSON file in Application Support** — not CoreData, not SwiftData, not SQLite.

Rationale:
- CoreData requires Xcode project for model versioning (we have no Xcode project — swiftc only)
- SwiftData requires macOS 14+ (project targets macOS 13+, so SwiftData is out)
- SQLite via raw C API is verbose and has no Swift wrapper available without SPM
- JSON flat file handles hundreds or even thousands of records without query performance issues (transcription records are small — avg ~200 bytes of text)
- Codable + JSONEncoder/Decoder is zero-dependency, single-file-friendly, already used for settings serialization patterns in the project

(HIGH confidence — SwiftData requires macOS 14 confirmed by Apple docs + community; CoreData requires .xcdatamodel file incompatible with swiftc-only build)

**Model:**
```swift
struct TranscriptionRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let text: String
    let duration: TimeInterval
    let sourceApp: String?   // from AppContext
    let wordCount: Int
}
```

**Storage location:** `~/Library/Application Support/Voice/history.json` — same directory as models.

**Interface:**
```swift
class HistoryStore {
    static let shared = HistoryStore()
    var records: [TranscriptionRecord] { get }
    func append(_ record: TranscriptionRecord)
    func delete(id: UUID)
    func search(query: String) -> [TranscriptionRecord]
}
```

**Write pattern:** Append-on-finish (called from `finishProcessing()`). Load from disk once at launch. Writes are async to avoid blocking main thread. Cap at 1000 records (trim oldest) to bound file size.

---

### 4. HistoryWindowController (Browse UI)

**What:** `NSWindowController` with a search field and scrollable list of past transcriptions.

**Pattern:** Follow the existing `SettingsWindowController` pattern — `NSWindowController` subclass instantiated on demand, opened via menu item or `Cmd+H`.

**Contents:** `NSTableView` or a SwiftUI `List` inside `NSHostingView`. Filter by search field using `HistoryStore.search()`. Actions: copy, re-inject, delete. "Re-inject" calls `refocusAndInject()` with the selected record's text — same pipeline as a fresh transcription.

**No new patterns needed** — follows existing overlay and settings window conventions exactly. (HIGH confidence — existing code review)

---

### 5. VoiceCommandProcessor (Post-Processing)

**What:** Scans transcribed text for dictation commands before injection.

**Approach: String pattern matching on the transcribed output** — not a separate speech recognition pass, not a keyword-spotting model. Whisper already transcribed the audio; we just check if the output matches known command strings.

Commands to implement first:
- "scratch that" / "delete that" → suppress injection, optionally delete last injected text
- "new paragraph" → replace command with `\n\n`
- "new line" → replace with `\n`
- "period" / "comma" / "question mark" → replace with punctuation (optional — Whisper often handles these)

**Why not a separate model:** The latency budget is already consumed by whisper.cpp. Adding a keyword-spotter (Porcupine, Vosk, Apple's SpeechAnalyzer) adds complexity, a dependency, and latency to every recording. Post-processing matching is instant and sufficient for the command set. (HIGH confidence — this is how open-wispr, Wispr Flow, and Voice Type all handle basic commands per search results)

**Interface:**
```swift
struct VoiceCommandProcessor {
    struct Result {
        let shouldInject: Bool
        let processedText: String
        let commandFired: VoiceCommand?
    }
    enum VoiceCommand { case scratchThat, newParagraph, newLine }
    static func process(_ rawText: String) -> Result
}
```

**Position in pipeline:** Called in `transcribeAndProcess()` after whisper output, before AI cleanup (commands should be removed before AI sees the text). If `shouldInject == false`, skip injection and return to idle.

---

## Data Flow (Full Updated Pipeline)

```
[Hotkey Press]
  -> InputMonitor.onRecordStart
  -> AppDelegate.startRecording()
     -> AVRecorder.startRecording(to: /tmp/voice_XXXX.wav)
        -> AVAudioEngine.inputNode.installTap { buffer in
             onAmplitude(rms(buffer))   // -> WaveformView updates
             converter.convert(buffer) -> write to AVAudioFile
           }

[Hotkey Release]
  -> InputMonitor.onRecordStop
  -> AppDelegate.stopRecording()
     -> AVRecorder.stopRecording() -> url
     -> DispatchQueue.global(qos: .userInitiated).async:
        transcribeAndProcess(url)

[transcribeAndProcess]
  1. Validate file size (>1000 bytes)
  2. Run whisper-cli Process -> raw text
  3. VoiceCommandProcessor.process(rawText)
     -> if scratchThat: finishProcessing(nil), return
     -> else: processedText (commands replaced)
  4. If AI cleanup enabled: AIClient.cleanup(processedText) -> cleanedText
  5. HistoryStore.append(TranscriptionRecord(...))
  6. DispatchQueue.main.async: refocusAndInject(cleanedText)

[refocusAndInject]
  -> Re-activate previousApp
  -> TextInjector.injectText (AX or clipboard fallback)
  -> finishProcessing(cleanedText)
     -> AppState = .idle
     -> OverlayContentView shows preview
     -> Play success sound
```

---

## Suggested Build Order (Phase Dependencies)

Dependencies between components determine the correct build sequence:

**Phase 1: AVFoundation Recording** (no dependencies on new features)
- Implement `AVRecorder` class
- Replace SoX `Process` calls in `startRecording()`/`stopRecording()` with `AVRecorder`
- Add mic device selector to Settings > General tab
- This is the highest-priority phase because it eliminates the external SoX dependency that prevents self-contained distribution. All other features depend on a working recording layer.

**Phase 2: Waveform Overlay** (depends on Phase 1 — needs AVRecorder.onAmplitude)
- Add `WaveformView` subview to `OverlayContentView`
- Wire `AVRecorder.onAmplitude` -> WaveformView state
- Pure UI addition; no pipeline changes

**Phase 3: Voice Commands** (depends on Phase 1 — needs reliable recording)
- Implement `VoiceCommandProcessor`
- Insert into `transcribeAndProcess()` pipeline
- No UI additions needed; settings toggle in Transcription tab

**Phase 4: Transcription History** (depends on Phase 1 — needs records to store)
- Implement `HistoryStore`
- Wire `append()` call into `finishProcessing()`
- Implement `HistoryWindowController`
- Add `Cmd+H` menu item and toolbar shortcut

Each phase is independently shippable. Phase 2 and 3 can be done in either order (neither depends on the other). Phase 4 should come last because the history window UX is more complex and benefits from having reliable data from a polished recording layer.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Splitting Files Before Necessary
**What:** Extracting `AVRecorder` or `HistoryStore` into separate `.swift` files prematurely.
**Why bad:** `swiftc file_a.swift file_b.swift -o Voice` works, but `install.sh` and `create-dmg.sh` must be updated. The single-file constraint is deliberate and reduces build complexity. The project has explicit guidance: "may need to split if it grows past ~3000 lines." Current + new features = ~2800-2900 lines, which is within the threshold.
**Instead:** Add new classes as MARK sections in `Voice.swift`. Evaluate split at 3500+ lines.

### Anti-Pattern 2: Using SwiftData or CoreData for History
**What:** Reaching for a modern persistence framework for transcription records.
**Why bad:** SwiftData requires macOS 14+ (project targets macOS 13+). CoreData requires a `.xcdatamodel` file which is generated by Xcode — incompatible with the swiftc-only build. Neither is warranted for what amounts to a list of text records.
**Instead:** JSON flat file in Application Support, loaded once at launch, persisted async on each new record.

### Anti-Pattern 3: AVAudioSession on macOS
**What:** Using `AVAudioSession.sharedInstance().availableInputs` for device enumeration.
**Why bad:** `AVAudioSession` is iOS-only. It does not exist on macOS. This is a common pitfall for developers who copy iOS patterns.
**Instead:** `AVCaptureDevice.devices(for: .audio)` for enumeration, `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` for selection via Core Audio.

### Anti-Pattern 4: Separate Real-Time Keyword Detection
**What:** Running a keyword-spotter (Porcupine, Apple SpeechAnalyzer, Vosk) in parallel with whisper for voice commands.
**Why bad:** Adds a second model, second permission, significant latency, and ongoing maintenance. The voice command set ("scratch that", "new paragraph") is tiny and deterministic.
**Instead:** String pattern matching on whisper's output. Whisper already transcribed the audio accurately. Match against a command table and transform the text before injection.

### Anti-Pattern 5: SwiftUI for the Entire Settings/History UI
**What:** Rewriting SettingsWindowController or HistoryWindowController as pure SwiftUI views.
**Why bad:** The existing Settings is AppKit-based NSWindowController. Mixing paradigms in a single-file monolith creates confusion. The overlay already uses SwiftUI via NSHostingView (a well-established pattern in this codebase).
**Instead:** Follow the existing pattern: NSWindowController + NSHostingView wrapping a SwiftUI content view for complex content. Or pure AppKit if the content is simple table/list.

---

## File Splitting Guidelines

If `Voice.swift` approaches 3500 lines, extract in this order:

1. `VoiceAI.swift` — all three `AIClient` implementations (~300 lines, self-contained, no AppKit)
2. `VoiceHistory.swift` — `HistoryStore` + `TranscriptionRecord` (~200 lines, pure data)
3. `VoiceAudio.swift` — `AVRecorder` + `WaveformView` (~250 lines, AVFoundation)

**Do not split:** `AppDelegate`, `InputMonitor`, `TextInjector`, `Settings`. These are tightly wired to the main app lifecycle and each other. Splitting them creates more coupling problems than it solves.

**Build script update when splitting:**
```bash
swiftc Voice.swift VoiceAI.swift VoiceHistory.swift VoiceAudio.swift \
  -framework AVFoundation -framework CoreAudio \
  -framework AppKit -framework UserNotifications \
  -o Voice
```

---

## Scalability Considerations

| Concern | Now (single user, local app) | If History Grows Large |
|---------|------------------------------|------------------------|
| History reads | Load full JSON on launch | Add index file + lazy-load; SQLite if >10K records |
| Waveform performance | Single `Canvas` redraw @ 10fps is sufficient | No scaling concern — bounded by recording duration |
| Recording quality | AVAudioEngine at 16kHz mono is adequate for speech | No scaling concern |
| Voice command set | ~6-10 string patterns, O(n) scan | Still trivial at 100 commands |

---

## Sources

- [AVAudioEngine — Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avaudioengine) (official, HIGH confidence)
- [Audio Playback, Recording, and Processing — Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/audio-playback-recording-and-processing) (official, HIGH confidence)
- [Select the audio device for AVAudioEngine — Apple Developer Forums thread 71008](https://developer.apple.com/forums/thread/71008) (official forum, HIGH confidence)
- [AudioKit AVAudioEngine+Devices.swift](https://github.com/AudioKit/AudioKit/blob/main/Sources/AudioKit/Internals/Hardware/AVAudioEngine+Devices.swift) (reference implementation, HIGH confidence)
- [How to Record a .wav File with AVAudioEngine — reiterate.app](https://blog.reiterate.app/software/2022/03/11/acknowledgement-part-7/) (MEDIUM confidence — well-explained but single source)
- [Creating a Live Audio Waveform in SwiftUI — createwithswift.com](https://www.createwithswift.com/creating-a-live-audio-waveform-in-swiftui/) (MEDIUM confidence — SwiftUI Canvas pattern confirmed)
- [SwiftData requires macOS 14+ — Apple Developer Forums thread 731173](https://developer.apple.com/forums/thread/731173) (HIGH confidence — confirmed by multiple sources)
- [macOS working around AVAudioEngine device selection limitations — AudioKit Issue #2130](https://github.com/AudioKit/AudioKit/issues/2130) (HIGH confidence — battle-tested workaround)
- [Getting Started With Multi File Command Line Swift — sgeos.github.io](http://sgeos.github.io/swift/2016/02/08/getting-started-with-multi-file-command-line-swift.html) (MEDIUM confidence — older but swiftc multi-file behavior is stable)

---

*Architecture research: 2026-03-24*
