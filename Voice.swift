// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

import Cocoa
import ApplicationServices
import UserNotifications
import AVFoundation
import CoreAudio
import SceneKit
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
/// The overlay's type: the design system's mono labels.
func overlayFont(_ size: CGFloat, weight: NSFont.Weight = .medium) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight)
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
            if Settings.shared.overlayShowAppName, cv.targetAppName.isEmpty { contentWidth += 0 }
            if Settings.shared.overlayShowAppName, !cv.targetAppName.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: overlayFont(fontSize - 1, weight: .regular)]
                let nameW = min((cv.targetAppName as NSString).size(withAttributes: attrs).width, 80)
                contentWidth += nameW + 8
            }
            contentWidth += 35 + 8  // waveform + gap
            if Settings.shared.overlayShowTimer { contentWidth += 40 }
        case .transcribing:
            let attrs: [NSAttributedString.Key: Any] = [.font: overlayFont(fontSize + 1, weight: .semibold)]
            contentWidth = ("\u{23F3} THINKING..." as NSString).size(withAttributes: attrs).width
        case .done(let preview):
            let truncated = preview.count > 30 ? String(preview.prefix(30)) + "..." : preview
            let attrs: [NSAttributedString.Key: Any] = [.font: overlayFont(fontSize + 1, weight: .semibold)]
            contentWidth = ("\u{2713} \(truncated)" as NSString).size(withAttributes: attrs).width
        case .error(let msg):
            let truncated = msg.count > 30 ? String(msg.prefix(30)) + "..." : msg
            let attrs: [NSAttributedString.Key: Any] = [.font: overlayFont(fontSize + 1, weight: .semibold)]
            contentWidth = ("\u{2717} \(truncated)" as NSString).size(withAttributes: attrs).width
        }

        // The pill is `pillHeight` tall; the 3D mic is a square as tall as the whole
        // window, standing on the pill's bottom edge and rising above its top.
        let pillHeight = max(fontSize * 2.4, 30)
        let h = pillHeight + OverlayContentView.micOverhang
        let micWidth = h * 0.86
        let micRight = OverlayContentView.micInset + micWidth
        let w = micRight + contentWidth + padding

        let newFrame = NSRect(x: 0, y: 0, width: w, height: h)
        setFrame(newFrame, display: true)
        contentView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        cv.pillHeight = pillHeight
        cv.micRight = micRight
        cv.layoutMic(NSRect(x: OverlayContentView.micInset, y: 0, width: micWidth, height: h))
        hasShadow = Settings.shared.overlayBackgroundOpacity > 0
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - w / 2
        let y = screenFrame.maxY - h - 10
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
    /// How far the mic rises above the pill.
    static let micOverhang: CGFloat = 22
    static let micInset: CGFloat = 6

    var overlayState: OverlayState = .recording {
        didSet { needsDisplay = true }
    }
    /// Set by OverlayWindow.positionOnScreen.
    var pillHeight: CGFloat = 30
    var micRight: CGFloat = 40
    private var pillRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: pillHeight) }

    // The same clay microphone as the main window, in its own little scene.
    private let micView = SCNView(frame: .zero)
    let micController = MicController()
    private var levelSmoothed: CGFloat = 0
    private var micTurntable: SCNNode?
    private var builtStyle: MicStyle?

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
        setUpMic()
        NotificationCenter.default.addObserver(forName: .voiceThemeChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.needsDisplay = true
            self.rebuildMicIfNeeded()
            self.micController.apply(ThemeStore.shared.current)
        }
    }

    /// Swaps the overlay's mic for the chosen style.
    private func rebuildMicIfNeeded() {
        let style = ThemeStore.shared.heroStyle
        guard style != builtStyle, let turntable = micTurntable else { return }
        turntable.childNodes.forEach { $0.removeFromParentNode() }
        let theme = ThemeStore.shared.current
        let nodes = MicModel.make(style: style, head: theme.heroPrimary, stand: theme.heroSecondary)
        turntable.addChildNode(nodes.root)
        micController.attach(nodes, turntable: turntable)
        micController.apply(theme, animated: false)
        builtStyle = style
    }

    private func setUpMic() {
        micView.wantsLayer = true
        micView.layer?.isOpaque = false
        micView.layer?.backgroundColor = NSColor.clear.cgColor
        micView.backgroundColor = .clear
        micView.antialiasingMode = .multisampling4X
        micView.preferredFramesPerSecond = 60
        micView.rendersContinuously = false
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        MicModel.stage(in: scene)
        // Tight crop: the mic nearly fills its square.
        _ = MicModel.camera(in: scene, distance: 4.8)
        let theme = ThemeStore.shared.current
        let nodes = MicModel.make(style: ThemeStore.shared.heroStyle, head: theme.heroPrimary, stand: theme.heroSecondary)
        builtStyle = ThemeStore.shared.heroStyle
        let turntable = SCNNode()
        turntable.eulerAngles = SCNVector3(0.05, MicSceneView.restYaw, 0)
        turntable.addChildNode(nodes.root)
        scene.rootNode.addChildNode(turntable)
        micTurntable = turntable
        micView.scene = scene
        micController.attach(nodes, turntable: turntable)
        micController.apply(theme, animated: false)
        addSubview(micView)
    }

    func layoutMic(_ frame: NSRect) {
        micView.frame = frame
    }

    /// Mirrors the overlay state onto the mic: it listens, thinks, hops or shakes.
    func applyMicState() {
        micView.rendersContinuously = true
        switch overlayState {
        case .recording, .popo:
            micController.setThinking(false)
            micController.setListening(true, breathe: false)
        case .transcribing:
            micController.setListening(false)
            micController.setThinking(true)
        case .done:
            micController.setThinking(false)
            micController.setListening(false)
            micController.bounce()
        case .error:
            micController.setThinking(false)
            micController.setListening(false)
            micController.shake()
        }
        micView.isPlaying = true
    }

    func pauseMic() {
        micView.rendersContinuously = false
        micView.isPlaying = false
        micController.setListening(false)
        micController.setThinking(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private var theme: Theme { ThemeStore.shared.current }

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
            // The mic's head swells with your voice.
            self.micController.setLevel(CGFloat(amplified))

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
        // Background pill in the theme's ground color, with a hairline of ink.
        let bgOpacity = Settings.shared.overlayBackgroundOpacity
        if bgOpacity > 0 {
            let path = NSBezierPath(roundedRect: pillRect.insetBy(dx: 1, dy: 1), xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
            theme.nsBackground.withAlphaComponent(bgOpacity).setFill()
            path.fill()
            theme.nsInk.withAlphaComponent(0.12 * bgOpacity).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        switch overlayState {
        case .recording, .popo:
            drawRecordingOverlay()
        case .transcribing:
            drawCenteredText(icon: "\u{23F3}", text: "THINKING...")
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
            .foregroundColor: theme.nsInk,
            .font: overlayFont(Settings.shared.overlayFontSize + 1, weight: .semibold)
        ]
        let fullText = icon + " " + text
        let size = fullText.size(withAttributes: attrs)
        let areaMidX = (micRight + pillRect.width) / 2
        let textPoint = NSPoint(x: areaMidX - size.width / 2, y: pillRect.midY - size.height / 2)
        fullText.draw(at: textPoint, withAttributes: attrs)
    }

    private func drawRecordingOverlay() {
        let isRecordingState: Bool
        if case .recording = overlayState { isRecordingState = true } else { isRecordingState = false }

        let fontSize = Settings.shared.overlayFontSize
        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.nsInk,
            .font: overlayFont(fontSize, weight: .medium)
        ]
        let smallAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: theme.nsInk.withAlphaComponent(0.7),
            .font: overlayFont(fontSize - 1, weight: .regular)
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

        // --- Draw centered in the area right of the mic ---
        var x = (micRight + pillRect.width) / 2 - totalWidth / 2
        let midY = pillRect.midY

        // Accent dot while holding the key; a ring for hands-free.
        let dotRect = NSRect(x: x, y: midY - dotSize / 2, width: dotSize, height: dotSize)
        if isRecordingState {
            theme.nsAccent.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        } else {
            theme.nsAccent.setStroke()
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
        }
        x += dotSize + 6

        // App icon
        if Settings.shared.overlayShowAppIcon, let icon = targetAppIcon {
            let iconSize: CGFloat = 16
            let iconRect = NSRect(x: x, y: midY - iconSize / 2, width: iconSize, height: iconSize)
            icon.draw(in: iconRect)
            x += iconSize + 4
        }

        // App name, truncated with an ellipsis so it never runs into the waveform.
        if Settings.shared.overlayShowAppName, !targetAppName.isEmpty {
            let nameStr = targetAppName as NSString
            let nameSize = nameStr.size(withAttributes: smallAttrs)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            var attrs = smallAttrs
            attrs[.paragraphStyle] = paragraph
            let width = min(nameSize.width, 60)
            nameStr.draw(in: NSRect(x: x, y: midY - nameSize.height / 2, width: width, height: nameSize.height), withAttributes: attrs)
            x += width + 8
        }

        // Waveform bars — WhatsApp-style: center bars tallest, mirrored outward
        let maxBarHeight: CGFloat = pillRect.height * 0.7
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
            let by = midY - barHeight / 2
            let barRect = NSRect(x: bx, y: by, width: barWidth, height: barHeight)
            theme.nsInk.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        x = waveformX + waveformWidth + 8

        // Elapsed timer
        if Settings.shared.overlayShowTimer, let startTime = recordingStartTime {
            let elapsed = Int(Date().timeIntervalSince(startTime))
            let timerStr = String(format: "%d:%02d", elapsed / 60, elapsed % 60) as NSString
            let timerSize = timerStr.size(withAttributes: textAttrs)
            let timerPoint = NSPoint(x: x, y: midY - timerSize.height / 2)
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

    /// `-screen <name>` launch argument: open one window for screenshot QA and
    /// skip everything that needs Accessibility, the mic or a second instance check.
    static var previewScreen: String?
    static var snapshotPath: String?

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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // voice://thanks (Stripe's after-payment page) and voice://support.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:with:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, with reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        SupportStore.shared.handle(url: url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let screen = Self.previewScreen {
            setUpMenuBar()
            openPreview(screen)
            return
        }

        // Close any windows macOS may have restored despite our early prevention
        for window in NSApp.windows where window.title == "Voice" {
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

        setUpMenuBar()

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
            AppWindows.shared.showOnboarding(rerun: false)
        } else if ProcessInfo.processInfo.environment["VOICE_FORCE_ONBOARDING"] != nil {
            // Dev/preview hook: reopen the setup wizard on an already-set-up app.
            AppWindows.shared.showOnboarding(rerun: true)
        }
        finishLaunchSetup()
    }

    private func setUpMenuBar() {
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
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        let lookItem = NSMenuItem(title: "Customize Look\u{2026}", action: #selector(openLook), keyEquivalent: "")
        lookItem.target = self
        lookItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        menu.addItem(lookItem)
        let supportItem = NSMenuItem(title: SupportStore.shared.isSupporter ? "You're a Supporter \u{2665}" : "Support Voice\u{2026}",
                                     action: #selector(openSupport), keyEquivalent: "")
        supportItem.target = self
        supportItem.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        menu.addItem(supportItem)
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
        NotificationCenter.default.addObserver(forName: .voiceThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateIcon()
        }
    }

    /// Screenshot QA: `Voice -screen home|onboarding|look|support|thanks|download [-theme id] [-shot out.png]`.
    private func openPreview(_ screen: String) {
        switch screen {
        case "onboarding":
            AppWindows.shared.showOnboarding(rerun: true)
        case "look":
            AppWindows.shared.showHome(route: .look)
        case "support":
            AppWindows.shared.showHome(route: .support)
        case "thanks":
            SupportStore.shared.pendingThanks = true
            AppWindows.shared.showHome(route: .support)
        case "overlay", "overlay-popo", "overlay-done", "overlay-error":
            // The fn pill with a fake voice: a slow sine so the mic swells and the bars move.
            previousApp = NSWorkspace.shared.frontmostApplication
            switch screen {
            case "overlay-popo": showOverlay(state: .popo)
            case "overlay-done": showOverlay(state: .done("Can you send me that report by Friday?"))
            case "overlay-error": showOverlay(state: .error("No audio detected"))
            default: showOverlay(state: .recording)
            }
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                let t = Date().timeIntervalSinceReferenceDate
                self?.currentAudioLevel = Float(0.012 + 0.02 * (0.5 + 0.5 * sin(t * 6)))
            }
            if let path = Self.snapshotPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    AppWindows.snapshot(self.overlayWindow, to: path)
                    NSApp.terminate(nil)
                }
            }
            return
        case "download":
            let progress = ModelDownloadWindowController.shared.progress
            progress.purpose = "speech"
            progress.size = "356 MB"
            progress.percent = 42
            progress.status = "150 of 356 MB"
            AppWindows.shared.showDownload(progress: progress)
        default:
            AppWindows.shared.showHome()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let path = Self.snapshotPath else { return }
        // Sheets animate in and SceneKit needs a few frames; wait, then capture the
        // frontmost of our windows (a sheet is its own window, so take the key one).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let window = AppWindows.shared.frontWindow ?? NSApp.keyWindow {
                AppWindows.snapshot(window, to: path)
            }
            NSApp.terminate(nil)
        }
    }

    private func finishLaunchSetup() {
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
        Feedback.prepare()
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

    /// The menu bar glyph: the vintage mic (slot-grille head in a yoke, on a stand) in one color.
    /// Drawn with a handler so it is redrawn sharp at the screen's scale; template when idle.
    func makeMenuBarImage(tint: NSColor? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setFillColor((tint ?? .black).cgColor)
            c.setStrokeColor((tint ?? .black).cgColor)
            // Yoke cradling the head, stem, base.
            c.setLineWidth(1.3)
            c.setLineCap(.round)
            let yoke = CGMutablePath()
            yoke.move(to: CGPoint(x: 4.3, y: 10.5))
            yoke.addLine(to: CGPoint(x: 4.3, y: 8))
            yoke.addArc(center: CGPoint(x: 9, y: 8), radius: 4.7, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            yoke.addLine(to: CGPoint(x: 13.7, y: 10.5))
            c.addPath(yoke)
            c.strokePath()
            c.fill(CGRect(x: 8.3, y: 2.2, width: 1.4, height: 1.4))
            c.addPath(CGPath(roundedRect: CGRect(x: 5.2, y: 0.9, width: 7.6, height: 1.6),
                             cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
            c.fillPath()
            // Solid head with three grille slots cut out.
            c.addPath(CGPath(roundedRect: CGRect(x: 5.6, y: 6.2, width: 6.8, height: 11),
                             cornerWidth: 3.4, cornerHeight: 3.4, transform: nil))
            c.fillPath()
            c.setBlendMode(.clear)
            for y: CGFloat in [8.6, 11.2, 13.8] {
                c.addPath(CGPath(roundedRect: CGRect(x: 7.1, y: y, width: 3.8, height: 1.05),
                                 cornerWidth: 0.52, cornerHeight: 0.52, transform: nil))
            }
            c.fillPath()
            return true
        }
        img.isTemplate = (tint == nil)
        return img
    }

    func updateIcon() {
        AppModel.shared.state = appState
        guard let button = statusItem?.button else { return }
        button.title = ""
        switch appState {
        case .idle:
            button.contentTintColor = nil
            button.image = makeMenuBarImage()
        case .recording, .popo:
            // The theme's accent, so the menu bar matches the overlay and the mic's lamp.
            button.image = makeMenuBarImage(tint: ThemeStore.shared.current.nsAccent)
        case .processing:
            button.image = makeMenuBarImage(tint: .secondaryLabelColor)
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
        contentView.applyMicState()
        overlayWindow.orderFrontRegardless()
    }

    func hideOverlay() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        (overlayWindow.contentView as? OverlayContentView)?.stopAnimation()
        (overlayWindow.contentView as? OverlayContentView)?.pauseMic()
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
                AppModel.shared.lastTranscription = text
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

    /// Recording cues, synthesized by the design system (Feedback) instead of
    /// afplay-ing system sounds. The names are the old system-sound names, kept
    /// so the call sites read the same: Tink = start, Morse = hands-free on,
    /// Pop/Submarine = stop, Glass = done, Funk/Basso = cancel or error.
    func playSound(_ name: String) {
        switch name {
        case "Tink": Feedback.pop()
        case "Morse": Feedback.clink()
        case "Pop", "Submarine": Feedback.thock()
        case "Glass": Feedback.success()
        case "Funk", "Basso": Feedback.error()
        default: Feedback.tick()
        }
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
        AppWindows.shared.showOnboarding(rerun: true)
    }

    @objc func openSettings() {
        AppWindows.shared.showHome()
    }

    @objc func openLook() {
        AppWindows.shared.showHome(route: .look)
    }

    @objc func openSupport() {
        AppWindows.shared.showHome(route: .support)
    }

    // NSMenuDelegate — rebuild mic submenu each time menu opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.action == #selector(openSupport) {
                item.title = SupportStore.shared.isSupporter ? "You're a Supporter \u{2665}" : "Support Voice\u{2026}"
            }
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

                // An update that needs a newer macOS than this Mac runs can't be installed, so say so
                // instead of offering a download that won't open. "minimumSystemVersion" is optional.
                let isNewer = latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending
                if isNewer, let minimum = json["minimumSystemVersion"] as? String,
                   !ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.osVersion(minimum)) {
                    let os = ProcessInfo.processInfo.operatingSystemVersion
                    let alert = NSAlert()
                    alert.messageText = "Voice \(latestVersion) Needs macOS \(minimum)"
                    alert.informativeText = "This Mac runs macOS \(os.majorVersion).\(os.minorVersion). "
                        + "Voice \(currentVersion) keeps working; update macOS to get Voice \(latestVersion)."
                    alert.alertStyle = .informational
                    alert.runModal()
                } else if isNewer {
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

    /// "14" or "14.2" or "14.2.1" as an OperatingSystemVersion; missing parts are 0.
    static func osVersion(_ string: String) -> OperatingSystemVersion {
        let parts = string.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        return OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts[2])
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
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-screen"), i + 1 < args.count {
            AppDelegate.previewScreen = args[i + 1]
        }
        if let i = args.firstIndex(of: "-shot"), i + 1 < args.count {
            AppDelegate.snapshotPath = args[i + 1]
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
