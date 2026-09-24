// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

import Cocoa
import ApplicationServices
import UserNotifications
import AVFoundation
import CoreAudio
import Security  // SecItemDelete: one-time purge of the old license key

// MARK: - App State

enum AppState {
    case idle
    case recording
    case popo          // POPO lock mode (continuous until fn tap)
    case processing
}

// MARK: - Hotkey Option

struct HotkeyOption {
    let name: String
    let keyCode: Int64
    let flagMask: CGEventFlags
}

let hotkeyOptions: [HotkeyOption] = [
    HotkeyOption(name: "fn", keyCode: 63, flagMask: .maskSecondaryFn),
    HotkeyOption(name: "Right Option", keyCode: 61, flagMask: .maskAlternate),
    HotkeyOption(name: "Left Option", keyCode: 58, flagMask: .maskAlternate),
    HotkeyOption(name: "Right Cmd", keyCode: 54, flagMask: .maskCommand),
]

// MARK: - Settings

class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "hotkeyIndex": 0,
            "soundsEnabled": true,
            "autoStartOnLogin": true,
            "popoTimeout": 5,
            "clipboardRestore": true,
            "aiEnabled": true,
            "micDeviceUID": "",
            "overlayShowAppName": true,
            "overlayShowAppIcon": true,
            "overlayShowWindowTitle": false,
            "overlayShowTimer": true,
        ])
        migrateLegacyAISettings()
        purgeLegacyLicensingData()
        migrateSpeechModelSetting()
    }

    var hotkeyIndex: Int {
        get { defaults.integer(forKey: "hotkeyIndex") }
        set { defaults.set(newValue, forKey: "hotkeyIndex") }
    }

    var hotkeyCode: Int64 {
        let idx = hotkeyIndex
        return idx < hotkeyOptions.count ? hotkeyOptions[idx].keyCode : 63
    }

    var hotkeyFlag: CGEventFlags {
        let idx = hotkeyIndex
        return idx < hotkeyOptions.count ? hotkeyOptions[idx].flagMask : .maskSecondaryFn
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: "soundsEnabled") }
        set { defaults.set(newValue, forKey: "soundsEnabled") }
    }

    var autoStartOnLogin: Bool {
        get { defaults.bool(forKey: "autoStartOnLogin") }
        set {
            defaults.set(newValue, forKey: "autoStartOnLogin")
            updateLaunchAgent(enabled: newValue)
        }
    }

    var popoTimeout: Int {
        get { defaults.integer(forKey: "popoTimeout") }
        set { defaults.set(max(1, min(30, newValue)), forKey: "popoTimeout") }
    }

    var popoTimeoutSeconds: TimeInterval {
        TimeInterval(popoTimeout) * 60.0
    }

    var clipboardRestore: Bool {
        get { defaults.bool(forKey: "clipboardRestore") }
        set { defaults.set(newValue, forKey: "clipboardRestore") }
    }

    var aiEnabled: Bool {
        get { defaults.bool(forKey: "aiEnabled") }
        set { defaults.set(newValue, forKey: "aiEnabled") }
    }

    var aiCustomPrompt: String {
        get { defaults.string(forKey: "aiCustomPrompt") ?? "" }
        set { defaults.set(newValue, forKey: "aiCustomPrompt") }
    }

    // Catalog id of the speech model (see ModelCatalog). Replaces the legacy
    // "whisperModel" key; migrated in migrateSpeechModelSetting().
    var speechModelID: String {
        get { defaults.string(forKey: "speechModel") ?? ModelCatalog.parakeet.id }
        set { defaults.set(newValue, forKey: "speechModel") }
    }

    var speechModel: ModelSpec { ModelCatalog.speech(id: speechModelID) }

    // Spoken language. "auto" detects; otherwise an ISO code (see
    // ModelCatalog.languages). Parakeet is multilingual regardless; this
    // steers Whisper and gates the English-only text cleanup.
    var transcriptionLanguage: String {
        get { defaults.string(forKey: "transcriptionLanguage") ?? "auto" }
        set { defaults.set(newValue, forKey: "transcriptionLanguage") }
    }

    // Free-text user vocabulary (names, acronyms, technical terms). Whisper
    // takes it as a decoder prompt; for every model it also restores the
    // user's spelling after transcription (TextCleanup.applyVocabulary).
    var customVocabulary: String {
        get { defaults.string(forKey: "customVocabulary") ?? "" }
        set { defaults.set(newValue, forKey: "customVocabulary") }
    }

    var micDeviceUID: String {
        get { defaults.string(forKey: "micDeviceUID") ?? "" }
        set { defaults.set(newValue, forKey: "micDeviceUID") }
    }


    var overlayShowAppName: Bool {
        get { defaults.bool(forKey: "overlayShowAppName") }
        set { defaults.set(newValue, forKey: "overlayShowAppName") }
    }

    var overlayShowAppIcon: Bool {
        get { defaults.bool(forKey: "overlayShowAppIcon") }
        set { defaults.set(newValue, forKey: "overlayShowAppIcon") }
    }

    var overlayShowWindowTitle: Bool {
        get { defaults.bool(forKey: "overlayShowWindowTitle") }
        set { defaults.set(newValue, forKey: "overlayShowWindowTitle") }
    }

    var overlayShowTimer: Bool {
        get { defaults.bool(forKey: "overlayShowTimer") }
        set { defaults.set(newValue, forKey: "overlayShowTimer") }
    }

    var overlayBackgroundOpacity: CGFloat {
        get {
            let val = defaults.double(forKey: "overlayBackgroundOpacity")
            return val > 0 || defaults.object(forKey: "overlayBackgroundOpacity") != nil ? CGFloat(val) : 0.85
        }
        set { defaults.set(Double(newValue), forKey: "overlayBackgroundOpacity") }
    }

    var overlayEnabled: Bool {
        get { defaults.object(forKey: "overlayEnabled") == nil ? true : defaults.bool(forKey: "overlayEnabled") }
        set { defaults.set(newValue, forKey: "overlayEnabled") }
    }

    var overlayFontSize: CGFloat {
        get {
            let val = defaults.double(forKey: "overlayFontSize")
            return val > 0 ? CGFloat(val) : 13.0  // Medium
        }
        set { defaults.set(Double(newValue), forKey: "overlayFontSize") }
    }

    var overlaySensitivity: Float {
        get {
            let val = defaults.float(forKey: "overlaySensitivity")
            return val > 0 ? val : 30.0
        }
        set { defaults.set(newValue, forKey: "overlaySensitivity") }
    }

    var saveTranscripts: Bool {
        get { defaults.object(forKey: "saveTranscripts") == nil ? true : defaults.bool(forKey: "saveTranscripts") }
        set { defaults.set(newValue, forKey: "saveTranscripts") }
    }

    var transcriptDirectory: String {
        get {
            let val = defaults.string(forKey: "transcriptDirectory") ?? ""
            if val.isEmpty {
                let defaultDir = NSHomeDirectory() + "/Documents/Voice Transcripts"
                return defaultDir
            }
            return val
        }
        set { defaults.set(newValue, forKey: "transcriptDirectory") }
    }

    func saveTranscript(_ text: String) {
        guard saveTranscripts else { return }
        let dir = transcriptDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "voice_\(formatter.string(from: Date())).txt"
        let path = (dir as NSString).appendingPathComponent(filename)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        NSLog("Voice: saved transcript to %@", path)
    }

    func searchTranscripts(query: String) -> [(date: Date, text: String, path: String)] {
        let dir = transcriptDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        var results: [(date: Date, text: String, path: String)] = []
        for file in files.sorted().reversed() where file.hasSuffix(".txt") {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if query.isEmpty || content.localizedCaseInsensitiveContains(query) {
                let datePart = file.replacingOccurrences(of: "voice_", with: "").replacingOccurrences(of: ".txt", with: "")
                let date = formatter.date(from: datePart) ?? Date()
                results.append((date: date, text: content, path: path))
            }
        }
        return results
    }

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: "onboardingComplete") }
        set { defaults.set(newValue, forKey: "onboardingComplete") }
    }

    func resetAll() {
        // Reset user-facing settings to defaults (preserves saved transcripts)
        let keysToReset = [
            "hotkeyIndex", "soundsEnabled", "autoStartOnLogin", "popoTimeout",
            "clipboardRestore", "aiEnabled", "speechModel", "transcriptionLanguage",
            "aiCustomPrompt", "customVocabulary", "micDeviceUID", "overlayShowAppName", "overlayShowAppIcon",
            "overlayShowWindowTitle", "overlayShowTimer",
            "overlayEnabled", "overlayBackgroundOpacity", "overlayFontSize",
            "overlaySensitivity", "saveTranscripts", "transcriptDirectory"
        ]
        for key in keysToReset {
            defaults.removeObject(forKey: key)
        }
    }

    // Pre-3.2 builds supported cloud AI providers (with API keys in
    // UserDefaults) and Ollama. Remove anything they left behind.
    private func migrateLegacyAISettings() {
        defaults.removeObject(forKey: "aiProvider")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("apiKey") || key.hasPrefix("aiModel") {
            defaults.removeObject(forKey: key)
        }
    }

    // Pre-3.3 installs chose among Whisper variants. Users with custom
    // vocabulary keep Whisper (only it can take the biasing prompt); everyone
    // else moves to Parakeet, which matches Whisper's accuracy ~10x faster.
    private func migrateSpeechModelSetting() {
        guard defaults.string(forKey: "speechModel") == nil,
              defaults.string(forKey: "whisperModel") != nil else { return }
        let hasVocabulary = !customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        speechModelID = hasVocabulary ? ModelCatalog.whisperTurbo.id : ModelCatalog.parakeet.id
        defaults.removeObject(forKey: "whisperModel")
    }

    // Voice is free and open source (GPL-3.0) since 3.3. Remove what the old
    // license / weekly-word-limit system stored: usage counters, trial date and
    // the LemonSqueezy license key in the Keychain.
    private func purgeLegacyLicensingData() {
        guard !defaults.bool(forKey: "licensingDataPurged") else { return }
        for key in ["wordsThisWeek", "weekResetDate", "trialStartDate", "lastLicenseValidation",
                    "licenseKey", "licenseInstanceId", "isLicensed"] {
            defaults.removeObject(forKey: key)
        }
        for account in ["license-key", "license-instance-id"] {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: "com.faradaysoft.voice",
                kSecAttrAccount: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        defaults.set(true, forKey: "licensingDataPurged")
    }

    func updateLaunchAgent(enabled: Bool) {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.faradaysoft.voice.plist"
        if enabled {
            // Find the current executable
            let execPath = Bundle.main.executablePath ?? "/Applications/Voice.app/Contents/MacOS/Voice"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.faradaysoft.voice</string>
                <key>Program</key>
                <string>\(execPath)</string>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - Audio Device Enumeration

struct AudioDevice {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
}

func listInputDevices() -> [AudioDevice] {
    var propAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize) == noErr else { return [] }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

    var inputDevices: [AudioDevice] = []
    for id in deviceIDs {
        // Check if device has input channels
        var inputScope = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &inputScope, 0, nil, &bufSize) == noErr, bufSize > 0 else { continue }

        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPtr.deallocate() }
        guard AudioObjectGetPropertyData(id, &inputScope, 0, nil, &bufSize, bufferListPtr) == noErr else { continue }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard inputChannels > 0 else { continue }

        // Get device name
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>? = nil
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &nameRef)
        let name = nameRef?.takeRetainedValue() as String? ?? ""

        // Get device UID
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef: Unmanaged<CFString>? = nil
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidRef)
        let uid = uidRef?.takeRetainedValue() as String? ?? ""

        // Filter out AVAudioEngine's internal aggregate devices
        if uid.hasPrefix("CADefaultDeviceAggregate") { continue }

        inputDevices.append(AudioDevice(uid: uid, name: name, deviceID: id))
    }
    return inputDevices
}

// MARK: - App Context

struct AppContext {
    let appName: String
    let windowTitle: String
    let fieldRole: String

    static func current() -> AppContext {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        var appName = "Unknown"
        var windowTitle = ""
        var fieldRole = ""

        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
           let app = focusedApp {
            var nameValue: AnyObject?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXTitleAttribute as CFString, &nameValue) == .success,
               let name = nameValue as? String {
                appName = name
            }

            var windowValue: AnyObject?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
               let window = windowValue {
                var titleValue: AnyObject?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let title = titleValue as? String {
                    windowTitle = title
                }
            }

            var elementValue: AnyObject?
            if AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &elementValue) == .success,
               let element = elementValue {
                var roleValue: AnyObject?
                if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &roleValue) == .success,
                   let role = roleValue as? String {
                    fieldRole = role
                }
            }
        }

        return AppContext(appName: appName, windowTitle: windowTitle, fieldRole: fieldRole)
    }
}

// MARK: - Shared Cleanup Prompt

func cleanupSystemPrompt(appContext: AppContext) -> String {
    let custom = Settings.shared.aiCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let vocab = Settings.shared.customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
    var customLine = custom.isEmpty ? "" : "\n    Additional instructions: \(custom)"
    if !vocab.isEmpty {
        customLine += "\n    Spell these terms exactly as written: \(String(vocab.prefix(300)))"
    }
    // Few-shot framing is load-bearing. Instruction-tuned small models
    // (even Qwen 1.5B) otherwise respond to message-shaped input as if
    // chatting. Input/Output examples force the model into rewriter mode.
    // See MODELS.md for the history.
    return """
    You are a text-cleanup filter. Your input is the user's raw speech transcript. Your output is the same text with filler words removed and punctuation added. Never answer the user, never offer help, never ask questions. Just rewrite the input.

    Examples:
    Input: um so I was thinking we should uh meet tomorrow
    Output: I was thinking we should meet tomorrow.

    Input: hey can you send me that report
    Output: Can you send me that report?

    Input: yeah lets go with plan B
    Output: Yeah, let's go with plan B.

    Rules:
    - Remove fillers: um, uh, like, you know, I mean, sort of, basically.
    - For mid-sentence corrections or "scratch that" / "no wait", keep only the final version.
    - Fix grammar and punctuation minimally. Capitalize proper nouns and sentence starts.
    - Preserve the speaker's exact words and meaning. Do not paraphrase or summarize.
    - Output plain text only. No lists, bullets, numbering, markdown, commentary, or preamble.
    Context: written in \(appContext.appName).\(customLine)
    """
}

// Raw ASR text -> text to paste. Hesitations ("um", "uh") are removed
// deterministically; the LLM only runs when the text needs judgment (ambiguous
// fillers, self-corrections, stutters), and its output is only used if it is
// still a faithful rewrite. Clean dictation never touches the model, so it
// can't be paraphrased. Blocks; call off the main thread.
func polishTranscript(_ raw: String, appContext: AppContext) -> String {
    let vocabulary = Settings.shared.customVocabulary
    // The hesitation rules and cleanup prompt are English-tuned. Apply them for
    // English or Automatic (usually English); for an explicitly non-English
    // language, just restore vocabulary spelling and paste the ASR text, which
    // is already punctuated.
    let lang = Settings.shared.transcriptionLanguage
    guard lang == "en" || lang == "auto" else {
        return TextCleanup.applyVocabulary(raw, vocabulary: vocabulary)
    }
    let text = TextCleanup.applyVocabulary(TextCleanup.removeHesitations(raw), vocabulary: vocabulary)
    // Very long dictation (~1000+ tokens) would crowd the model's context and
    // take seconds; it gets deterministic cleanup only.
    guard Settings.shared.aiEnabled, text.count <= 4000, TextCleanup.needsModel(text) else { return text }

    let prompt = cleanupSystemPrompt(appContext: appContext)
    guard let output = SpeechEngine.shared.generateCleanup(text, systemPrompt: prompt) else {
        return text
    }
    guard let accepted = TextCleanup.acceptModelOutput(output, for: text) else {
        NSLog("Voice: rejected cleanup output that drifted from the transcript")
        return text
    }
    return TextCleanup.applyVocabulary(accepted, vocabulary: vocabulary)
}

// MARK: - Input Monitor (CGEventTap for fn key)

class InputMonitor {
    var onRecordStart: (() -> Void)?
    var onRecordStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPopoStart: (() -> Void)?
    var onPopoStop: (() -> Void)?

    var eventTap: CFMachPort?  // exposed so paste can temporarily disable tap
    private var runLoopSource: CFRunLoopSource?
    private var fnDown = false
    private var fnDownTime: TimeInterval = 0
    private var isRecording = false
    private var isPopo = false
    private let minHoldDuration: TimeInterval = 0.3  // ignore taps < 300ms

    // Double-tap detection for POPO mode
    private var lastShortTapTime: TimeInterval = 0       // when the last short tap (release) happened
    private var pendingRecordStart = false                // waiting to see if second tap comes
    private var doubleTapTimer: DispatchWorkItem?         // fires if no second tap arrives
    private let doubleTapWindow: TimeInterval = 0.4       // max gap between taps
    private let shortTapThreshold: TimeInterval = 0.25    // taps shorter than this are "short"

    // Cached hotkey values — read from Settings once, updated via reloadHotkey()
    // Avoids hitting UserDefaults inside the CGEventTap callback
    var hotkeyCode: Int64 = 63
    var hotkeyFlag: CGEventFlags = .maskSecondaryFn

    func reloadHotkey() {
        hotkeyCode = Settings.shared.hotkeyCode
        hotkeyFlag = Settings.shared.hotkeyFlag
    }

    func start() -> Bool {
        // Try creating event tap directly — this is the real permission check
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        NSLog("Voice: attempting to create event tap...")
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: InputMonitor.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Voice: EVENT TAP FAILED - no accessibility permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Voice: event tap created successfully!")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func setRecording(_ active: Bool) {
        isRecording = active
        if !active { fnDown = false }
    }

    func setPopo(_ active: Bool) {
        isPopo = active
        if !active { fnDown = false }
    }

    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passRetained(event) }
        let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        // Re-enable if system disabled the tap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Use cached hotkey values from the monitor instance (no UserDefaults access)
        let hotkeyCode = monitor.hotkeyCode
        let hotkeyFlag = monitor.hotkeyFlag

        // Space key — no longer used for POPO activation (double-tap replaces Space+fn)
        if keyCode == 49 && (type == .keyDown || type == .keyUp) {
            return Unmanaged.passRetained(event)
        }

        // Escape key — cancel recording
        if type == .keyDown && keyCode == 53 {
            if monitor.isRecording || monitor.isPopo {
                DispatchQueue.main.async { monitor.onCancel?() }
                return nil  // swallow
            }
            return Unmanaged.passRetained(event)
        }

        // Hotkey (flagsChanged)
        guard type == .flagsChanged && keyCode == hotkeyCode else {
            return Unmanaged.passRetained(event)
        }

        let keyPressed = flags.contains(hotkeyFlag)
        let now = ProcessInfo.processInfo.systemUptime

        if keyPressed && !monitor.fnDown {
            // ── Key DOWN ──
            monitor.fnDown = true
            monitor.fnDownTime = now

            // In POPO mode, tap stops it
            if monitor.isPopo {
                DispatchQueue.main.async { monitor.onPopoStop?() }
                return nil
            }

            // Check for double-tap: second press within window after a short tap
            if monitor.pendingRecordStart && (now - monitor.lastShortTapTime) < monitor.doubleTapWindow {
                monitor.pendingRecordStart = false
                monitor.doubleTapTimer?.cancel()
                monitor.doubleTapTimer = nil
                NSLog("Voice: double-tap detected → POPO mode")
                DispatchQueue.main.async { monitor.onPopoStart?() }
                return nil
            }

            // Don't start recording immediately — wait to see if this is a short tap
            // Schedule deferred recording start after shortTapThreshold
            let deferredStart = DispatchWorkItem { [weak monitor] in
                guard let monitor = monitor, monitor.fnDown, !monitor.isRecording, !monitor.isPopo else { return }
                monitor.onRecordStart?()
            }
            monitor.doubleTapTimer?.cancel()
            monitor.doubleTapTimer = deferredStart
            DispatchQueue.main.asyncAfter(deadline: .now() + monitor.shortTapThreshold, execute: deferredStart)
            return nil  // swallow

        } else if !keyPressed && monitor.fnDown {
            // ── Key UP ──
            monitor.fnDown = false
            let holdDuration = now - monitor.fnDownTime

            // In POPO mode, ignore release
            if monitor.isPopo {
                return nil
            }

            // Short tap — recording hasn't started yet (deferred start didn't fire)
            if !monitor.isRecording {
                // Cancel the deferred recording start
                monitor.doubleTapTimer?.cancel()
                monitor.doubleTapTimer = nil
                // Mark as potential first tap of double-tap
                monitor.lastShortTapTime = now
                monitor.pendingRecordStart = true

                // If no second tap arrives, it was just a quick tap — ignore
                let timer = DispatchWorkItem { [weak monitor] in
                    guard let monitor = monitor else { return }
                    monitor.pendingRecordStart = false
                    monitor.doubleTapTimer = nil
                }
                monitor.doubleTapTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + monitor.doubleTapWindow, execute: timer)
                return nil
            }

            // Recording is active (held past threshold) — stop it
            if holdDuration < monitor.minHoldDuration {
                DispatchQueue.main.async { monitor.onCancel?() }
            } else {
                DispatchQueue.main.async { monitor.onRecordStop?() }
            }
            return nil
        }

        return Unmanaged.passRetained(event)
    }
}

// MARK: - Overlay Window

// Mini preview of the overlay pill shown in Settings
class OverlayPreviewView: NSView {
    var fontSize: CGFloat = 13.0  // Medium (matches the default overlayFontSize)
    private let containerWidth: CGFloat = 430  // parent container width for centering

    // Animated waveform so the "Waveform" slider shows a live effect in Settings.
    // Bars use the SAME formula as the real overlay — min(1, rawLevel * sensitivity)
    // — over a synthetic quiet-speech envelope, so low values barely move and
    // high values clip at full height, exactly as they would while dictating.
    private var wavePhase: CGFloat = 0
    private var waveTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startWave() } else { stopWave() }
    }

    private func startWave() {
        guard waveTimer == nil else { return }
        waveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.wavePhase += 0.35
            self.needsDisplay = true
        }
    }

    private func stopWave() {
        waveTimer?.invalidate()
        waveTimer = nil
    }

    deinit { stopWave() }

    // Calculate ideal width for current settings
    func idealWidth() -> CGFloat {
        let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]
        let smallAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize - 1)]
        let padding: CGFloat = 24
        var w: CGFloat = 8 + 6  // dot + gap
        if Settings.shared.overlayShowAppIcon { w += 16 + 4 }
        if Settings.shared.overlayShowAppName {
            w += min(("Terminal" as NSString).size(withAttributes: smallAttrs).width, 60) + 8
        }
        w += 35 + 8  // waveform + gap
        if Settings.shared.overlayShowTimer {
            w += ("0:05" as NSString).size(withAttributes: textAttrs).width
        }
        return w + padding
    }

    func resizeToFit() {
        let w = idealWidth()
        let h = max(fontSize * 2.4, 28)
        let centerX = (containerWidth - w) / 2
        let originY = frame.origin.y + frame.height - h
        frame = NSRect(x: centerX, y: originY, width: w, height: h)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if !Settings.shared.overlayEnabled { return }

        let bgOpacity = Settings.shared.overlayBackgroundOpacity
        if bgOpacity > 0 {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            NSColor(white: 0.1, alpha: bgOpacity).setFill()
            pill.fill()
        }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
        ]
        let smallAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.7, alpha: 1.0),
            .font: NSFont.systemFont(ofSize: fontSize - 1, weight: .regular)
        ]

        let dotSize: CGFloat = 8
        let barCount = 7
        let barWidth: CGFloat = 3.0
        let barGap: CGFloat = 2.0
        let waveformWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

        var totalWidth: CGFloat = dotSize + 6
        let sampleApp = "Terminal"
        if Settings.shared.overlayShowAppName {
            totalWidth += min((sampleApp as NSString).size(withAttributes: smallAttrs).width, 60) + 8
        }
        totalWidth += waveformWidth + 8
        let timerStr = "0:05" as NSString
        if Settings.shared.overlayShowTimer {
            totalWidth += timerStr.size(withAttributes: textAttrs).width
        }

        var x = bounds.midX - totalWidth / 2

        // Red dot
        let dotRect = NSRect(x: x, y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)
        NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        x += dotSize + 6

        if Settings.shared.overlayShowAppName {
            let nameSize = (sampleApp as NSString).size(withAttributes: smallAttrs)
            (sampleApp as NSString).draw(at: NSPoint(x: x, y: bounds.midY - nameSize.height / 2), withAttributes: smallAttrs)
            x += min(nameSize.width, 60) + 8
        }

        let sensitivity = Settings.shared.overlaySensitivity
        let maxBarHeight: CGFloat = bounds.height * 0.6
        let minBarHeight: CGFloat = 4.0
        for i in 0..<barCount {
            // Synthetic quiet-speech RMS (~0.012–0.030), then the real overlay's
            // amplification. A travelling sine makes the bars bounce.
            let rawLevel = 0.012 + 0.018 * (0.5 + 0.5 * sin(Double(wavePhase) + Double(i) * 0.9))
            let amplified = min(CGFloat(1.0), CGFloat(rawLevel) * CGFloat(sensitivity))
            let barHeight = max(minBarHeight, amplified * maxBarHeight)
            let bx = x + CGFloat(i) * (barWidth + barGap)
            let by = bounds.midY - barHeight / 2
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: barWidth, height: barHeight), xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        x += waveformWidth + 8

        if Settings.shared.overlayShowTimer {
            let timerSize = timerStr.size(withAttributes: textAttrs)
            timerStr.draw(at: NSPoint(x: x, y: bounds.midY - timerSize.height / 2), withAttributes: textAttrs)
        }
    }
}

class OverlayWindow: NSWindow {
    init() {
        let frame = NSRect(x: 0, y: 0, width: 280, height: 64)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = OverlayContentView(frame: frame)
        self.contentView = contentView
    }

    // Never steal focus from the active app
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionOnScreen() {
        guard let screen = NSScreen.main else { return }
        guard let cv = contentView as? OverlayContentView else { return }

        let fontSize = Settings.shared.overlayFontSize
        let padding: CGFloat = 24  // left + right padding
        var contentWidth: CGFloat = 0

        switch cv.overlayState {
        case .recording, .popo:
            // dot + gap
            contentWidth = 8 + 6
            if Settings.shared.overlayShowAppIcon { contentWidth += 16 + 4 }
            if Settings.shared.overlayShowAppName, !cv.targetAppName.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize - 1)]
                let nameW = min((cv.targetAppName as NSString).size(withAttributes: attrs).width, 80)
                contentWidth += nameW + 8
            }
            contentWidth += 35 + 8  // waveform + gap
            if Settings.shared.overlayShowTimer { contentWidth += 40 }
        case .transcribing:
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize + 2, weight: .medium)]
            contentWidth = ("\u{23F3} Transcribing..." as NSString).size(withAttributes: attrs).width
        case .done(let preview):
            let truncated = preview.count > 30 ? String(preview.prefix(30)) + "..." : preview
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize + 2, weight: .medium)]
            contentWidth = ("\u{2713} \(truncated)" as NSString).size(withAttributes: attrs).width
        case .error(let msg):
            let truncated = msg.count > 30 ? String(msg.prefix(30)) + "..." : msg
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize + 2, weight: .medium)]
            contentWidth = ("\u{2717} \(truncated)" as NSString).size(withAttributes: attrs).width
        }

        let w = contentWidth + padding
        let h = max(fontSize * 2.4, 28)  // height based on font size

        let newFrame = NSRect(x: 0, y: 0, width: w, height: h)
        setFrame(newFrame, display: true)
        contentView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        hasShadow = Settings.shared.overlayBackgroundOpacity > 0
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - w / 2
        let y = screenFrame.maxY - h - 12
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

enum OverlayState {
    case recording
    case popo
    case transcribing
    case done(String)
    case error(String)
}

class OverlayContentView: NSView {
    var overlayState: OverlayState = .recording {
        didSet { needsDisplay = true }
    }

    // Waveform state (WhatsApp-inspired animated bars — center tallest, radiates outward)
    var audioLevels: [Float] = Array(repeating: 0.0, count: 12)  // 12 samples for smooth waveform
    private var animationTimer: Timer?

    // Timer state
    var recordingStartTime: Date?
    private var elapsedTimer: Timer?

    // App context shown in the overlay
    var targetAppName: String = ""
    var targetAppIcon: NSImage?

    // Reference to app delegate for reading audio levels
    weak var appDelegate: AppDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func startAnimation() {
        animationTimer?.invalidate()
        elapsedTimer?.invalidate()
        recordingStartTime = Date()

        // Waveform animation at 30fps — reads currentAudioLevel from AppDelegate
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, let delegate = self.appDelegate else { return }
            let level = delegate.currentAudioLevel

            // Shift history left, push new sample at end
            for i in 0..<(self.audioLevels.count - 1) {
                self.audioLevels[i] = self.audioLevels[i + 1]
            }
            // Amplify for visual impact (raw RMS is very small)
            let amplified = min(Float(1.0), level * Settings.shared.overlaySensitivity)
            self.audioLevels[self.audioLevels.count - 1] = amplified

            self.needsDisplay = true
        }

        // Elapsed time redraw every second
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartTime = nil
        audioLevels = Array(repeating: 0.0, count: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background pill
        let bgOpacity = Settings.shared.overlayBackgroundOpacity
        if bgOpacity > 0 {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            NSColor(white: 0.1, alpha: bgOpacity).setFill()
            path.fill()
        }

        switch overlayState {
        case .recording, .popo:
            drawRecordingOverlay()
        case .transcribing:
            drawCenteredText(icon: "\u{23F3}", text: "Transcribing...")
        case .done(let preview):
            let truncated = preview.count > 30 ? String(preview.prefix(30)) + "..." : preview
            drawCenteredText(icon: "\u{2713}", text: truncated)
        case .error(let msg):
            let truncated = msg.count > 30 ? String(msg.prefix(30)) + "..." : msg
            drawCenteredText(icon: "\u{2717}", text: truncated)
        }
    }

    private func drawCenteredText(icon: String, text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: Settings.shared.overlayFontSize + 2, weight: .medium)
        ]
        let fullText = icon + " " + text
        let size = fullText.size(withAttributes: attrs)
        let textPoint = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        fullText.draw(at: textPoint, withAttributes: attrs)
    }

    private func drawRecordingOverlay() {
        let isRecordingState: Bool
        if case .recording = overlayState { isRecordingState = true } else { isRecordingState = false }

        let fontSize = Settings.shared.overlayFontSize
        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
        ]
        let smallAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.7, alpha: 1.0),
            .font: NSFont.systemFont(ofSize: fontSize - 1, weight: .regular)
        ]

        // --- Measure total content width first ---
        let dotSize: CGFloat = 8
        let barCount = 7
        let barWidth: CGFloat = 3.0
        let barGap: CGFloat = 2.0
        let waveformWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

        var totalWidth: CGFloat = dotSize + 6  // dot + gap

        if Settings.shared.overlayShowAppIcon, targetAppIcon != nil {
            totalWidth += 16 + 4  // icon + gap
        }

        var appNameWidth: CGFloat = 0
        if Settings.shared.overlayShowAppName, !targetAppName.isEmpty {
            let nameSize = (targetAppName as NSString).size(withAttributes: smallAttrs)
            appNameWidth = min(nameSize.width, 60)
            totalWidth += appNameWidth + 8
        }

        totalWidth += waveformWidth + 8  // waveform + gap

        var timerWidth: CGFloat = 0
        if Settings.shared.overlayShowTimer, recordingStartTime != nil {
            let elapsed = Int(Date().timeIntervalSince(recordingStartTime!))
            let timerStr = String(format: "%d:%02d", elapsed / 60, elapsed % 60) as NSString
            timerWidth = timerStr.size(withAttributes: textAttrs).width
            totalWidth += timerWidth
        }

        // --- Draw centered ---
        var x = bounds.midX - totalWidth / 2

        // Red dot (recording) or blue dot (POPO)
        let dotColor: NSColor = isRecordingState
            ? NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
            : NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0)
        let dotRect = NSRect(x: x, y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        x += dotSize + 6

        // App icon
        if Settings.shared.overlayShowAppIcon, let icon = targetAppIcon {
            let iconSize: CGFloat = 16
            let iconRect = NSRect(x: x, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
            icon.draw(in: iconRect)
            x += iconSize + 4
        }

        // App name
        if Settings.shared.overlayShowAppName, !targetAppName.isEmpty {
            let nameStr = targetAppName as NSString
            let nameSize = nameStr.size(withAttributes: smallAttrs)
            let namePoint = NSPoint(x: x, y: bounds.midY - nameSize.height / 2)
            nameStr.draw(at: namePoint, withAttributes: smallAttrs)
            x += min(nameSize.width, 60) + 8
        }

        // Waveform bars — WhatsApp-style: center bars tallest, mirrored outward
        let maxBarHeight: CGFloat = bounds.height * 0.7
        let minBarHeight: CGFloat = 4.0

        let center = barCount / 2
        var barLevels = [Float](repeating: 0, count: barCount)
        let latest = audioLevels.count - 1
        barLevels[center] = audioLevels[latest]
        for offset in 1...center {
            let sampleIdx = max(0, latest - offset * 2)
            let level = audioLevels[sampleIdx] * Float(1.0 - Double(offset) * 0.15)
            barLevels[center - offset] = level
            barLevels[center + offset] = level
        }

        let waveformX = x
        for i in 0..<barCount {
            let level = CGFloat(barLevels[i])
            let barHeight = max(minBarHeight, level * maxBarHeight)
            let bx = waveformX + CGFloat(i) * (barWidth + barGap)
            let by = bounds.midY - barHeight / 2
            let barRect = NSRect(x: bx, y: by, width: barWidth, height: barHeight)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        x = waveformX + waveformWidth + 8

        // Elapsed timer
        if Settings.shared.overlayShowTimer, let startTime = recordingStartTime {
            let elapsed = Int(Date().timeIntervalSince(startTime))
            let timerStr = String(format: "%d:%02d", elapsed / 60, elapsed % 60) as NSString
            let timerSize = timerStr.size(withAttributes: textAttrs)
            let timerPoint = NSPoint(x: x, y: bounds.midY - timerSize.height / 2)
            timerStr.draw(at: timerPoint, withAttributes: textAttrs)
        }
    }
}

// MARK: - Text Injector (Accessibility API)

// Delayed clipboard provider — matches Wispr Flow's NSPasteboardItemDataProvider approach.
// Instead of writing text directly to the clipboard, we register a provider that supplies
// the data on-demand when the target app reads the clipboard after Cmd+V.
class DelayedClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    let text: String
    var dataWasRequested = false
    var onDataRequested: (() -> Void)?

    init(text: String) {
        self.text = text
        super.init()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        dataWasRequested = true
        onDataRequested?()
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        // no-op — required by protocol
    }
}

class TextInjector {
    weak var inputMonitor: InputMonitor?  // to disable event tap during paste
    private var activeProvider: DelayedClipboardProvider?  // prevent ARC from releasing during paste

    // Terminal apps report AX value as settable but don't actually honor it for input.
    // Skip AX injection entirely for these and go straight to clipboard paste.
    private static let terminalBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
    ]

    func injectText(_ text: String) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? ""
        NSLog("Voice: injecting into %@ (%@)", frontApp?.localizedName ?? "nil", bundleID)

        // For terminals, always use clipboard paste — AX "succeeds" but doesn't actually type
        if TextInjector.terminalBundleIDs.contains(bundleID) {
            NSLog("Voice: terminal detected, using clipboard paste")
            clipboardPasteFallback(text)
            return
        }

        if tryAXInject(text) {
            NSLog("Voice: AX inject succeeded")
        } else {
            NSLog("Voice: AX failed, using clipboard paste")
            clipboardPasteFallback(text)
        }
    }

    private func tryAXInject(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            return false
        }

        let axElement = element as! AXUIElement

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }

        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
        let current = (currentValue as? String) ?? ""

        var rangeValue: AnyObject?
        var insertionPoint = current.count
        if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let range = rangeValue {
            var cfRange = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &cfRange) {
                insertionPoint = cfRange.location
            }
        }

        let safeInsertionPoint = min(max(insertionPoint, 0), current.count)
        let startIndex = current.index(current.startIndex, offsetBy: safeInsertionPoint)
        var newValue = current
        newValue.insert(contentsOf: text, at: startIndex)

        guard AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newValue as CFTypeRef) == .success else {
            return false
        }

        let newPosition = safeInsertionPoint + text.count
        var newRange = CFRange(location: newPosition, length: 0)
        if let rangeVal = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, rangeVal)
        }

        return true
    }

    private func clipboardPasteFallback(_ text: String) {
        let pasteboard = NSPasteboard.general
        let shouldRestore = Settings.shared.clipboardRestore

        // Save current clipboard contents (matching Wispr Flow's approach).
        // Filter to valid UTI types only — legacy types like NSStringPboardType cause errors on restore.
        var savedData: [(NSPasteboard.PasteboardType, Data)] = []
        if shouldRestore {
            let savedTypes = pasteboard.types ?? []
            for type in savedTypes {
                let raw = type.rawValue
                // Skip legacy non-UTI types (they start with "NS" or don't contain a dot)
                if raw.hasPrefix("NS") || (!raw.contains(".") && !raw.hasPrefix("com.") && !raw.hasPrefix("public.") && !raw.hasPrefix("org.")) {
                    continue
                }
                if let data = pasteboard.data(forType: type) {
                    savedData.append((type, data))
                }
            }
        }

        // Set up delayed clipboard rendering (like Wispr Flow's DelayedClipboardProvider)
        let provider = DelayedClipboardProvider(text: text)
        activeProvider = provider  // prevent ARC release

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        pasteboard.writeObjects([item])
        NSLog("Voice: clipboard ready (%d chars)", text.count)

        // Disable event tap, simulate Cmd+V, schedule clipboard restoration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulatePaste()

            // Restore original clipboard after 500ms (same as Wispr Flow)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if shouldRestore {
                    pasteboard.clearContents()
                    if !savedData.isEmpty {
                        let restoreItem = NSPasteboardItem()
                        for (type, data) in savedData {
                            restoreItem.setData(data, forType: type)
                        }
                        pasteboard.writeObjects([restoreItem])
                    }
                }
                self?.activeProvider = nil
            }
        }
    }

    private func simulatePaste() {
        // Temporarily disable our event tap so it doesn't intercept the simulated Cmd+V.
        // Wispr Flow avoids this by running paste from a separate process (Swift helper),
        // but disabling the tap achieves the same effect in a single-process architecture.
        if let tap = inputMonitor?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            NSLog("Voice: failed to create CGEvents for paste")
            if let tap = inputMonitor?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Re-enable the event tap after a short delay to let the paste event propagate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if let tap = self?.inputMonitor?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }
}

// MARK: - Model Download Window

// Downloads catalog models one at a time with a progress window. Each file is
// SHA-256 verified before it is moved into place, so a truncated or tampered
// download never reaches the C++ model loaders.
class ModelDownloadWindowController: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloadWindowController()

    private var window: NSWindow?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var retryButton: NSButton?
    private var session: URLSession?
    private var queue: [ModelSpec] = []
    private var completions: [() -> Void] = []

    /// Calls `completion` once every model in `specs` is installed. Missing
    /// models are downloaded; calls made while a download is running join it.
    func ensureModels(_ specs: [ModelSpec], completion: @escaping () -> Void) {
        let missing = specs.filter { spec in
            !spec.isInstalled && !queue.contains { $0.id == spec.id }
        }
        let busy = !queue.isEmpty
        if missing.isEmpty && !busy {
            completion()
            return
        }
        queue.append(contentsOf: missing)
        completions.append(completion)
        if !busy {
            showWindow()
            startNext()
        }
    }

    private var current: ModelSpec? { queue.first }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = "Downloading Models"
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating

        guard let contentView = w.contentView else { return }

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 30, y: 110, width: 360, height: 22)
        contentView.addSubview(title)
        titleLabel = title

        let subtitle = NSTextField(wrappingLabelWithString: "")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 30, y: 68, width: 360, height: 36)
        contentView.addSubview(subtitle)
        subtitleLabel = subtitle

        let bar = NSProgressIndicator(frame: NSRect(x: 30, y: 44, width: 360, height: 20))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        contentView.addSubview(bar)
        progressBar = bar

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 30, y: 18, width: 250, height: 18)
        contentView.addSubview(status)
        statusLabel = status

        window = w
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startNext() {
        guard let spec = current, let url = URL(string: spec.url) else { return }
        let purpose = spec.role == .speech ? "speech recognition" : "AI text cleanup"
        titleLabel?.stringValue = "Downloading \(purpose) model..."
        subtitleLabel?.stringValue = "One-time download (\(spec.sizeDescription)). Voice runs this model locally on your Mac — your audio never leaves it."
        statusLabel?.textColor = .secondaryLabelColor
        statusLabel?.stringValue = "Starting download..."
        progressBar?.doubleValue = 0
        retryButton?.removeFromSuperview()
        retryButton = nil

        try? FileManager.default.createDirectory(atPath: ModelSpec.modelDirectory, withIntermediateDirectories: true)
        if session == nil {
            session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        }
        session?.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (self.current?.bytes ?? 0)
            guard total > 0 else { return }
            let pct = Double(totalBytesWritten) / Double(total) * 100
            self.progressBar?.doubleValue = pct
            self.statusLabel?.stringValue = String(format: "%.0f / %.0f MB (%.0f%%)",
                                                   Double(totalBytesWritten) / 1_048_576, Double(total) / 1_048_576, pct)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns, so move it now
        // and verify afterwards.
        guard let spec = DispatchQueue.main.sync(execute: { current }) else { return }
        let partial = spec.downloadPath + ".partial"
        try? FileManager.default.removeItem(atPath: partial)
        do {
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: partial))
        } catch {
            fail("Error: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async { self.statusLabel?.stringValue = "Verifying..." }
        guard sha256Hex(ofFileAt: partial) == spec.sha256 else {
            try? FileManager.default.removeItem(atPath: partial)
            NSLog("Voice: checksum mismatch for %@", spec.fileName)
            fail("Download was corrupted — please retry")
            return
        }
        do {
            try? FileManager.default.removeItem(atPath: spec.downloadPath)
            try FileManager.default.moveItem(atPath: partial, toPath: spec.downloadPath)
        } catch {
            fail("Error: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async {
            self.queue.removeFirst()
            if self.queue.isEmpty {
                self.finish()
            } else {
                self.startNext()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        fail("Download failed: \(error.localizedDescription)")
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.statusLabel?.stringValue = message
            self.statusLabel?.textColor = .systemRed
            guard self.retryButton == nil else { return }
            let retry = NSButton(frame: NSRect(x: 290, y: 14, width: 100, height: 24))
            retry.title = "Retry"
            retry.bezelStyle = .rounded
            retry.target = self
            retry.action = #selector(self.retryDownload)
            self.window?.contentView?.addSubview(retry)
            self.retryButton = retry
        }
    }

    private func finish() {
        statusLabel?.stringValue = "Download complete!"
        progressBar?.doubleValue = 100
        // Brief pause so user sees "complete", then close
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.window?.close()
            self.window = nil
            // Revert to accessory if onboarding is done
            if Settings.shared.onboardingComplete {
                NSApp.setActivationPolicy(.accessory)
            }
            let done = self.completions
            self.completions = []
            done.forEach { $0() }
        }
    }

    @objc private func retryDownload() {
        startNext()
    }
}

// A single checklist row: status dot, title, subtitle, and an action button
// that hides once the item is satisfied. `refresh()` re-reads live state.
private final class SetupRow: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let pendingSubtitle: String
    private let doneSubtitle: String
    let isDone: () -> Bool
    private let action: () -> Void

    init(title: String, subtitle: String, doneSubtitle: String, buttonTitle: String,
         isDone: @escaping () -> Bool, action: @escaping () -> Void) {
        self.pendingSubtitle = subtitle
        self.doneSubtitle = doneSubtitle
        self.isDone = isDone
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 52))

        iconView.frame = NSRect(x: 4, y: 15, width: 24, height: 24)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = NSRect(x: 40, y: 27, width: 250, height: 20)
        addSubview(titleLabel)

        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 40, y: 7, width: 270, height: 18)
        addSubview(subtitleLabel)

        actionButton.title = buttonTitle
        actionButton.bezelStyle = .rounded
        actionButton.frame = NSRect(x: 315, y: 12, width: 100, height: 28)
        actionButton.target = self
        actionButton.action = #selector(tap)
        addSubview(actionButton)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap() { action() }

    func refresh() {
        let done = isDone()
        let symbol = done ? "checkmark.circle.fill" : "circle"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = done ? .systemGreen : .tertiaryLabelColor
        subtitleLabel.stringValue = done ? doneSubtitle : pendingSubtitle
        actionButton.isHidden = done
    }
}

// MARK: - Onboarding Wizard

// A short guided setup: welcome, a live permissions checklist that verifies
// each requirement as the user grants it, a mic test, and a usage tour.
class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var currentStep = 0
    private var stepViews: [NSView] = []
    private var testStepView: NSView?
    private var progressDots: [NSView] = []
    private var nextButton: NSButton?
    private var checklistTimer: Timer?
    private var setupRows: [SetupRow] = []
    // True when reopened from the menu on an already-running app, so complete()
    // doesn't start the input monitor / polling a second time.
    private var isRerun = false

    private var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    private var permissionsSatisfied: Bool { AXIsProcessTrusted() && micAuthorized }

    func show(rerun: Bool = false) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        isRerun = rerun
        // Show Dock icon during onboarding so the window is discoverable
        NSApp.setActivationPolicy(.regular)
        let w = createWindow()
        window = w
        showStep(0)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: isRerun ? [.titled, .closable] : [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = isRerun ? "Voice Setup" : "Welcome to Voice"
        w.center()
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.level = .floating

        guard let contentView = w.contentView else { return w }

        let welcomeStep = createWelcomeStep(in: contentView)
        let permissionsStep = createPermissionsStep(in: contentView)
        let testStep = createTestStep(in: contentView)
        let tourStep = createTourStep(in: contentView)
        testStepView = testStep

        stepViews = [welcomeStep, permissionsStep, testStep, tourStep]
        for sv in stepViews {
            sv.isHidden = true
            contentView.addSubview(sv)
        }

        // Progress dots at bottom center
        let stepCount = stepViews.count
        let dotContainer = NSView(frame: NSRect(x: 160, y: 16, width: 160, height: 16))
        let dotSize: CGFloat = 8
        let dotSpacing: CGFloat = 20
        let totalDotWidth = CGFloat(stepCount) * dotSize + CGFloat(stepCount - 1) * (dotSpacing - dotSize)
        let startX = (160 - totalDotWidth) / 2
        for i in 0..<stepCount {
            let dot = NSView(frame: NSRect(x: startX + CGFloat(i) * dotSpacing, y: 4, width: dotSize, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = dotSize / 2
            dot.layer?.backgroundColor = NSColor.lightGray.cgColor
            dotContainer.addSubview(dot)
            progressDots.append(dot)
        }
        contentView.addSubview(dotContainer)

        let btn = NSButton(frame: NSRect(x: 360, y: 16, width: 100, height: 32))
        btn.title = "Get Started"
        btn.bezelStyle = .rounded
        btn.keyEquivalent = "\r"
        btn.target = self
        btn.action = #selector(nextStep)
        contentView.addSubview(btn)
        nextButton = btn

        return w
    }

    private func showStep(_ step: Int) {
        currentStep = step
        for (i, sv) in stepViews.enumerated() { sv.isHidden = (i != step) }
        for (i, dot) in progressDots.enumerated() {
            dot.layer?.backgroundColor = (i == step)
                ? NSColor.controlAccentColor.cgColor
                : NSColor.lightGray.cgColor
        }

        // Only the permissions step needs live polling.
        if step == 1 { startChecklistPolling() } else { stopChecklistPolling() }

        switch step {
        case 0:
            nextButton?.title = "Get Started"
            nextButton?.isEnabled = true
        case 1:
            nextButton?.title = "Continue"
            refreshChecklist()
        case 2:
            nextButton?.title = "Next"
            nextButton?.isEnabled = true
        case 3:
            nextButton?.title = "Done"
            nextButton?.isEnabled = true
        default:
            break
        }
    }

    @objc private func nextStep() {
        let next = currentStep + 1
        if next >= stepViews.count { complete() } else { showStep(next) }
    }

    private func complete() {
        stopChecklistPolling()
        Settings.shared.onboardingComplete = true
        window?.close()
        window = nil
        NSApp.setActivationPolicy(.accessory)
        // On first-run completion, start the services that were deferred during
        // onboarding. On a menu-triggered rerun they're already running.
        if !isRerun, let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.startAccessibilityPolling()
            _ = appDelegate.inputMonitor.start()
        }
        isRerun = false
    }

    // MARK: - Permissions checklist

    private func createPermissionsStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        let title = NSTextField(labelWithString: "Set Up Voice")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 40, y: 258, width: 400, height: 30)
        title.alignment = .center
        view.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Voice checks each item off as you enable it. Everything runs locally on your Mac.")
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 40, y: 222, width: 400, height: 34)
        subtitle.alignment = .center
        view.addSubview(subtitle)

        let accessibility = SetupRow(
            title: "Accessibility",
            subtitle: "Lets Voice detect your hotkey.",
            doneSubtitle: "Enabled — Voice can detect your hotkey.",
            buttonTitle: "Enable",
            isDone: { AXIsProcessTrusted() },
            action: {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })

        let microphone = SetupRow(
            title: "Microphone",
            subtitle: "Lets Voice record your speech.",
            doneSubtitle: "Enabled — your audio stays on this Mac.",
            buttonTitle: "Enable",
            isDone: { [weak self] in self?.micAuthorized ?? false },
            action: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                default:
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
            })

        let model = Settings.shared.speechModel
        let speechModel = SetupRow(
            title: "Speech model",
            subtitle: "\(model.displayName) · \(model.sizeDescription).",
            doneSubtitle: "Downloaded and verified.",
            buttonTitle: "Download",
            isDone: { Settings.shared.speechModel.isInstalled },
            action: {
                ModelDownloadWindowController.shared.ensureModels([Settings.shared.speechModel]) {}
            })

        setupRows = [accessibility, microphone, speechModel]
        var y: CGFloat = 160
        for row in setupRows {
            row.frame = NSRect(x: 30, y: y, width: 420, height: 52)
            view.addSubview(row)
            y -= 56
        }

        let note = NSTextField(wrappingLabelWithString: "The speech model isn't required to continue — Voice downloads it automatically the first time you dictate.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 40, y: 4, width: 400, height: 34)
        note.alignment = .center
        view.addSubview(note)

        return view
    }

    private func startChecklistPolling() {
        guard checklistTimer == nil else { return }
        checklistTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshChecklist()
        }
    }

    private func stopChecklistPolling() {
        checklistTimer?.invalidate()
        checklistTimer = nil
    }

    private func refreshChecklist() {
        for row in setupRows { row.refresh() }
        // Continue is gated on the two permissions; the model is optional.
        nextButton?.isEnabled = permissionsSatisfied
    }

    // MARK: - Step Builders

    private func createWelcomeStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        let title = NSTextField(labelWithString: "Welcome to Voice")
        title.font = NSFont.boldSystemFont(ofSize: 22)
        title.frame = NSRect(x: 40, y: 210, width: 400, height: 34)
        title.alignment = .center
        view.addSubview(title)

        let tagline = NSTextField(wrappingLabelWithString: "Hold fn, speak, and release. Your words appear wherever your cursor is — transcribed and cleaned up entirely on your Mac.")
        tagline.font = NSFont.systemFont(ofSize: 14)
        tagline.textColor = .secondaryLabelColor
        tagline.frame = NSRect(x: 50, y: 130, width: 380, height: 70)
        tagline.alignment = .center
        view.addSubview(tagline)

        let privacy = NSTextField(wrappingLabelWithString: "No cloud, no accounts, no data collection. This quick setup takes about a minute.")
        privacy.font = NSFont.systemFont(ofSize: 12)
        privacy.textColor = .tertiaryLabelColor
        privacy.frame = NSRect(x: 50, y: 80, width: 380, height: 40)
        privacy.alignment = .center
        view.addSubview(privacy)

        return view
    }

    private func createTestStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        let title = NSTextField(labelWithString: "Test Your Setup")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 40, y: 240, width: 400, height: 30)
        title.alignment = .center
        view.addSubview(title)

        let instruction = NSTextField(wrappingLabelWithString: "Press the button below and say a few words. We'll transcribe them to confirm everything works.")
        instruction.font = NSFont.systemFont(ofSize: 14)
        instruction.textColor = .secondaryLabelColor
        instruction.frame = NSRect(x: 40, y: 170, width: 400, height: 65)
        instruction.alignment = .center
        view.addSubview(instruction)

        let testBtn = NSButton(frame: NSRect(x: 175, y: 125, width: 130, height: 32))
        testBtn.title = "Start Test"
        testBtn.bezelStyle = .rounded
        testBtn.target = self
        testBtn.action = #selector(startTestRecording)
        testBtn.identifier = NSUserInterfaceItemIdentifier("testBtn")
        view.addSubview(testBtn)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 40, y: 90, width: 400, height: 28)
        statusLabel.alignment = .center
        statusLabel.identifier = NSUserInterfaceItemIdentifier("testStatusLabel")
        view.addSubview(statusLabel)

        let resultField = NSTextField(wrappingLabelWithString: "")
        resultField.font = NSFont.systemFont(ofSize: 13)
        resultField.textColor = .labelColor
        resultField.frame = NSRect(x: 40, y: 50, width: 400, height: 36)
        resultField.alignment = .center
        resultField.identifier = NSUserInterfaceItemIdentifier("testResultField")
        view.addSubview(resultField)

        return view
    }

    private func createTourStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        let title = NSTextField(labelWithString: "How to Use Voice")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 40, y: 250, width: 400, height: 30)
        title.alignment = .center
        view.addSubview(title)

        let tips: [(String, String)] = [
            ("fn", "Hold fn to record, release to transcribe"),
            ("waveform.path", "A waveform overlay appears while recording"),
            ("menubar.rectangle", "Look for the Voice icon in your menu bar"),
            ("gear", "Click the menu bar icon for settings and hotkey options"),
            ("keyboard", "Double-tap fn for hands-free mode (tap again to stop)")
        ]

        var y = 220
        for (iconName, text) in tips {
            let iconView = NSImageView(frame: NSRect(x: 50, y: y - 4, width: 20, height: 20))
            if iconName == "fn" {
                let label = NSTextField(labelWithString: "fn")
                label.font = NSFont.boldSystemFont(ofSize: 11)
                label.textColor = .controlAccentColor
                label.frame = NSRect(x: 50, y: y - 2, width: 20, height: 18)
                label.alignment = .center
                view.addSubview(label)
            } else if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                iconView.image = img
                iconView.contentTintColor = .controlAccentColor
            }
            iconView.imageScaling = .scaleProportionallyUpOrDown
            view.addSubview(iconView)

            let tipLabel = NSTextField(labelWithString: text)
            tipLabel.font = NSFont.systemFont(ofSize: 13)
            tipLabel.textColor = .secondaryLabelColor
            tipLabel.frame = NSRect(x: 80, y: y - 2, width: 360, height: 20)
            view.addSubview(tipLabel)

            y -= 34
        }

        let footer = NSTextField(labelWithString: "Voice lives in your menu bar — no Dock icon needed.")
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.frame = NSRect(x: 40, y: 30, width: 400, height: 18)
        footer.alignment = .center
        view.addSubview(footer)

        return view
    }

    // MARK: - Mic Test

    @objc private func startTestRecording() {
        guard let stepView = testStepView else { return }

        for subview in stepView.subviews {
            if let label = subview as? NSTextField, label.identifier?.rawValue == "testStatusLabel" {
                label.stringValue = "Listening..."
                label.textColor = .secondaryLabelColor
            }
            if let label = subview as? NSTextField, label.identifier?.rawValue == "testResultField" {
                label.stringValue = ""
            }
            if let btn = subview as? NSButton, btn.identifier?.rawValue == "testBtn" {
                btn.isEnabled = false
            }
        }
        nextButton?.isEnabled = false

        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.startRecording()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            for subview in stepView.subviews {
                if let label = subview as? NSTextField, label.identifier?.rawValue == "testStatusLabel" {
                    label.stringValue = "Transcribing..."
                }
            }
            delegate.stopRecording()

            var checkCount = 0
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                checkCount += 1
                guard let self = self else { timer.invalidate(); return }
                if delegate.appState == .idle, let transcription = delegate.lastTranscription {
                    timer.invalidate()
                    self.showTestResult(transcription: transcription, stepView: stepView)
                } else if checkCount > 20 {
                    timer.invalidate()
                    self.showTestResult(transcription: nil, stepView: stepView)
                }
            }
        }
    }

    private func showTestResult(transcription: String?, stepView: NSView) {
        for subview in stepView.subviews {
            if let label = subview as? NSTextField, label.identifier?.rawValue == "testStatusLabel" {
                if let text = transcription, !text.isEmpty {
                    label.stringValue = "Everything works! You're all set."
                    label.textColor = .systemGreen
                } else {
                    label.stringValue = "Nothing was transcribed. You can try again or finish setup."
                    label.textColor = .systemOrange
                }
            }
            if let label = subview as? NSTextField, label.identifier?.rawValue == "testResultField" {
                label.stringValue = transcription ?? ""
            }
            if let btn = subview as? NSButton, btn.identifier?.rawValue == "testBtn" {
                btn.isEnabled = true
            }
        }
        nextButton?.isEnabled = true
    }
}

// MARK: - Settings Window

class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Voice Settings"
        w.center()
        w.isReleasedWhenClosed = false
        w.isRestorable = false

        let vc = SettingsViewController()
        w.contentViewController = vc
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var tabView: NSTabView!

    // General tab controls
    private var hotkeyPopup: NSPopUpButton!
    private var soundsCheckbox: NSButton!
    private var autoStartCheckbox: NSButton!
    private var popoStepper: NSStepper!
    private var popoLabel: NSTextField!
    private var clipboardCheckbox: NSButton!

    // AI tab controls
    private var aiEnabledCheckbox: NSButton!
    private var aiCustomPromptField: NSTextField!
    private var customVocabularyField: NSTextField!

    // Audio tab controls
    private var micPopup: NSPopUpButton!
    private var micStatusLabel: NSTextField!
    private var overlayEnabledCheckbox: NSButton!
    private var overlayAppNameCheckbox: NSButton!
    private var overlayAppIconCheckbox: NSButton!
    private var overlayBgSlider: NSSlider!
    private var overlayBgLabel: NSTextField!
    private var overlayTimerCheckbox: NSButton!
    private var overlayFontSizeSegment: NSSegmentedControl!
    private var overlayPreview: OverlayPreviewView!
    private var sensitivitySlider: NSSlider!
    private var sensitivityLabel: NSTextField!

    // Transcription tab controls
    private var speechModelPopup: NSPopUpButton!
    private var languagePopup: NSPopUpButton!
    private var downloadButton: NSButton!
    private var downloadStatusLabel: NSTextField!
    private var saveTranscriptsCheckbox: NSButton!
    private var transcriptDirLabel: NSTextField!
    private var transcriptSearchField: NSSearchField!
    private var transcriptTableView: NSTableView!
    private var transcriptResults: [(date: Date, text: String, path: String)] = []
    private var transcriptCountLabel: NSTextField!

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 420))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Sticky footer, shown under every tab: a separator and the always-
        // visible Reset to Defaults button.
        let footerHeight: CGFloat = 44
        let separator = NSBox(frame: NSRect(x: 0, y: footerHeight, width: view.bounds.width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(separator)

        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        resetBtn.frame = NSRect(x: view.bounds.width - 12 - 150, y: 8, width: 150, height: 28)
        resetBtn.bezelStyle = .rounded
        resetBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(resetBtn)

        let footerNote = NSTextField(labelWithString: "Restores all preferences to their defaults.")
        footerNote.font = NSFont.systemFont(ofSize: 11)
        footerNote.textColor = .tertiaryLabelColor
        footerNote.frame = NSRect(x: 14, y: 14, width: 280, height: 16)
        footerNote.autoresizingMask = [.maxYMargin]
        view.addSubview(footerNote)

        tabView = NSTabView(frame: NSRect(x: 12, y: footerHeight + 8,
                                          width: view.bounds.width - 24,
                                          height: view.bounds.height - footerHeight - 20))
        tabView.autoresizingMask = [.width, .height]
        view.addSubview(tabView)
        rebuildTabs(selectedIndex: 0)

        // Listen for audio device changes (live mic list updates)
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &propAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshMicList()
        }
    }

    // Rebuilds every tab from current settings. Used at load and after a reset,
    // so all controls reflect the same source of truth rather than a hand-kept
    // list that can drift from the real defaults.
    private func rebuildTabs(selectedIndex: Int) {
        for item in tabView.tabViewItems { tabView.removeTabViewItem(item) }
        tabView.addTabViewItem(makeAudioTab())
        tabView.addTabViewItem(makeGeneralTab())
        tabView.addTabViewItem(makeAITab())
        tabView.addTabViewItem(makeTranscriptionTab())
        let count = tabView.numberOfTabViewItems
        if count > 0 { tabView.selectTabViewItem(at: max(0, min(selectedIndex, count - 1))) }
    }

    // MARK: - General Tab

    private func makeGeneralTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "general")
        item.label = "General"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        var y: CGFloat = 260

        // Push-to-talk key
        addLabel("Push-to-talk key:", at: NSPoint(x: 20, y: y), in: container)
        hotkeyPopup = NSPopUpButton(frame: NSRect(x: 180, y: y - 2, width: 200, height: 26), pullsDown: false)
        for opt in hotkeyOptions {
            hotkeyPopup.addItem(withTitle: opt.name)
        }
        hotkeyPopup.selectItem(at: Settings.shared.hotkeyIndex)
        hotkeyPopup.target = self
        hotkeyPopup.action = #selector(hotkeyChanged)
        container.addSubview(hotkeyPopup)

        y -= 40

        // Sounds
        soundsCheckbox = NSButton(checkboxWithTitle: "Sounds", target: self, action: #selector(soundsChanged))
        soundsCheckbox.frame = NSRect(x: 20, y: y, width: 200, height: 22)
        soundsCheckbox.state = Settings.shared.soundsEnabled ? .on : .off
        container.addSubview(soundsCheckbox)

        y -= 34

        // Auto-start on login
        autoStartCheckbox = NSButton(checkboxWithTitle: "Auto-start on login", target: self, action: #selector(autoStartChanged))
        autoStartCheckbox.frame = NSRect(x: 20, y: y, width: 200, height: 22)
        autoStartCheckbox.state = Settings.shared.autoStartOnLogin ? .on : .off
        container.addSubview(autoStartCheckbox)

        y -= 40

        // POPO timeout
        addLabel("Hands-free timeout (min):", at: NSPoint(x: 20, y: y), in: container)
        popoLabel = NSTextField(labelWithString: "\(Settings.shared.popoTimeout)")
        popoLabel.frame = NSRect(x: 200, y: y, width: 30, height: 22)
        popoLabel.alignment = .center
        container.addSubview(popoLabel)

        popoStepper = NSStepper(frame: NSRect(x: 232, y: y, width: 19, height: 22))
        popoStepper.minValue = 1
        popoStepper.maxValue = 30
        popoStepper.integerValue = Settings.shared.popoTimeout
        popoStepper.target = self
        popoStepper.action = #selector(popoTimeoutChanged)
        container.addSubview(popoStepper)

        y -= 40

        // Clipboard restore
        clipboardCheckbox = NSButton(checkboxWithTitle: "Restore clipboard after paste", target: self, action: #selector(clipboardChanged))
        clipboardCheckbox.frame = NSRect(x: 20, y: y, width: 280, height: 22)
        clipboardCheckbox.state = Settings.shared.clipboardRestore ? .on : .off
        container.addSubview(clipboardCheckbox)

        item.view = container
        return item
    }

    // MARK: - Audio Tab

    private func makeAudioTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "audio")
        item.label = "Audio"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 350))

        var y: CGFloat = 280

        // Microphone selector
        addLabel("Microphone:", at: NSPoint(x: 20, y: y), in: container)
        micPopup = NSPopUpButton(frame: NSRect(x: 140, y: y - 2, width: 280, height: 26), pullsDown: false)
        micPopup.target = self
        micPopup.action = #selector(micChanged)
        container.addSubview(micPopup)

        y -= 22
        micStatusLabel = NSTextField(labelWithString: "")
        micStatusLabel.frame = NSRect(x: 140, y: y, width: 280, height: 16)
        micStatusLabel.font = NSFont.systemFont(ofSize: 10)
        micStatusLabel.textColor = .secondaryLabelColor
        container.addSubview(micStatusLabel)

        refreshMicList()  // must be after micStatusLabel is created

        y -= 32

        // Overlay section header
        overlayEnabledCheckbox = NSButton(checkboxWithTitle: "Show overlay", target: self, action: #selector(overlaySettingChanged))
        overlayEnabledCheckbox.frame = NSRect(x: 20, y: y, width: 130, height: 22)
        overlayEnabledCheckbox.state = Settings.shared.overlayEnabled ? .on : .off
        container.addSubview(overlayEnabledCheckbox)
        y -= 26

        // Overlay toggles row
        overlayAppNameCheckbox = NSButton(checkboxWithTitle: "App name", target: self, action: #selector(overlaySettingChanged))
        overlayAppNameCheckbox.frame = NSRect(x: 40, y: y, width: 95, height: 22)
        overlayAppNameCheckbox.state = Settings.shared.overlayShowAppName ? .on : .off
        container.addSubview(overlayAppNameCheckbox)

        overlayAppIconCheckbox = NSButton(checkboxWithTitle: "App icon", target: self, action: #selector(overlaySettingChanged))
        overlayAppIconCheckbox.frame = NSRect(x: 140, y: y, width: 90, height: 22)
        overlayAppIconCheckbox.state = Settings.shared.overlayShowAppIcon ? .on : .off
        container.addSubview(overlayAppIconCheckbox)

        overlayTimerCheckbox = NSButton(checkboxWithTitle: "Timer", target: self, action: #selector(overlaySettingChanged))
        overlayTimerCheckbox.frame = NSRect(x: 235, y: y, width: 70, height: 22)
        overlayTimerCheckbox.state = Settings.shared.overlayShowTimer ? .on : .off
        container.addSubview(overlayTimerCheckbox)
        y -= 26

        // Slider rows
        addLabel("Background:", at: NSPoint(x: 40, y: y + 2), in: container)
        overlayBgSlider = NSSlider(value: Double(Settings.shared.overlayBackgroundOpacity * 100), minValue: 0, maxValue: 100, target: self, action: #selector(overlayBgChanged))
        overlayBgSlider.frame = NSRect(x: 140, y: y, width: 120, height: 22)
        container.addSubview(overlayBgSlider)
        overlayBgLabel = NSTextField(labelWithString: "\(Int(Settings.shared.overlayBackgroundOpacity * 100))%")
        overlayBgLabel.frame = NSRect(x: 265, y: y + 2, width: 40, height: 18)
        overlayBgLabel.font = NSFont.systemFont(ofSize: 11)
        overlayBgLabel.textColor = .secondaryLabelColor
        container.addSubview(overlayBgLabel)
        y -= 24

        addLabel("Font size:", at: NSPoint(x: 40, y: y + 2), in: container)
        overlayFontSizeSegment = NSSegmentedControl(labels: ["Small", "Medium", "Large"], trackingMode: .selectOne, target: self, action: #selector(overlayFontSizeChanged))
        overlayFontSizeSegment.frame = NSRect(x: 140, y: y, width: 180, height: 22)
        // Map current size to segment: Small=10, Medium=13, Large=16
        let currentSize = Settings.shared.overlayFontSize
        if currentSize <= 11 { overlayFontSizeSegment.selectedSegment = 0 }
        else if currentSize <= 14 { overlayFontSizeSegment.selectedSegment = 1 }
        else { overlayFontSizeSegment.selectedSegment = 2 }
        container.addSubview(overlayFontSizeSegment)
        y -= 24

        addLabel("Waveform:", at: NSPoint(x: 40, y: y + 2), in: container)
        sensitivitySlider = NSSlider(value: Double(Settings.shared.overlaySensitivity), minValue: 5, maxValue: 80, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.frame = NSRect(x: 140, y: y, width: 120, height: 22)
        // Display only: scales the overlay bars. Does not change mic gain or transcription.
        sensitivitySlider.toolTip = "How tall the overlay waveform bounces (shown live below). Visual only \u{2014} doesn't affect recording or accuracy."
        container.addSubview(sensitivitySlider)
        sensitivityLabel = NSTextField(labelWithString: "\(Int(Settings.shared.overlaySensitivity))x")
        sensitivityLabel.frame = NSRect(x: 265, y: y + 2, width: 40, height: 18)
        sensitivityLabel.font = NSFont.systemFont(ofSize: 11)
        sensitivityLabel.textColor = .secondaryLabelColor
        container.addSubview(sensitivityLabel)
        y -= 30

        // Preview — auto-sized to match content
        let previewFontSize = Settings.shared.overlayFontSize
        let previewH = max(previewFontSize * 2.4, 28)
        overlayPreview = OverlayPreviewView(frame: NSRect(x: 0, y: y - previewH, width: 200, height: previewH))
        overlayPreview.fontSize = previewFontSize
        container.addSubview(overlayPreview)
        overlayPreview.resizeToFit()

        item.view = container
        return item
    }

    private func refreshMicList() {
        guard micPopup != nil else { return }
        micPopup.removeAllItems()
        micPopup.addItem(withTitle: "System Default")
        let devices = listInputDevices()
        for device in devices {
            micPopup.addItem(withTitle: device.name)
            micPopup.lastItem?.representedObject = device.uid as NSString
        }
        // Select current saved device
        let savedUID = Settings.shared.micDeviceUID
        if savedUID.isEmpty {
            micPopup.selectItem(at: 0)
        } else {
            if let idx = devices.firstIndex(where: { $0.uid == savedUID }) {
                micPopup.selectItem(at: idx + 1)  // +1 for "System Default"
            } else {
                micPopup.selectItem(at: 0)
                micStatusLabel.stringValue = "Preferred device not available"
                micStatusLabel.textColor = .systemOrange
            }
        }
    }

    @objc private func micChanged() {
        if micPopup.indexOfSelectedItem == 0 {
            Settings.shared.micDeviceUID = ""
        } else if let uid = micPopup.selectedItem?.representedObject as? String {
            Settings.shared.micDeviceUID = uid
        }
        micStatusLabel.stringValue = ""
        micStatusLabel.textColor = .secondaryLabelColor
    }

    @objc private func overlaySettingChanged() {
        Settings.shared.overlayEnabled = overlayEnabledCheckbox.state == .on
        Settings.shared.overlayShowAppName = overlayAppNameCheckbox.state == .on
        Settings.shared.overlayShowAppIcon = overlayAppIconCheckbox.state == .on
        // overlayBgSlider handled by its own action
        Settings.shared.overlayShowTimer = overlayTimerCheckbox.state == .on
        overlayPreview.resizeToFit()
    }

    @objc private func overlayBgChanged() {
        let pct = Int(overlayBgSlider.doubleValue)
        Settings.shared.overlayBackgroundOpacity = CGFloat(pct) / 100.0
        overlayBgLabel.stringValue = "\(pct)%"
        overlayPreview.needsDisplay = true
    }

    @objc private func sensitivityChanged() {
        let val = Int(sensitivitySlider.doubleValue)
        Settings.shared.overlaySensitivity = Float(val)
        sensitivityLabel.stringValue = "\(val)x"
        overlayPreview?.needsDisplay = true
    }

    @objc private func overlayFontSizeChanged() {
        let sizes: [CGFloat] = [10, 13, 16]  // Small, Medium, Large
        let idx = overlayFontSizeSegment.selectedSegment
        let size = sizes[idx]
        Settings.shared.overlayFontSize = size
        overlayPreview.fontSize = size
        overlayPreview.resizeToFit()
    }

    // MARK: - AI Tab

    private func makeAITab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "ai")
        item.label = "AI"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 320))

        // The tab content area is ~320pt tall and AppKit clips from the top,
        // so everything must sit below ~306 like the other tabs.
        var y: CGFloat = 284

        // Local AI text cleanup toggle
        aiEnabledCheckbox = NSButton(checkboxWithTitle: "AI text cleanup", target: self, action: #selector(aiEnabledChanged))
        aiEnabledCheckbox.frame = NSRect(x: 20, y: y, width: 220, height: 22)
        aiEnabledCheckbox.state = Settings.shared.aiEnabled ? .on : .off
        container.addSubview(aiEnabledCheckbox)

        y -= 4

        // Description
        let desc = NSTextField(wrappingLabelWithString: "Cleans up grammar, removes filler words (um, uh, like), and handles corrections. Runs entirely on your Mac — nothing is sent to the cloud.")
        desc.frame = NSRect(x: 38, y: y - 36, width: 392, height: 40)
        desc.textColor = .secondaryLabelColor
        desc.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(desc)

        y -= 70

        // Custom prompt instructions
        addLabel("Custom instructions:", at: NSPoint(x: 20, y: y), in: container)
        y -= 4
        let promptHint = NSTextField(labelWithString: "e.g. \"Never change proper nouns like Claude or Gemini\"")
        promptHint.frame = NSRect(x: 20, y: y - 16, width: 410, height: 14)
        promptHint.textColor = .tertiaryLabelColor
        promptHint.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(promptHint)

        y -= 28

        aiCustomPromptField = NSTextField(string: Settings.shared.aiCustomPrompt)
        aiCustomPromptField.frame = NSRect(x: 20, y: y - 34, width: 410, height: 44)
        aiCustomPromptField.placeholderString = "Add custom instructions for AI text cleanup..."
        aiCustomPromptField.font = NSFont.systemFont(ofSize: 12)
        aiCustomPromptField.usesSingleLineMode = false
        aiCustomPromptField.cell?.wraps = true
        aiCustomPromptField.cell?.isScrollable = true
        aiCustomPromptField.delegate = self
        container.addSubview(aiCustomPromptField)

        y -= 58

        // Custom vocabulary — restores spelling for every model; Whisper also
        // uses it to bias recognition
        addLabel("Custom vocabulary:", at: NSPoint(x: 20, y: y), in: container)
        y -= 4
        let vocabHint = NSTextField(labelWithString: "Names, acronyms, technical terms — fixes their spelling in your text")
        vocabHint.frame = NSRect(x: 20, y: y - 16, width: 410, height: 14)
        vocabHint.textColor = .tertiaryLabelColor
        vocabHint.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(vocabHint)

        y -= 28

        customVocabularyField = NSTextField(string: Settings.shared.customVocabulary)
        customVocabularyField.frame = NSRect(x: 20, y: y - 34, width: 410, height: 44)
        customVocabularyField.placeholderString = "Kubernetes, kubectl, faradaysoft, GGUF, whisper.cpp, ..."
        customVocabularyField.font = NSFont.systemFont(ofSize: 12)
        customVocabularyField.usesSingleLineMode = false
        customVocabularyField.cell?.wraps = true
        customVocabularyField.cell?.isScrollable = true
        customVocabularyField.delegate = self
        container.addSubview(customVocabularyField)

        item.view = container
        return item
    }

    // MARK: - Transcription Tab

    private func makeTranscriptionTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "transcription")
        item.label = "Transcription"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 350))

        var y: CGFloat = 282

        // Speech model — compact row
        addLabel("Model:", at: NSPoint(x: 20, y: y), in: container)
        speechModelPopup = NSPopUpButton(frame: NSRect(x: 75, y: y - 2, width: 200, height: 24), pullsDown: false)
        for model in ModelCatalog.speechModels {
            speechModelPopup.addItem(withTitle: model.displayName)
            speechModelPopup.lastItem?.representedObject = model.id
        }
        speechModelPopup.selectItem(at: ModelCatalog.speechModels.firstIndex { $0.id == Settings.shared.speechModelID } ?? 0)
        speechModelPopup.target = self
        speechModelPopup.action = #selector(speechModelChanged)
        container.addSubview(speechModelPopup)

        downloadButton = NSButton(title: "Download", target: self, action: #selector(downloadModel))
        downloadButton.frame = NSRect(x: 280, y: y - 2, width: 75, height: 24)
        downloadButton.bezelStyle = .rounded
        downloadButton.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(downloadButton)

        downloadStatusLabel = NSTextField(labelWithString: "")
        downloadStatusLabel.frame = NSRect(x: 358, y: y + 2, width: 72, height: 14)
        downloadStatusLabel.textColor = .systemGreen
        downloadStatusLabel.font = NSFont.systemFont(ofSize: 9)
        downloadStatusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(downloadStatusLabel)
        updateDownloadButton()

        y -= 30

        // Language — Parakeet is multilingual; this steers Whisper and gates
        // the English-only text cleanup.
        addLabel("Language:", at: NSPoint(x: 20, y: y), in: container)
        languagePopup = NSPopUpButton(frame: NSRect(x: 95, y: y - 2, width: 180, height: 24), pullsDown: false)
        for lang in ModelCatalog.languages {
            languagePopup.addItem(withTitle: lang.name)
            languagePopup.lastItem?.representedObject = lang.code
        }
        languagePopup.selectItem(at: ModelCatalog.languages.firstIndex { $0.code == Settings.shared.transcriptionLanguage } ?? 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        container.addSubview(languagePopup)

        y -= 26

        // Save transcripts — single compact row
        saveTranscriptsCheckbox = NSButton(checkboxWithTitle: "Save transcripts", target: self, action: #selector(saveTranscriptsChanged))
        saveTranscriptsCheckbox.frame = NSRect(x: 20, y: y, width: 130, height: 20)
        saveTranscriptsCheckbox.font = NSFont.systemFont(ofSize: 11)
        saveTranscriptsCheckbox.state = Settings.shared.saveTranscripts ? .on : .off
        container.addSubview(saveTranscriptsCheckbox)

        transcriptDirLabel = NSTextField(labelWithString: "")
        let dirPath = Settings.shared.transcriptDirectory
        let shortPath = (dirPath as NSString).lastPathComponent
        transcriptDirLabel.stringValue = "~/.../" + shortPath
        transcriptDirLabel.frame = NSRect(x: 148, y: y + 2, width: 120, height: 14)
        transcriptDirLabel.font = NSFont.systemFont(ofSize: 9)
        transcriptDirLabel.textColor = .tertiaryLabelColor
        transcriptDirLabel.lineBreakMode = .byTruncatingHead
        container.addSubview(transcriptDirLabel)

        let dirButton = NSButton(title: "Change", target: self, action: #selector(chooseTranscriptDir))
        dirButton.frame = NSRect(x: 280, y: y, width: 60, height: 20)
        dirButton.bezelStyle = .rounded
        dirButton.controlSize = .small
        dirButton.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(dirButton)

        let openButton = NSButton(title: "Open", target: self, action: #selector(openTranscriptDir))
        openButton.frame = NSRect(x: 344, y: y, width: 50, height: 20)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = NSFont.systemFont(ofSize: 10)
        container.addSubview(openButton)

        y -= 24

        // Search field — live filtering
        transcriptSearchField = NSSearchField(frame: NSRect(x: 20, y: y, width: 350, height: 24))
        transcriptSearchField.placeholderString = "Search transcripts..."
        transcriptSearchField.font = NSFont.systemFont(ofSize: 12)
        transcriptSearchField.delegate = self
        transcriptSearchField.sendsSearchStringImmediately = true
        transcriptSearchField.sendsWholeSearchString = false
        container.addSubview(transcriptSearchField)

        transcriptCountLabel = NSTextField(labelWithString: "")
        transcriptCountLabel.frame = NSRect(x: 374, y: y + 4, width: 56, height: 14)
        transcriptCountLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        transcriptCountLabel.textColor = .tertiaryLabelColor
        transcriptCountLabel.alignment = .right
        container.addSubview(transcriptCountLabel)

        y -= 4

        // Transcript list — single column, custom cell layout
        let tableHeight = y - 6
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 6, width: 410, height: tableHeight))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = false

        transcriptTableView = NSTableView()
        transcriptTableView.dataSource = self
        transcriptTableView.delegate = self
        transcriptTableView.rowHeight = 48
        transcriptTableView.usesAlternatingRowBackgroundColors = false
        transcriptTableView.backgroundColor = .clear
        transcriptTableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        transcriptTableView.headerView = nil
        transcriptTableView.intercellSpacing = NSSize(width: 0, height: 1)
        transcriptTableView.selectionHighlightStyle = .regular
        transcriptTableView.gridStyleMask = .solidHorizontalGridLineMask
        transcriptTableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.3)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        col.width = 406
        transcriptTableView.addTableColumn(col)

        // Double-click to copy
        transcriptTableView.doubleAction = #selector(copyTranscriptRow)
        transcriptTableView.target = self

        scrollView.documentView = transcriptTableView
        container.addSubview(scrollView)

        reloadTranscripts()

        item.view = container
        return item
    }

    // MARK: - Transcript Table Data

    private func reloadTranscripts() {
        let query = transcriptSearchField?.stringValue ?? ""
        transcriptResults = Settings.shared.searchTranscripts(query: query)
        transcriptTableView?.reloadData()
        let count = transcriptResults.count
        if count == 0 {
            transcriptCountLabel?.stringValue = query.isEmpty ? "" : "No results"
        } else {
            transcriptCountLabel?.stringValue = "\(count)"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return transcriptResults.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < transcriptResults.count else { return nil }
        let record = transcriptResults[row]

        // Custom cell: text on top (13pt), date below (10pt gray)
        let cellView = NSView(frame: NSRect(x: 0, y: 0, width: 406, height: 48))

        // Transcript text — primary content
        let textLabel = NSTextField(labelWithString: "")
        let preview = record.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        textLabel.stringValue = preview
        textLabel.font = NSFont.systemFont(ofSize: 13)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.frame = NSRect(x: 8, y: 22, width: 390, height: 20)
        cellView.addSubview(textLabel)

        // Date — secondary, below text
        let dateLabel = NSTextField(labelWithString: "")
        dateLabel.font = NSFont.systemFont(ofSize: 10)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.lineBreakMode = .byClipping
        dateLabel.frame = NSRect(x: 8, y: 5, width: 390, height: 14)

        let formatter = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(record.date) {
            formatter.dateFormat = "'Today at' h:mm a"
        } else if cal.isDateInYesterday(record.date) {
            formatter.dateFormat = "'Yesterday at' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        }
        dateLabel.stringValue = formatter.string(from: record.date)
        cellView.addSubview(dateLabel)

        return cellView
    }

    // Live search — NSSearchFieldDelegate
    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField, field === transcriptSearchField {
            reloadTranscripts()
        }
        if let field = obj.object as? NSTextField, field === aiCustomPromptField {
            Settings.shared.aiCustomPrompt = field.stringValue
        }
        if let field = obj.object as? NSTextField, field === customVocabularyField {
            Settings.shared.customVocabulary = field.stringValue
        }
    }

    @objc private func copyTranscriptRow() {
        let row = transcriptTableView.clickedRow
        guard row >= 0, row < transcriptResults.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptResults[row].text, forType: .string)
        transcriptCountLabel?.stringValue = "Copied!"
        transcriptCountLabel?.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.transcriptCountLabel?.textColor = .tertiaryLabelColor
            self?.reloadTranscripts()
        }
    }

    @objc private func saveTranscriptsChanged() {
        Settings.shared.saveTranscripts = saveTranscriptsCheckbox.state == .on
    }

    @objc private func chooseTranscriptDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Settings.shared.transcriptDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.transcriptDirectory = url.path
            transcriptDirLabel.stringValue = url.path
        }
    }

    @objc private func openTranscriptDir() {
        let dir = Settings.shared.transcriptDirectory
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    // MARK: - Helpers

    @discardableResult
    private func addLabel(_ text: String, at point: NSPoint, in container: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: point.x, y: point.y, width: 160, height: 22)
        container.addSubview(label)
        return label
    }

    private func updateDownloadButton() {
        let exists = Settings.shared.speechModel.isInstalled
        downloadButton.isHidden = exists
        downloadStatusLabel.stringValue = exists ? "Model available" : "Model not downloaded"
        downloadStatusLabel.textColor = exists ? .systemGreen : .systemOrange
    }

    // MARK: - Actions

    @objc private func hotkeyChanged() {
        Settings.shared.hotkeyIndex = hotkeyPopup.indexOfSelectedItem
        // Update the cached hotkey in the input monitor
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.inputMonitor.reloadHotkey()
        }
    }

    @objc private func soundsChanged() {
        Settings.shared.soundsEnabled = soundsCheckbox.state == .on
    }

    @objc private func autoStartChanged() {
        Settings.shared.autoStartOnLogin = autoStartCheckbox.state == .on
    }

    @objc private func popoTimeoutChanged() {
        Settings.shared.popoTimeout = popoStepper.integerValue
        popoLabel.stringValue = "\(popoStepper.integerValue)"
    }

    @objc private func clipboardChanged() {
        Settings.shared.clipboardRestore = clipboardCheckbox.state == .on
    }

    @objc private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset to Defaults?"
        alert.informativeText = "This will reset all settings to their defaults. Your saved transcripts will not be affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selected = tabView.indexOfTabViewItem(tabView.selectedTabViewItem ?? tabView.tabViewItems.first!)
        Settings.shared.resetAll()
        // Rebuild every tab so all controls reflect the restored defaults.
        rebuildTabs(selectedIndex: selected)

        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.inputMonitor.reloadHotkey()
        }
    }

    @objc private func aiEnabledChanged() {
        Settings.shared.aiEnabled = aiEnabledCheckbox.state == .on
        if Settings.shared.aiEnabled {
            ModelDownloadWindowController.shared.ensureModels([ModelCatalog.cleanup]) {}
        }
    }

    @objc private func languageChanged() {
        if let code = languagePopup.selectedItem?.representedObject as? String {
            Settings.shared.transcriptionLanguage = code
        }
    }

    @objc private func speechModelChanged() {
        if let id = speechModelPopup.selectedItem?.representedObject as? String {
            Settings.shared.speechModelID = id
        }
        updateDownloadButton()
    }

    @objc private func downloadModel() {
        downloadButton.isEnabled = false
        ModelDownloadWindowController.shared.ensureModels([Settings.shared.speechModel]) { [weak self] in
            self?.downloadButton.isEnabled = true
            self?.updateDownloadButton()
        }
    }
}

// MARK: - WAV Header Writer

func writeWAVHeader(to handle: FileHandle, dataSize: UInt32) {
    var header = Data()
    // RIFF chunk
    header.append(contentsOf: "RIFF".utf8)
    var chunkSize = UInt32(36 + dataSize).littleEndian
    header.append(Data(bytes: &chunkSize, count: 4))
    header.append(contentsOf: "WAVE".utf8)
    // fmt sub-chunk
    header.append(contentsOf: "fmt ".utf8)
    var subchunk1Size = UInt32(16).littleEndian
    header.append(Data(bytes: &subchunk1Size, count: 4))
    var audioFormat = UInt16(1).littleEndian  // PCM
    header.append(Data(bytes: &audioFormat, count: 2))
    var numChannels = UInt16(1).littleEndian  // mono
    header.append(Data(bytes: &numChannels, count: 2))
    var sampleRate = UInt32(16000).littleEndian
    header.append(Data(bytes: &sampleRate, count: 4))
    var byteRate = UInt32(32000).littleEndian  // 16000 * 1 * 2
    header.append(Data(bytes: &byteRate, count: 4))
    var blockAlign = UInt16(2).littleEndian  // 1 * 2
    header.append(Data(bytes: &blockAlign, count: 2))
    var bitsPerSample = UInt16(16).littleEndian
    header.append(Data(bytes: &bitsPerSample, count: 2))
    // data sub-chunk
    header.append(contentsOf: "data".utf8)
    var dataChunkSize = dataSize.littleEndian
    header.append(Data(bytes: &dataChunkSize, count: 4))
    handle.seek(toFileOffset: 0)
    handle.write(header)
}

// Peak-normalize a 16kHz mono Int16 PCM WAV file in place.
// Raises quiet / mumbled speech to a consistent level before handing it to
// Whisper, which performs dramatically better on normalized input.
// Returns true on success; false leaves the file untouched.
@discardableResult
func normalizeWavFile(at path: String) -> Bool {
    guard var data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          data.count > 44 else { return false }

    let headerSize = 44
    let sampleBytes = data.count - headerSize
    let sampleCount = sampleBytes / 2
    guard sampleCount > 0 else { return false }

    var peak: Int32 = 0
    var rmsAccum: Double = 0
    data.withUnsafeBytes { raw in
        let base = raw.baseAddress!.advanced(by: headerSize).assumingMemoryBound(to: Int16.self)
        for i in 0..<sampleCount {
            let s = Int32(base[i])
            let a = abs(s)
            if a > peak { peak = a }
            rmsAccum += Double(s) * Double(s)
        }
    }

    let rms = sqrt(rmsAccum / Double(sampleCount)) / 32768.0
    // Skip if too quiet overall (likely no speech) — normalizing pure noise
    // just amplifies hiss and tanks whisper accuracy.
    guard rms > 0.003, peak > 0 else { return false }

    // Target -3 dBFS peak (~23170 of 32767). Cap gain at 20x so a single loud
    // sample doesn't prevent quiet speech from being boosted.
    let target: Double = 23170
    var gain = target / Double(peak)
    if gain < 1.0 { return false }   // already loud enough, leave it alone
    if gain > 20.0 { gain = 20.0 }

    data.withUnsafeMutableBytes { raw in
        let base = raw.baseAddress!.advanced(by: headerSize).assumingMemoryBound(to: Int16.self)
        for i in 0..<sampleCount {
            var v = Double(base[i]) * gain
            if v > 32767 { v = 32767 }
            if v < -32768 { v = -32768 }
            base[i] = Int16(v)
        }
    }

    do {
        try data.write(to: URL(fileURLWithPath: path))
        return true
    } catch {
        return false
    }
}

// Build a short initial prompt for Whisper that biases the decoder toward
// the active app's vocabulary — e.g. code terms in Xcode, casual tone in
// Messages. Whisper uses this as prior context without transcribing it.
func whisperContextPrompt(from context: AppContext) -> String {
    var parts: [String] = []
    let app = context.appName.trimmingCharacters(in: .whitespaces)
    if !app.isEmpty && app != "Unknown" {
        parts.append("Dictating into \(app).")
    }
    let title = context.windowTitle.trimmingCharacters(in: .whitespaces)
    if !title.isEmpty {
        // Cap window title length — whisper prompts over ~200 tokens degrade.
        let clipped = title.count > 120 ? String(title.prefix(120)) : title
        parts.append("Window: \(clipped).")
    }
    let vocab = Settings.shared.customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !vocab.isEmpty {
        let clipped = vocab.count > 300 ? String(vocab.prefix(300)) : vocab
        parts.append("Vocabulary: \(clipped).")
    }
    return parts.joined(separator: " ")
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var appState: AppState = .idle
    var audioEngine: AVAudioEngine?
    var isRestartingEngine = false
    var audioFileHandle: FileHandle?
    var audioDataSize: UInt32 = 0
    var currentAudioLevel: Float = 0.0  // Exposed for waveform overlay
    var zeroBufferCount: Int = 0
    var zeroSignalWarningShown: Bool = false
    var audioFile: String?
    var previousApp: NSRunningApplication?  // saved before recording to refocus for paste

    let afplayPath = "/usr/bin/afplay"

    let inputMonitor = InputMonitor()
    let textInjector = TextInjector()
    let overlayWindow = OverlayWindow()

    var popoTimer: Timer?

    var dismissTimer: Timer?
    var lastTranscription: String?

    // Every quit path (menu, relaunch, logout) lands here. Models must be
    // freed before exit or ggml's Metal teardown aborts the process.
    func applicationWillTerminate(_ notification: Notification) {
        SpeechEngine.shared.shutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any windows macOS may have restored despite our early prevention
        for window in NSApp.windows where window.title == "Voice Settings" {
            window.close()
        }

        // Migrate old LaunchAgent bundle ID (com.local.voice -> com.faradaysoft.voice)
        let oldPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.local.voice.plist"
        let newPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.faradaysoft.voice.plist"
        if FileManager.default.fileExists(atPath: oldPlistPath) && !FileManager.default.fileExists(atPath: newPlistPath) {
            NSLog("Voice: migrating LaunchAgent from com.local.voice to com.faradaysoft.voice")
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["unload", oldPlistPath]
            try? unload.run()
            unload.waitUntilExit()
            try? FileManager.default.removeItem(atPath: oldPlistPath)
            // Re-create with new bundle ID if autostart is enabled
            if Settings.shared.autoStartOnLogin {
                Settings.shared.updateLaunchAgent(enabled: true)
            }
        }

        // Prevent duplicate instances — if another Voice is already running, quit silently
        let myPid = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.faradaysoft.voice"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPid && !$0.isTerminated }
        if !others.isEmpty {
            NSLog("Voice: another instance already running (pid %d), quitting", others[0].processIdentifier)
            NSApplication.shared.terminate(nil)
            return
        }

        // Request notification permissions
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self

        // Shortcuts reference
        let hotkeyName = hotkeyOptions[Settings.shared.hotkeyIndex].name
        let shortcutsHeader = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        shortcutsHeader.isEnabled = false
        menu.addItem(shortcutsHeader)
        let pttItem = NSMenuItem(title: "  Push-to-Talk", action: nil, keyEquivalent: "")
        pttItem.isEnabled = false
        if #available(macOS 14.0, *) { pttItem.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) }
        let pttKey = NSMenuItem(title: hotkeyName, action: nil, keyEquivalent: "")
        pttKey.isEnabled = false
        menu.addItem(pttItem)
        let popoItem = NSMenuItem(title: "  Hands-Free (double-tap \(hotkeyName))", action: nil, keyEquivalent: "")
        popoItem.isEnabled = false
        if #available(macOS 14.0, *) { popoItem.image = NSImage(systemSymbolName: "mic.badge.plus", accessibilityDescription: nil) }
        menu.addItem(popoItem)

        menu.addItem(NSMenuItem.separator())

        // Actions
        let pasteItem = NSMenuItem(title: "Paste Last Transcription", action: #selector(pasteLast), keyEquivalent: "v")
        pasteItem.target = self
        if #available(macOS 14.0, *) { pasteItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) }
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        // Microphone submenu
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        if #available(macOS 14.0, *) { micItem.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) }
        let micSubmenu = NSMenu()
        micItem.submenu = micSubmenu
        menu.addItem(micItem)

        menu.addItem(NSMenuItem.separator())

        // Settings & Quit
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        if #available(macOS 14.0, *) { settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) }
        menu.addItem(settingsItem)
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        let setupItem = NSMenuItem(title: "Run Setup Again\u{2026}", action: #selector(runSetupAgain), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Voice", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        // Link text injector to input monitor so it can disable event tap during paste
        textInjector.inputMonitor = inputMonitor

        // Setup input monitor
        inputMonitor.onRecordStart = { [weak self] in
            self?.startRecording()
        }
        inputMonitor.onRecordStop = { [weak self] in
            self?.stopRecording()
        }
        inputMonitor.onCancel = { [weak self] in
            self?.cancelRecording()
        }
        inputMonitor.onPopoStart = { [weak self] in
            self?.startPopo()
        }
        inputMonitor.onPopoStop = { [weak self] in
            self?.stopPopo()
        }

        // First-launch onboarding
        if !Settings.shared.onboardingComplete {
            OnboardingWindowController.shared.show()
        } else if ProcessInfo.processInfo.environment["VOICE_FORCE_ONBOARDING"] != nil {
            // Dev/preview hook: reopen the setup wizard on an already-set-up app.
            OnboardingWindowController.shared.show(rerun: true)
        }

        inputMonitor.reloadHotkey()
        // During onboarding, skip everything that touches Accessibility —
        // AXIsProcessTrusted() can trigger the system dialog on macOS Sequoia.
        // The onboarding completion handler will start these.
        if Settings.shared.onboardingComplete {
            // Start accessibility polling for auto-restart
            startAccessibilityPolling()

            if !inputMonitor.start() {
                showNotification(title: "Voice", body: "Accessibility permission required. Add Voice.app in System Settings > Privacy & Security > Accessibility.")
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                // AX polling timer (started above) will handle relaunch when permission is granted
            }
        }

        // Listen for audio device changes (Bluetooth connect/disconnect)
        var defaultDeviceAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self = self else { return }
            // Debounce — AVAudioEngine setup itself can trigger device change notifications
            if self.isRestartingEngine { return }
            NSLog("Voice: default input device changed")
            // If currently capturing audio, restart the engine with the new device.
            switch self.appState {
            case .recording, .popo:
                NSLog("Voice: restarting engine during active capture due to device change")
                self.audioEngine?.inputNode.removeTap(onBus: 0)
                self.audioEngine?.stop()
                self.audioEngine = nil
                // Small delay for the new device to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    switch self.appState {
                    case .recording, .popo:
                        self.restartRecordingEngine()
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        // Re-create event tap after wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.markWake()
            // Delay tap restart — system needs a moment after wake
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.inputMonitor.stop()
                _ = self?.inputMonitor.start()
            }
        }

        // Preflight: download any missing models (speech always, cleanup
        // only if AI cleanup is on). Models aren't bundled in the DMG.
        var required = [Settings.shared.speechModel]
        if Settings.shared.aiEnabled { required.append(ModelCatalog.cleanup) }
        ModelDownloadWindowController.shared.ensureModels(required) {
            SpeechEngine.shared.warmUp(speech: Settings.shared.speechModel, cleanup: Settings.shared.aiEnabled)
        }
    }

    // MARK: - Accessibility Polling

    private var wasAccessibilityGranted = false
    private var accessibilityPollTimer: Timer?
    private var lastWakeTime: Date = .distantPast
    private var axChangeCount = 0

    func startAccessibilityPolling() {
        wasAccessibilityGranted = AXIsProcessTrusted()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Skip checks for 10 seconds after wake — AXIsProcessTrusted can flicker
            if Date().timeIntervalSince(self.lastWakeTime) < 10.0 { return }
            let isNowGranted = AXIsProcessTrusted()
            if isNowGranted != self.wasAccessibilityGranted {
                // Debounce: require 3 consecutive checks (~6s) before acting
                self.axChangeCount += 1
                if self.axChangeCount >= 3 {
                    self.wasAccessibilityGranted = isNowGranted
                    self.axChangeCount = 0
                    if isNowGranted {
                        self.relaunchSilently()
                    }
                }
            } else {
                self.axChangeCount = 0
            }
        }
    }

    func markWake() {
        lastWakeTime = Date()
    }

    func relaunchSilently() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    func makeWaveformImage(tint: NSColor? = nil) -> NSImage {
        let w: CGFloat = 18, h: CGFloat = 18
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        let barCount = 7
        let barW: CGFloat = 1.5
        let gap: CGFloat = 1.0
        let totalW = CGFloat(barCount) * barW + CGFloat(barCount - 1) * gap
        let startX = (w - totalW) / 2.0
        let centerY = h / 2.0
        let maxH = h * 0.7
        let heights: [CGFloat] = [0.25, 0.5, 0.75, 1.0, 0.75, 0.5, 0.25]
        (tint ?? NSColor.black).setFill()
        for i in 0..<barCount {
            let bh = maxH * heights[i]
            let x = startX + CGFloat(i) * (barW + gap)
            let y = centerY - bh / 2.0
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: bh),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        img.unlockFocus()
        img.isTemplate = (tint == nil)
        return img
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        switch appState {
        case .idle:
            button.title = ""
            button.contentTintColor = nil
            button.image = makeWaveformImage()
        case .recording:
            button.title = ""
            let micOrange = NSColor(red: 0.98, green: 0.68, blue: 0.08, alpha: 1.0)
            button.image = makeWaveformImage(tint: micOrange)
        case .popo:
            button.title = ""
            let micOrange = NSColor(red: 0.98, green: 0.68, blue: 0.08, alpha: 1.0)
            button.image = makeWaveformImage(tint: micOrange)
        case .processing:
            button.title = ""
            button.image = makeWaveformImage(tint: .secondaryLabelColor)
        }
    }

    // MARK: - Overlay

    func showOverlay(state: OverlayState) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        if !Settings.shared.overlayEnabled { return }

        guard let contentView = overlayWindow.contentView as? OverlayContentView else { return }
        contentView.overlayState = state
        contentView.appDelegate = self

        switch state {
        case .recording, .popo:
            // Pass target app context
            if let app = previousApp {
                contentView.targetAppName = app.localizedName ?? ""
                contentView.targetAppIcon = app.icon
            } else {
                contentView.targetAppName = ""
                contentView.targetAppIcon = nil
            }
            contentView.startAnimation()
        default:
            contentView.stopAnimation()
            contentView.targetAppName = ""
            contentView.targetAppIcon = nil
        }

        overlayWindow.positionOnScreen()
        overlayWindow.orderFrontRegardless()
    }

    func hideOverlay() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        (overlayWindow.contentView as? OverlayContentView)?.stopAnimation()
        overlayWindow.orderOut(nil)
    }

    func autoDismissOverlay(after seconds: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.hideOverlay()
        }
    }

    // MARK: - Audio Capture

    // Push-to-talk (.recording) and hands-free (.popo) share one capture path;
    // they differ only in state, sounds and the hands-free safety timeout.

    func startRecording() {
        beginCapture(popo: false)
    }

    func startPopo() {
        beginCapture(popo: true)
    }

    func stopRecording() {
        guard case .recording = appState else { return }
        endCapture(transcribe: true, sound: "Pop")
    }

    func stopPopo() {
        guard case .popo = appState else { return }
        endCapture(transcribe: true, sound: "Submarine")
    }

    func cancelRecording() {
        switch appState {
        case .recording, .popo:
            endCapture(transcribe: false, sound: "Funk")
        default:
            break
        }
    }

    private func beginCapture(popo: Bool) {
        guard case .idle = appState else { return }

        zeroBufferCount = 0
        zeroSignalWarningShown = false

        // Save the currently focused app so we can refocus it before pasting
        previousApp = NSWorkspace.shared.frontmostApplication
        // Load models while the user talks, so they're warm at release.
        SpeechEngine.shared.prepare(speech: Settings.shared.speechModel, cleanup: Settings.shared.aiEnabled)

        // Show feedback immediately — before engine start
        appState = popo ? .popo : .recording
        inputMonitor.setRecording(true)
        if popo { inputMonitor.setPopo(true) }
        updateIcon()
        showOverlay(state: popo ? .popo : .recording)
        if Settings.shared.soundsEnabled { playSound(popo ? "Morse" : "Tink") }

        // WAV with a 44-byte placeholder header, finalized in endCapture
        let tempFile = NSTemporaryDirectory() + "voice_\(ProcessInfo.processInfo.globallyUniqueString).wav"
        audioFile = tempFile
        FileManager.default.createFile(atPath: tempFile, contents: Data(count: 44))
        guard let handle = FileHandle(forWritingAtPath: tempFile) else {
            abortCapture("Failed to create audio file")
            return
        }
        handle.seek(toFileOffset: 44)
        audioFileHandle = handle
        audioDataSize = 0

        if let error = startCaptureEngine() {
            abortCapture(error)
            return
        }

        if popo {
            popoTimer = Timer.scheduledTimer(withTimeInterval: Settings.shared.popoTimeoutSeconds, repeats: false) { [weak self] _ in
                self?.stopPopo()
                self?.showNotification(title: "Voice", body: "Hands-free mode auto-stopped after \(Settings.shared.popoTimeout) minutes.")
            }
        }
    }

    private func abortCapture(_ message: String) {
        audioFileHandle?.closeFile()
        audioFileHandle = nil
        if let file = audioFile { cleanup(file) }
        audioFile = nil
        appState = .idle
        inputMonitor.setRecording(false)
        inputMonitor.setPopo(false)
        updateIcon()
        hideOverlay()
        showNotification(title: "Voice", body: message)
    }

    private func endCapture(transcribe: Bool, sound: String) {
        popoTimer?.invalidate()
        popoTimer = nil
        inputMonitor.setRecording(false)
        inputMonitor.setPopo(false)

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        // Delay dealloc — AVAudioIOUnit dispatch queue may have in-flight callbacks
        let engineRef = audioEngine
        audioEngine = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = engineRef }

        if transcribe, let handle = audioFileHandle {
            writeWAVHeader(to: handle, dataSize: audioDataSize)
        }
        audioFileHandle?.closeFile()
        audioFileHandle = nil
        if Settings.shared.soundsEnabled { playSound(sound) }

        guard transcribe else {
            if let file = audioFile { cleanup(file) }
            audioFile = nil
            appState = .idle
            updateIcon()
            hideOverlay()
            return
        }

        appState = .processing
        updateIcon()
        showOverlay(state: .transcribing)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribeAndProcess()
        }
    }

    // Re-create the engine mid-capture after a device change (Bluetooth reconnect).
    // Keeps appending to the same WAV file.
    func restartRecordingEngine() {
        isRestartingEngine = true
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.isRestartingEngine = false } }
        if let error = startCaptureEngine() {
            NSLog("Voice: engine restart after device change failed: %@", error)
        }
    }

    // Starts an AVAudioEngine on the selected mic, converting input to 16 kHz
    // mono Int16 appended to audioFileHandle. Returns an error message on failure.
    private func startCaptureEngine() -> String? {
        var engine = AVAudioEngine()
        var inputNode = engine.inputNode

        // Set selected microphone via CoreAudio; a mic that has disappeared
        // falls back to the system default silently.
        let selectedUID = Settings.shared.micDeviceUID
        if !selectedUID.isEmpty {
            if let device = listInputDevices().first(where: { $0.uid == selectedUID }) {
                var deviceID = device.deviceID
                let status = AudioUnitSetProperty(
                    inputNode.audioUnit!,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    NSLog("Voice: Failed to set mic device %@ (status %d), using default", selectedUID, status)
                }
            } else {
                NSLog("Voice: Preferred mic %@ not found, using system default", selectedUID)
            }
        }

        var hwFormat = inputNode.outputFormat(forBus: 0)
        // If format is invalid (0 channels / 0 sample rate), the device selection failed silently.
        // Reset to system default and retry with a fresh engine.
        if hwFormat.channelCount == 0 || hwFormat.sampleRate == 0 {
            NSLog("Voice: invalid hwFormat — resetting mic to system default")
            Settings.shared.micDeviceUID = ""
            engine = AVAudioEngine()
            inputNode = engine.inputNode
            hwFormat = inputNode.outputFormat(forBus: 0)
        }
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            return "No valid microphone found"
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            NSLog("Voice: converter creation failed — hwFormat=%@", hwFormat.description)
            return "Failed to create audio converter"
        }

        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, _ in
            guard let self = self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / hwFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return }
            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, let channelData = convertedBuffer.int16ChannelData else { return }
            let frameCount = Int(convertedBuffer.frameLength)
            self.audioFileHandle?.write(Data(bytes: channelData[0], count: frameCount * 2))
            self.audioDataSize += UInt32(frameCount * 2)

            // RMS level for the waveform overlay
            var sum: Float = 0
            for i in 0..<frameCount {
                let sample = Float(channelData[0][i]) / 32768.0
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(max(frameCount, 1)))
            DispatchQueue.main.async {
                self.currentAudioLevel = rms
                // Zero-signal detection (AirPods/Bluetooth mics that deliver silence)
                guard rms < 0.0001 else {
                    self.zeroBufferCount = 0
                    return
                }
                self.zeroBufferCount += 1
                // ~2 seconds of silence at 16kHz with 4096 buffer = ~8 buffers
                guard self.zeroBufferCount > 8, !self.zeroSignalWarningShown else { return }
                self.zeroSignalWarningShown = true
                self.showOverlay(state: .error("No audio detected \u{2014} check your microphone"))
                // Return to the capture overlay after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    switch self.appState {
                    case .recording: self.showOverlay(state: .recording)
                    case .popo: self.showOverlay(state: .popo)
                    default: break
                    }
                }
            }
        }
        // installTap can raise ObjC exceptions on mic disconnect / format
        // mismatch — catch them instead of crashing with SIGABRT.
        let tapOK = VoiceExceptionCatcher.run {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat, block: tapBlock)
        }
        guard tapOK else { return "Microphone unavailable — try again" }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            NSLog("Voice: engine.start() FAILED: %@", error.localizedDescription)
            return "Failed to start recording: \(error.localizedDescription)"
        }
        audioEngine = engine
        NSLog("Voice: engine started — sampleRate=%.0f channels=%d", hwFormat.sampleRate, hwFormat.channelCount)
        return nil
    }

    // MARK: - Transcription & Processing

    func transcribeAndProcess() {
        guard let audioFile = audioFile else {
            finishProcessing(error: "No audio file")
            return
        }

        guard FileManager.default.fileExists(atPath: audioFile),
              let attrs = try? FileManager.default.attributesOfItem(atPath: audioFile),
              let size = attrs[.size] as? Int, size > 1000 else {
            finishProcessing(error: "Recording too short")
            cleanup(audioFile)
            return
        }

        // Capture active-app context once and reuse for both whisper biasing
        // and the downstream LLM cleanup pass.
        let appContext = AppContext.current()

        // Peak-normalize the WAV so quiet/mumbled speech is brought up to a
        // consistent level before the speech model sees it. This is the single
        // biggest quality win for low-volume input and costs ~10ms.
        normalizeWavFile(at: audioFile)
        let samples = loadPCM16Wav(at: audioFile)
        // Audio is in memory now — don't leave the recording on disk.
        cleanup(audioFile)
        guard let samples, !samples.isEmpty else {
            finishProcessing(error: "Recording too short")
            return
        }

        let model = Settings.shared.speechModel
        guard model.isInstalled else {
            finishProcessing(error: "Speech model not downloaded")
            DispatchQueue.main.async {
                ModelDownloadWindowController.shared.ensureModels([model]) {}
            }
            return
        }

        // Only Whisper can use a biasing prompt; Parakeet has no prompt input.
        let prompt = model.asrKind == VE_ASR_WHISPER ? whisperContextPrompt(from: appContext) : ""
        let language = Settings.shared.transcriptionLanguage
        guard var rawText = SpeechEngine.shared.transcribe(samples, model: model, prompt: prompt, language: language) else {
            finishProcessing(error: "Transcription failed")
            return
        }
        rawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = rawText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        rawText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Fix glued sentences ("done.Next") and missing space after , ; :
        // Narrow on purpose: "node.js", "Voice.swift" and "U.S." stay intact.
        rawText = rawText.replacingOccurrences(
            of: "([a-z]{2}[.!?])([A-Z][a-z])|([,;:])([A-Za-z])",
            with: "$1$3 $2$4",
            options: .regularExpression
        )

        if rawText.isEmpty {
            finishProcessing(error: "Empty transcription")
            return
        }

        let finalText = polishTranscript(rawText, appContext: appContext)
        // "Um." alone cleans down to "." — nothing worth pasting.
        guard finalText.rangeOfCharacter(from: .alphanumerics) != nil else {
            finishProcessing(error: "Empty transcription")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.refocusAndInject(finalText)
            self?.finishProcessing(text: finalText)
        }
    }

    func finishProcessing(text: String? = nil, error: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.appState = .idle
            self?.updateIcon()

            if let text = text {
                self?.lastTranscription = text
                Settings.shared.saveTranscript(text)
                let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text
                self?.showOverlay(state: .done(preview))
                self?.autoDismissOverlay(after: 1.5)
                if Settings.shared.soundsEnabled { self?.playSound("Glass") }
            } else if let error = error {
                self?.showOverlay(state: .error(error))
                self?.autoDismissOverlay(after: 2.0)
                if Settings.shared.soundsEnabled { self?.playSound("Basso") }
            }
        }
    }

    // MARK: - Focus & Inject

    func refocusAndInject(_ text: String) {
        // Re-activate the app that was focused before recording started
        if let app = previousApp, !app.isTerminated {
            app.activate()
            // Give the app time to regain focus before injecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.textInjector.injectText(text)
            }
        } else {
            textInjector.injectText(text)
        }
    }

    // MARK: - Utilities

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    func playSound(_ name: String) {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: afplayPath)
        process.arguments = [path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc func runSetupAgain() {
        OnboardingWindowController.shared.show(rerun: true)
    }

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    // NSMenuDelegate — rebuild mic submenu each time menu opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.title == "Microphone", let submenu = item.submenu {
                submenu.removeAllItems()
                // System Default option
                let defaultItem = NSMenuItem(title: "System Default", action: #selector(selectMic(_:)), keyEquivalent: "")
                defaultItem.target = self
                defaultItem.representedObject = "" as NSString
                defaultItem.state = Settings.shared.micDeviceUID.isEmpty ? .on : .off
                submenu.addItem(defaultItem)
                submenu.addItem(NSMenuItem.separator())
                // Available input devices
                let devices = listInputDevices()
                for device in devices {
                    let devItem = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
                    devItem.target = self
                    devItem.representedObject = device.uid as NSString
                    devItem.state = (device.uid == Settings.shared.micDeviceUID) ? .on : .off
                    submenu.addItem(devItem)
                }
            }
        }
    }

    @objc func selectMic(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Settings.shared.micDeviceUID = uid
    }

    @objc func pasteLast() {
        guard let text = lastTranscription else {
            if Settings.shared.soundsEnabled { playSound("Basso") }
            return
        }
        // Put text on clipboard immediately (user can also manually Cmd+V)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Wait for menu to close and focus to return, then inject
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.textInjector.injectText(text)
        }
    }

    @objc func checkForUpdates() {
        let appcastURL = URL(string: "https://faradaysoft.com/appcast.json")!
        URLSession.shared.dataTask(with: appcastURL) { data, _, error in
            DispatchQueue.main.async {
                guard let data = data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let latestVersion = json["version"] as? String,
                      let downloadURL = json["url"] as? String else {
                    let alert = NSAlert()
                    alert.messageText = "Update Check Failed"
                    alert.informativeText = "Could not reach the update server. Please try again later."
                    alert.alertStyle = .warning
                    alert.runModal()
                    return
                }

                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

                if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                    let alert = NSAlert()
                    alert.messageText = "Update Available"
                    alert.informativeText = "Voice \(latestVersion) is available. You have \(currentVersion)."
                    if let notes = json["notes"] as? String {
                        alert.informativeText += "\n\n\(notes)"
                    }
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    alert.alertStyle = .informational
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: downloadURL)!)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "You're Up to Date"
                    alert.informativeText = "Voice \(currentVersion) is the latest version."
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            }
        }.resume()
    }

    @objc func quitApp() {
        // Close settings window before quit so macOS doesn't snapshot it
        for window in NSApp.windows {
            window.close()
        }
        popoTimer?.invalidate()
        inputMonitor.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFileHandle?.closeFile()
        audioFileHandle = nil
        if let file = audioFile {
            cleanup(file)
        }
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Main

// @main (built with -parse-as-library) because the app is now more than one
// Swift file, and top-level code is only allowed in main.swift.
@main
enum VoiceMain {
    // NSApplication.delegate is weak — something has to own the delegate.
    private static var appDelegate: AppDelegate?

    static func main() {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--selftest" {
            exit(SelfTest.run(Array(CommandLine.arguments.dropFirst(2))))
        }

        // Disable macOS window restoration BEFORE app.run() — restoration happens during run(),
        // before applicationDidFinishLaunching, so this must be set early.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        // Nuke any saved state left over from a previous run
        let savedStatePath = NSHomeDirectory() + "/Library/Saved Application State/com.faradaysoft.voice.savedState"
        try? FileManager.default.removeItem(atPath: savedStatePath)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
