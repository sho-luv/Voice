import Cocoa
import ApplicationServices
import UserNotifications
import AVFoundation
import CoreAudio
import Security

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

// MARK: - Keychain

enum KeychainStore {
    static let service = "com.faradaysoft.voice"

    static func string(for account: String) -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return ""
            }
            return value
        case errSecItemNotFound:
            return ""
        default:
            NSLog("Voice: keychain read failed for %@ (%d)", account, status)
            return ""
        }
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        if value.isEmpty {
            return delete(account)
        }

        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            NSLog("Voice: keychain update failed for %@ (%d)", account, updateStatus)
            return false
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("Voice: keychain add failed for %@ (%d)", account, addStatus)
            return false
        }
        return true
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return true
        }
        NSLog("Voice: keychain delete failed for %@ (%d)", account, status)
        return false
    }
}

// MARK: - Settings

class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private let licenseKeyAccount = "license-key"
    private let licenseInstanceIdAccount = "license-instance-id"

    private init() {
        defaults.register(defaults: [
            "hotkeyIndex": 0,
            "soundsEnabled": true,
            "autoStartOnLogin": true,
            "popoTimeout": 5,
            "clipboardRestore": true,
            "aiEnabled": true,
            "aiModelOllama": "llama3.2:3b",
            "whisperModel": "large-v3-turbo-q5_0",
            "micDeviceUID": "",
            "overlayShowAppName": true,
            "overlayShowAppIcon": true,
            "overlayShowWindowTitle": false,
            "overlayShowTimer": true,
        ])
        migrateLegacyAISettings()
        migrateLegacyLicenseStorage()
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

    var aiModel: String {
        get { defaults.string(forKey: "aiModelOllama") ?? "llama3.2:3b" }
        set { defaults.set(newValue, forKey: "aiModelOllama") }
    }

    var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "large-v3-turbo-q5_0" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    var whisperModelPath: String {
        // 1. Check app bundle (self-contained DMG)
        let bundled = (Bundle.main.resourcePath ?? "") + "/ggml-\(whisperModel).bin"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        // 2. Fall back to Application Support
        return NSHomeDirectory() + "/Library/Application Support/Voice/Models/ggml-\(whisperModel).bin"
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
            return val > 0 ? CGFloat(val) : 11.0
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

    // Word Limit (freemium)
    let freeWeeklyLimit = 2000

    var wordsThisWeek: Int {
        get { defaults.integer(forKey: "wordsThisWeek") }
        set { defaults.set(newValue, forKey: "wordsThisWeek") }
    }

    var weekResetDate: Date? {
        get { defaults.object(forKey: "weekResetDate") as? Date }
        set { defaults.set(newValue, forKey: "weekResetDate") }
    }

    func addWords(_ count: Int) {
        resetWeekIfNeeded()
        wordsThisWeek += count
    }

    var wordsRemaining: Int {
        resetWeekIfNeeded()
        return max(0, freeWeeklyLimit - wordsThisWeek)
    }

    var isOverLimit: Bool {
        resetWeekIfNeeded()
        return wordsThisWeek >= freeWeeklyLimit
    }

    private func resetWeekIfNeeded() {
        let calendar = Calendar.current
        if let resetDate = weekResetDate {
            // Reset if we're in a different week (Monday-based)
            if !calendar.isDate(resetDate, equalTo: Date(), toGranularity: .weekOfYear) {
                wordsThisWeek = 0
                weekResetDate = Date()
            }
        } else {
            weekResetDate = Date()
        }
    }

    // Trial & License
    var trialStartDate: Date? {
        get { defaults.object(forKey: "trialStartDate") as? Date }
        set { defaults.set(newValue, forKey: "trialStartDate") }
    }

    var licenseKey: String {
        get { KeychainStore.string(for: licenseKeyAccount) }
        set { _ = KeychainStore.set(newValue, for: licenseKeyAccount) }
    }

    var licenseInstanceId: String {
        get { KeychainStore.string(for: licenseInstanceIdAccount) }
        set { _ = KeychainStore.set(newValue, for: licenseInstanceIdAccount) }
    }

    var hasStoredLicenseCredentials: Bool {
        !licenseKey.isEmpty && !licenseInstanceId.isEmpty
    }

    var lastLicenseValidation: Date? {
        get { defaults.object(forKey: "lastLicenseValidation") as? Date }
        set { defaults.set(newValue, forKey: "lastLicenseValidation") }
    }

    func resetAll() {
        // Reset user-facing settings to defaults (preserves license/trial data)
        let keysToReset = [
            "hotkeyIndex", "soundsEnabled", "autoStartOnLogin", "popoTimeout",
            "clipboardRestore", "aiEnabled", "aiModelOllama", "whisperModel",
            "micDeviceUID", "overlayShowAppName", "overlayShowAppIcon",
            "overlayShowWindowTitle", "overlayShowTimer",
            "overlayEnabled", "overlayBackgroundOpacity", "overlayFontSize",
            "overlaySensitivity", "saveTranscripts", "transcriptDirectory"
        ]
        for key in keysToReset {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "aiProvider")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("apiKey") {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("aiModel") && key != "aiModelOllama" {
            defaults.removeObject(forKey: key)
        }
    }

    private func migrateLegacyAISettings() {
        defaults.removeObject(forKey: "aiProvider")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("apiKey") {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("aiModel") && key != "aiModelOllama" {
            defaults.removeObject(forKey: key)
        }
    }

    private func migrateLegacyLicenseStorage() {
        let legacyKey = defaults.string(forKey: "licenseKey") ?? ""
        let legacyInstanceId = defaults.string(forKey: "licenseInstanceId") ?? ""

        if licenseKey.isEmpty && !legacyKey.isEmpty {
            licenseKey = legacyKey
        }
        if licenseInstanceId.isEmpty && !legacyInstanceId.isEmpty {
            licenseInstanceId = legacyInstanceId
        }

        defaults.removeObject(forKey: "licenseKey")
        defaults.removeObject(forKey: "licenseInstanceId")
        defaults.removeObject(forKey: "isLicensed")
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

    var toneGuidance: String {
        let name = appName.lowercased()
        if name.contains("mail") || name.contains("outlook") {
            return "Maintain professional tone."
        } else if name.contains("messages") || name.contains("slack") || name.contains("discord") {
            return "Casual tone. Keep concise."
        } else if name.contains("xcode") || name.contains("terminal") || name.contains("code") || name.contains("iterm") {
            return "Preserve technical terms exactly."
        }
        return "Use natural, clear prose."
    }

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
    """
    You are a speech-to-text cleanup assistant. Your ONLY job is to clean up raw speech transcription:
    1. Remove filler words (um, uh, like, you know, I mean, sort of, basically)
    2. Fix grammar and punctuation
    3. Handle mid-sentence corrections -- keep only the final version
    4. Handle backtracking ("scratch that", "no wait") -- discard preceding clause
    5. Add proper capitalization
    6. Preserve the speaker's meaning exactly -- do NOT paraphrase
    7. Output ONLY the cleaned text. No commentary.
    Context: Writing in \(appContext.appName). \(appContext.toneGuidance)
    """
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
    private var spaceHeld = false
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
    var fontSize: CGFloat = 11.0
    private let containerWidth: CGFloat = 430  // parent container width for centering

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

        let sampleLevels: [CGFloat] = [0.2, 0.4, 0.6, 0.9, 0.6, 0.4, 0.2]
        let maxBarHeight: CGFloat = bounds.height * 0.6
        let minBarHeight: CGFloat = 4.0
        for i in 0..<barCount {
            let barHeight = max(minBarHeight, sampleLevels[i] * maxBarHeight)
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

    // App context (shown in overlay per D-14, D-15)
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

        // App icon (per D-14, D-15)
        if Settings.shared.overlayShowAppIcon, let icon = targetAppIcon {
            let iconSize: CGFloat = 16
            let iconRect = NSRect(x: x, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
            icon.draw(in: iconRect)
            x += iconSize + 4
        }

        // App name (per D-14)
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

        // Elapsed timer (per D-13)
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

// MARK: - Ollama Client

class OllamaClient {
    let baseURL = "http://localhost:11434"
    private var isAvailable = false

    var model: String { Settings.shared.aiModel }

    func healthCheck(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            completion(false)
            return
        }

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self, error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                self?.isAvailable = false
                completion(false)
                return
            }
            self.isAvailable = true
            completion(true)
        }.resume()
    }

    func warmup() {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "prompt": "Hello",
            "stream": false,
            "options": ["num_predict": 1]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    func cleanupText(_ text: String, appContext: AppContext, completion: @escaping (String) -> Void) {
        guard isAvailable else {
            completion(text)
            return
        }

        let truncated = String(text.prefix(4000))
        let systemPrompt = cleanupSystemPrompt(appContext: appContext)

        generate(system: systemPrompt, prompt: truncated) { result in
            completion(result ?? text)
        }
    }

    func testConnection(completion: @escaping (Bool, String) -> Void) {
        healthCheck { available in
            if available {
                completion(true, "Ollama is running, model: \(self.model)")
            } else {
                completion(false, "Cannot connect to Ollama at localhost:11434")
            }
        }
    }

    private func generate(system: String, prompt: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.1, "num_predict": 2048]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                completion(nil)
                return
            }

            let cleaned = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(cleaned.isEmpty ? nil : cleaned)
        }.resume()
    }
}

// MARK: - License Manager

enum LicenseState {
    case free(wordsLeft: Int)
    case limitReached
    case licensed
    case offlineGrace  // licensed but can't re-validate, working but warning
    case invalid
}

class LicenseManager {
    static let shared = LicenseManager()

    private let lsProductId: Int = 912013
    let checkoutURL = "https://faradaysoft.lemonsqueezy.com/checkout/buy/2617c440-f8d4-49c7-b6fd-4cbb15ed95fd"

    private let revalidationIntervalDays = 7
    private let offlineGraceDays = 3

    private init() {}

    private var hasStoredLicenseCredentials: Bool {
        Settings.shared.hasStoredLicenseCredentials
    }

    // MARK: - State

    var currentState: LicenseState {
        // If licensed, check revalidation
        if hasStoredLicenseCredentials {
            guard let lastCheck = Settings.shared.lastLicenseValidation else {
                return .offlineGrace
            }
            let daysSince = Date().timeIntervalSince(lastCheck) / 86400
            if daysSince > Double(revalidationIntervalDays + offlineGraceDays) {
                return .invalid  // too long without validation
            } else if daysSince > Double(revalidationIntervalDays) {
                return .offlineGrace
            }
            return .licensed
        }

        // Free tier word limit
        let remaining = Settings.shared.wordsRemaining
        if remaining <= 0 {
            return .limitReached
        }
        return .free(wordsLeft: remaining)
    }

    var canRecord: Bool {
        switch currentState {
        case .free, .licensed, .offlineGrace:
            return true
        case .limitReached, .invalid:
            return false
        }
    }

    var statusText: String {
        switch currentState {
        case .free(let wordsLeft):
            let used = Settings.shared.freeWeeklyLimit - wordsLeft
            return "\(used) / \(Settings.shared.freeWeeklyLimit) words"
        case .limitReached: return "Weekly limit reached"
        case .licensed: return "Licensed"
        case .offlineGrace: return "Licensed (offline)"
        case .invalid: return "License invalid"
        }
    }

    // MARK: - Activation

    func activate(key: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate") else {
            completion(false, "Invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let machineName = Host.current().localizedName ?? "Mac"
        let body = "license_key=\(key)&instance_name=\(machineName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Mac")"
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async { completion(false, error?.localizedDescription ?? "Network error") }
                return
            }

            let activated = json["activated"] as? Bool ?? false
            let instanceId = (json["instance"] as? [String: Any])?["id"] as? String
            let licenseStatus = (json["license_key"] as? [String: Any])?["status"] as? String

            if activated, let instanceId = instanceId, licenseStatus == "active" {
                Settings.shared.licenseKey = key
                Settings.shared.licenseInstanceId = instanceId
                Settings.shared.lastLicenseValidation = Date()
                DispatchQueue.main.async { completion(true, "License activated!") }
            } else {
                let errorMsg = (json["error"] as? String) ?? "Activation failed"
                DispatchQueue.main.async { completion(false, errorMsg) }
            }
        }.resume()
    }

    // MARK: - Validation

    func validateIfNeeded() {
        guard hasStoredLicenseCredentials else { return }
        guard let lastCheck = Settings.shared.lastLicenseValidation else {
            validateOnline()
            return
        }
        let daysSince = Date().timeIntervalSince(lastCheck) / 86400
        if daysSince >= Double(revalidationIntervalDays) {
            validateOnline()
        }
    }

    private func validateOnline() {
        guard let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/validate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "license_key=\(Settings.shared.licenseKey)&instance_id=\(Settings.shared.licenseInstanceId)"
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Network error — rely on cached state + offline grace
                return
            }
            let valid = json["valid"] as? Bool ?? false
            if valid {
                Settings.shared.lastLicenseValidation = Date()
            } else {
                // License revoked or invalid — clear licensed state
                self.deactivate()
            }
        }.resume()
    }

    // MARK: - Deactivation

    func deactivate() {
        Settings.shared.licenseKey = ""
        Settings.shared.licenseInstanceId = ""
        Settings.shared.lastLicenseValidation = nil
    }
}

// MARK: - License Expiry Modal

class LicenseExpiryWindowController {
    static let shared = LicenseExpiryWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled],  // no close — must enter key or quit
            backing: .buffered,
            defer: false
        )
        w.title = "Voice"
        w.center()
        w.isReleasedWhenClosed = false
        w.isRestorable = false

        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        // Title
        let title = NSTextField(labelWithString: "Weekly limit reached")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 40, y: 230, width: 340, height: 30)
        contentView.addSubview(title)

        // Word count progress
        let used = Settings.shared.wordsThisWeek
        let limit = Settings.shared.freeWeeklyLimit
        let subtitle = NSTextField(wrappingLabelWithString: "You've used \(used) of \(limit) free words this week.\nUpgrade for unlimited dictation, or wait until Monday.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 40, y: 180, width: 340, height: 50)
        contentView.addSubview(subtitle)

        // Progress bar
        let progressBar = NSProgressIndicator(frame: NSRect(x: 60, y: 170, width: 300, height: 6))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = Double(limit)
        progressBar.doubleValue = min(Double(used), Double(limit))
        progressBar.isIndeterminate = false
        contentView.addSubview(progressBar)

        // License key field (per D-12)
        let keyField = NSTextField(frame: NSRect(x: 60, y: 150, width: 300, height: 28))
        keyField.placeholderString = "Enter license key"
        keyField.font = .systemFont(ofSize: 13)
        contentView.addSubview(keyField)

        // Status label
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 60, y: 125, width: 300, height: 20)
        contentView.addSubview(statusLabel)

        // Activate button
        let activateBtn = NSButton(title: "Activate", target: nil, action: nil)
        activateBtn.frame = NSRect(x: 170, y: 85, width: 100, height: 32)
        activateBtn.bezelStyle = .rounded
        activateBtn.keyEquivalent = "\r"  // Enter key
        contentView.addSubview(activateBtn)

        // Upgrade button: opens LemonSqueezy checkout
        let buyBtn = NSButton(title: "Upgrade — $5/mo or $39/yr", target: nil, action: nil)
        buyBtn.frame = NSRect(x: 100, y: 45, width: 220, height: 32)
        buyBtn.bezelStyle = .rounded
        buyBtn.contentTintColor = .controlAccentColor
        contentView.addSubview(buyBtn)

        // OK button — dismiss (app still works, just can't transcribe more this week)
        let okBtn = NSButton(title: "OK", target: nil, action: nil)
        okBtn.frame = NSRect(x: 20, y: 15, width: 80, height: 28)
        okBtn.bezelStyle = .rounded
        contentView.addSubview(okBtn)

        // Wire activate action using a helper class to capture references
        class ActivateHandler: NSObject {
            let keyField: NSTextField
            let statusLabel: NSTextField
            weak var window: NSWindow?
            init(keyField: NSTextField, statusLabel: NSTextField, window: NSWindow?) {
                self.keyField = keyField; self.statusLabel = statusLabel; self.window = window
            }
            @objc func activate() {
                let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    statusLabel.stringValue = "Please enter a license key"
                    statusLabel.textColor = .systemOrange
                    return
                }
                statusLabel.stringValue = "Activating..."
                statusLabel.textColor = .secondaryLabelColor
                LicenseManager.shared.activate(key: key) { [weak self] success, message in
                    self?.statusLabel.stringValue = message
                    self?.statusLabel.textColor = success ? .systemGreen : .systemRed
                    if success {
                        // Per D-14: dismiss modal and app functions normally
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self?.window?.close()
                            LicenseExpiryWindowController.shared.window = nil
                        }
                    }
                }
            }
        }
        let handler = ActivateHandler(keyField: keyField, statusLabel: statusLabel, window: w)
        // Prevent dealloc by storing as associated object
        objc_setAssociatedObject(w, "activateHandler", handler, .OBJC_ASSOCIATION_RETAIN)
        activateBtn.target = handler
        activateBtn.action = #selector(ActivateHandler.activate)

        // Wire buy action
        class BuyHandler: NSObject {
            @objc func buy() {
                if let url = URL(string: LicenseManager.shared.checkoutURL) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        let buyHandler = BuyHandler()
        objc_setAssociatedObject(w, "buyHandler", buyHandler, .OBJC_ASSOCIATION_RETAIN)
        buyBtn.target = buyHandler
        buyBtn.action = #selector(BuyHandler.buy)

        // Wire OK button to dismiss
        class OKHandler: NSObject {
            weak var window: NSWindow?
            init(window: NSWindow?) { self.window = window }
            @objc func dismiss() { window?.close() }
        }
        let okHandler = OKHandler(window: w)
        objc_setAssociatedObject(w, "okHandler", okHandler, .OBJC_ASSOCIATION_RETAIN)
        okBtn.target = okHandler
        okBtn.action = #selector(OKHandler.dismiss)

        w.contentView = contentView
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}

// MARK: - Onboarding Wizard

class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private var currentStep = 0
    private var stepViews: [NSView] = []
    private var progressDots: [NSView] = []
    private var nextButton: NSButton?
    private var accessibilityTimer: Timer?

    func show() {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = createWindow()
        window = w
        showStep(0)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled],  // no close button — user must complete onboarding
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to Voice"
        w.center()
        w.isReleasedWhenClosed = false
        w.isRestorable = false

        guard let contentView = w.contentView else { return w }

        // Build step views
        let welcomeStep = createWelcomeStep(in: contentView)
        let accessibilityStep = createAccessibilityStep(in: contentView)
        let micStep = createMicrophoneStep(in: contentView)
        let testStep = createTestStep(in: contentView)

        stepViews = [welcomeStep, accessibilityStep, micStep, testStep]
        for sv in stepViews {
            sv.isHidden = true
            contentView.addSubview(sv)
        }

        // Progress dots at bottom center
        let dotContainer = NSView(frame: NSRect(x: 160, y: 16, width: 160, height: 16))
        let dotSize: CGFloat = 8
        let dotSpacing: CGFloat = 20
        let totalDotWidth = CGFloat(4) * dotSize + CGFloat(3) * (dotSpacing - dotSize)
        let startX = (160 - totalDotWidth) / 2
        for i in 0..<4 {
            let dot = NSView(frame: NSRect(x: startX + CGFloat(i) * dotSpacing, y: 4, width: dotSize, height: dotSize))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = dotSize / 2
            dot.layer?.backgroundColor = NSColor.lightGray.cgColor
            dotContainer.addSubview(dot)
            progressDots.append(dot)
        }
        contentView.addSubview(dotContainer)

        // Next button (shared across steps, positioned bottom-right)
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

        for (i, sv) in stepViews.enumerated() {
            sv.isHidden = (i != step)
        }

        // Update progress dots
        for (i, dot) in progressDots.enumerated() {
            dot.layer?.backgroundColor = (i == step)
                ? NSColor.controlAccentColor.cgColor
                : NSColor.lightGray.cgColor
        }

        // Update button title and state
        switch step {
        case 0:
            nextButton?.title = "Get Started"
            nextButton?.isEnabled = true
        case 1:
            nextButton?.title = "Next"
            // Disabled until AX granted — startAccessibilityStepPolling manages this
            nextButton?.isEnabled = AXIsProcessTrusted()
            startAccessibilityStepPolling()
        case 2:
            nextButton?.title = "Next"
            // Enabled if mic already authorized
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            nextButton?.isEnabled = (status == .authorized)
        case 3:
            nextButton?.title = "Finish"
            nextButton?.isEnabled = true
        default:
            break
        }
    }

    @objc private func nextStep() {
        let next = currentStep + 1
        if next >= stepViews.count {
            complete()
        } else {
            showStep(next)
        }
    }

    private func complete() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        Settings.shared.onboardingComplete = true
        window?.close()
        window = nil
    }

    // MARK: - Step Builders

    private func createWelcomeStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        // App icon at top center
        let iconView = NSImageView(frame: NSRect(x: 190, y: 190, width: 100, height: 100))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        view.addSubview(iconView)

        // Title
        let title = NSTextField(labelWithString: "Welcome to Voice")
        title.font = NSFont.boldSystemFont(ofSize: 20)
        title.frame = NSRect(x: 40, y: 140, width: 400, height: 40)
        title.alignment = .center
        view.addSubview(title)

        // Subtitle
        let subtitle = NSTextField(wrappingLabelWithString: "Press a key, speak, text appears. All processing happens locally on your Mac.")
        subtitle.font = NSFont.systemFont(ofSize: 14)
        subtitle.textColor = NSColor.secondaryLabelColor
        subtitle.frame = NSRect(x: 60, y: 60, width: 360, height: 70)
        subtitle.alignment = .center
        view.addSubview(subtitle)

        return view
    }

    private func createAccessibilityStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        // Title
        let title = NSTextField(labelWithString: "Accessibility Permission")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 40, y: 240, width: 400, height: 30)
        title.alignment = .center
        view.addSubview(title)

        // Explanation
        let explanation = NSTextField(wrappingLabelWithString: "Voice needs Accessibility permission to detect your hotkey. Without it, Voice can't listen for the fn key press.")
        explanation.font = NSFont.systemFont(ofSize: 14)
        explanation.textColor = NSColor.secondaryLabelColor
        explanation.frame = NSRect(x: 40, y: 160, width: 400, height: 70)
        explanation.alignment = .center
        view.addSubview(explanation)

        // Open System Settings button
        let openBtn = NSButton(frame: NSRect(x: 155, y: 115, width: 170, height: 32))
        openBtn.title = "Open System Settings"
        openBtn.bezelStyle = .rounded
        openBtn.target = self
        openBtn.action = #selector(openAccessibilitySettings)
        view.addSubview(openBtn)

        // Status label
        let statusLabel = NSTextField(labelWithString: "Waiting for permission...")
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = NSColor.systemOrange
        statusLabel.frame = NSRect(x: 40, y: 75, width: 400, height: 28)
        statusLabel.alignment = .center
        statusLabel.identifier = NSUserInterfaceItemIdentifier("axStatusLabel")
        view.addSubview(statusLabel)

        // Trigger system prompt
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary)

        return view
    }

    private func createMicrophoneStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        // Title
        let title = NSTextField(labelWithString: "Microphone Permission")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 40, y: 240, width: 400, height: 30)
        title.alignment = .center
        view.addSubview(title)

        // Explanation
        let explanation = NSTextField(wrappingLabelWithString: "Voice records your speech locally using your Mac's microphone. No audio ever leaves your device.")
        explanation.font = NSFont.systemFont(ofSize: 14)
        explanation.textColor = NSColor.secondaryLabelColor
        explanation.frame = NSRect(x: 40, y: 160, width: 400, height: 70)
        explanation.alignment = .center
        view.addSubview(explanation)

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            let statusLabel = NSTextField(labelWithString: "Microphone permission granted!")
            statusLabel.font = NSFont.systemFont(ofSize: 13)
            statusLabel.textColor = NSColor.systemGreen
            statusLabel.frame = NSRect(x: 40, y: 105, width: 400, height: 28)
            statusLabel.alignment = .center
            view.addSubview(statusLabel)
        } else if status == .denied {
            let instructions = NSTextField(wrappingLabelWithString: "Microphone access was denied. Please go to System Settings > Privacy & Security > Microphone and enable Voice.")
            instructions.font = NSFont.systemFont(ofSize: 13)
            instructions.textColor = NSColor.systemRed
            instructions.frame = NSRect(x: 40, y: 85, width: 400, height: 55)
            instructions.alignment = .center
            view.addSubview(instructions)
        } else {
            // .notDetermined or other
            let grantBtn = NSButton(frame: NSRect(x: 165, y: 110, width: 150, height: 32))
            grantBtn.title = "Grant Permission"
            grantBtn.bezelStyle = .rounded
            grantBtn.target = self
            grantBtn.action = #selector(requestMicrophoneAccess)
            view.addSubview(grantBtn)

            let statusLabel = NSTextField(labelWithString: "Microphone access required")
            statusLabel.font = NSFont.systemFont(ofSize: 13)
            statusLabel.textColor = NSColor.systemOrange
            statusLabel.frame = NSRect(x: 40, y: 75, width: 400, height: 28)
            statusLabel.alignment = .center
            statusLabel.identifier = NSUserInterfaceItemIdentifier("micStatusLabel")
            view.addSubview(statusLabel)
        }

        return view
    }

    private func createTestStep(in container: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 50, width: 480, height: 300))

        // Title
        let title = NSTextField(labelWithString: "Test Your Setup")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        title.frame = NSRect(x: 40, y: 240, width: 400, height: 30)
        title.alignment = .center
        view.addSubview(title)

        // Instruction
        let instruction = NSTextField(wrappingLabelWithString: "Press the button below and say a few words. We'll transcribe them to confirm everything works.")
        instruction.font = NSFont.systemFont(ofSize: 14)
        instruction.textColor = NSColor.secondaryLabelColor
        instruction.frame = NSRect(x: 40, y: 170, width: 400, height: 65)
        instruction.alignment = .center
        view.addSubview(instruction)

        // Start Test button
        let testBtn = NSButton(frame: NSRect(x: 175, y: 125, width: 130, height: 32))
        testBtn.title = "Start Test"
        testBtn.bezelStyle = .rounded
        testBtn.target = self
        testBtn.action = #selector(startTestRecording)
        testBtn.identifier = NSUserInterfaceItemIdentifier("testBtn")
        view.addSubview(testBtn)

        // Status label
        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.frame = NSRect(x: 40, y: 90, width: 400, height: 28)
        statusLabel.alignment = .center
        statusLabel.identifier = NSUserInterfaceItemIdentifier("testStatusLabel")
        view.addSubview(statusLabel)

        // Result text field
        let resultField = NSTextField(wrappingLabelWithString: "")
        resultField.font = NSFont.systemFont(ofSize: 13)
        resultField.textColor = NSColor.labelColor
        resultField.frame = NSRect(x: 40, y: 50, width: 400, height: 36)
        resultField.alignment = .center
        resultField.identifier = NSUserInterfaceItemIdentifier("testResultField")
        view.addSubview(resultField)

        return view
    }

    // MARK: - Accessibility Step Polling

    private func startAccessibilityStepPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if AXIsProcessTrusted() {
                self.accessibilityTimer?.invalidate()
                self.accessibilityTimer = nil
                // Update status label to green
                if let stepView = self.stepViews.indices.contains(1) ? self.stepViews[1] : nil {
                    for subview in stepView.subviews {
                        if let label = subview as? NSTextField,
                           label.identifier?.rawValue == "axStatusLabel" {
                            label.stringValue = "Permission granted!"
                            label.textColor = NSColor.systemGreen
                            break
                        }
                    }
                }
                self.nextButton?.isEnabled = true
                // Auto-advance after 0.5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    if self?.currentStep == 1 {
                        self?.nextStep()
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.nextButton?.isEnabled = true
                    // Update mic step UI
                    if let stepView = self.stepViews.indices.contains(2) ? self.stepViews[2] : nil {
                        for subview in stepView.subviews {
                            if let label = subview as? NSTextField,
                               label.identifier?.rawValue == "micStatusLabel" {
                                label.stringValue = "Microphone permission granted!"
                                label.textColor = NSColor.systemGreen
                                break
                            }
                        }
                    }
                    // Auto-advance
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        if self?.currentStep == 2 {
                            self?.nextStep()
                        }
                    }
                }
            }
        }
    }

    @objc private func startTestRecording() {
        guard let stepView = stepViews.indices.contains(3) ? stepViews[3] : nil else { return }

        // Update UI
        for subview in stepView.subviews {
            if let label = subview as? NSTextField,
               label.identifier?.rawValue == "testStatusLabel" {
                label.stringValue = "Listening..."
                label.textColor = NSColor.secondaryLabelColor
            }
            if let label = subview as? NSTextField,
               label.identifier?.rawValue == "testResultField" {
                label.stringValue = ""
            }
            if let btn = subview as? NSButton,
               btn.identifier?.rawValue == "testBtn" {
                btn.isEnabled = false
            }
        }
        nextButton?.isEnabled = false

        guard let delegate = NSApp.delegate as? AppDelegate else { return }

        // Start recording using AppDelegate's methods
        delegate.startRecording()

        // Stop after 3 seconds and transcribe
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }

            // Update status
            for subview in stepView.subviews {
                if let label = subview as? NSTextField,
                   label.identifier?.rawValue == "testStatusLabel" {
                    label.stringValue = "Transcribing..."
                }
            }

            delegate.stopRecording()

            // Poll for transcription result (wait up to 10s)
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
            if let label = subview as? NSTextField,
               label.identifier?.rawValue == "testStatusLabel" {
                if let text = transcription, !text.isEmpty {
                    label.stringValue = "Everything works! You're all set."
                    label.textColor = NSColor.systemGreen
                } else {
                    label.stringValue = "Something went wrong. You can try again or finish setup."
                    label.textColor = NSColor.systemOrange
                }
            }
            if let label = subview as? NSTextField,
               label.identifier?.rawValue == "testResultField" {
                label.stringValue = transcription ?? ""
            }
            if let btn = subview as? NSButton,
               btn.identifier?.rawValue == "testBtn" {
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
    private var modelPopup: NSPopUpButton!
    private var ollamaStatusLabel: NSTextField!
    private var ollamaInstallButton: NSButton!
    private var testButton: NSButton!
    private var testResultLabel: NSTextField!

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
    private var whisperPopup: NSPopUpButton!
    private var downloadButton: NSButton!
    private var downloadStatusLabel: NSTextField!
    private var saveTranscriptsCheckbox: NSButton!
    private var transcriptDirLabel: NSTextField!
    private var transcriptSearchField: NSSearchField!
    private var transcriptTableView: NSTableView!
    private var transcriptResults: [(date: Date, text: String, path: String)] = []
    private var transcriptCountLabel: NSTextField!

    // License tab controls
    private var licenseStatusLabel = NSTextField(labelWithString: "")
    private var licenseKeyField = NSTextField()
    private var activateButton = NSButton(title: "Activate", target: nil, action: nil)
    private var deactivateButton = NSButton(title: "Deactivate", target: nil, action: nil)
    private var licenseResultLabel = NSTextField(labelWithString: "")

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabView = NSTabView(frame: view.bounds.insetBy(dx: 12, dy: 12))
        tabView.autoresizingMask = [.width, .height]
        view.addSubview(tabView)

        tabView.addTabViewItem(makeAudioTab())
        tabView.addTabViewItem(makeGeneralTab())
        tabView.addTabViewItem(makeAITab())
        tabView.addTabViewItem(makeTranscriptionTab())
        tabView.addTabViewItem(makeLicenseTab())

        // Listen for audio device changes (per D-06: live mic list updates)
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &propAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.refreshMicList()
        }
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
        addLabel("POPO timeout (minutes):", at: NSPoint(x: 20, y: y), in: container)
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

        // Reset to defaults — bottom right
        let resetBtn = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        resetBtn.frame = NSRect(x: 290, y: 12, width: 140, height: 24)
        resetBtn.bezelStyle = .rounded
        resetBtn.controlSize = .small
        resetBtn.font = NSFont.systemFont(ofSize: 11)
        container.addSubview(resetBtn)

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

        addLabel("Sensitivity:", at: NSPoint(x: 40, y: y + 2), in: container)
        sensitivitySlider = NSSlider(value: Double(Settings.shared.overlaySensitivity), minValue: 5, maxValue: 80, target: self, action: #selector(sensitivityChanged))
        sensitivitySlider.frame = NSRect(x: 140, y: y, width: 120, height: 22)
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        var y: CGFloat = 260

        // Local AI text cleanup
        aiEnabledCheckbox = NSButton(checkboxWithTitle: "Local AI text cleanup", target: self, action: #selector(aiEnabledChanged))
        aiEnabledCheckbox.frame = NSRect(x: 20, y: y, width: 220, height: 22)
        aiEnabledCheckbox.state = Settings.shared.aiEnabled ? .on : .off
        container.addSubview(aiEnabledCheckbox)

        y -= 40

        // Model
        addLabel("Ollama model:", at: NSPoint(x: 20, y: y), in: container)
        modelPopup = NSPopUpButton(frame: NSRect(x: 180, y: y - 2, width: 200, height: 26), pullsDown: false)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        container.addSubview(modelPopup)
        populateModelPopup()

        y -= 34

        // Ollama status + install (hidden unless Ollama provider selected and unreachable)
        ollamaStatusLabel = NSTextField(labelWithString: "")
        ollamaStatusLabel.frame = NSRect(x: 20, y: y, width: 200, height: 22)
        ollamaStatusLabel.textColor = .systemOrange
        ollamaStatusLabel.font = NSFont.systemFont(ofSize: 12)
        ollamaStatusLabel.isHidden = true
        container.addSubview(ollamaStatusLabel)

        ollamaInstallButton = NSButton(title: "Install Ollama", target: self, action: #selector(installOllama))
        ollamaInstallButton.frame = NSRect(x: 230, y: y - 2, width: 150, height: 24)
        ollamaInstallButton.bezelStyle = .rounded
        ollamaInstallButton.font = NSFont.systemFont(ofSize: 11)
        ollamaInstallButton.isHidden = true
        container.addSubview(ollamaInstallButton)

        y -= 44

        // Test connection button
        testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testButton.frame = NSRect(x: 20, y: y, width: 140, height: 28)
        testButton.bezelStyle = .rounded
        container.addSubview(testButton)

        testResultLabel = NSTextField(labelWithString: "")
        testResultLabel.frame = NSRect(x: 170, y: y + 4, width: 260, height: 22)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.font = NSFont.systemFont(ofSize: 11)
        testResultLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(testResultLabel)

        item.view = container
        return item
    }

    // MARK: - Transcription Tab

    private func makeTranscriptionTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "transcription")
        item.label = "Transcription"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 350))

        var y: CGFloat = 282

        // Whisper model — compact row
        addLabel("Model:", at: NSPoint(x: 20, y: y), in: container)
        whisperPopup = NSPopUpButton(frame: NSRect(x: 75, y: y - 2, width: 200, height: 24), pullsDown: false)
        let models = ["large-v3-turbo-q5_0", "small.en", "medium.en", "large-v3"]
        for m in models { whisperPopup.addItem(withTitle: m) }
        whisperPopup.selectItem(withTitle: Settings.shared.whisperModel)
        whisperPopup.target = self
        whisperPopup.action = #selector(whisperModelChanged)
        container.addSubview(whisperPopup)

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

    // MARK: - License Tab

    private func makeLicenseTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "license")
        item.label = "License"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        var y: CGFloat = 255

        // Status indicator
        addLabel("Status:", at: NSPoint(x: 20, y: y), in: container)
        licenseStatusLabel.frame = NSRect(x: 180, y: y, width: 250, height: 22)
        licenseStatusLabel.font = .systemFont(ofSize: 13)
        updateLicenseStatusLabel()
        container.addSubview(licenseStatusLabel)

        y -= 44

        // License key field
        addLabel("License key:", at: NSPoint(x: 20, y: y), in: container)
        licenseKeyField.frame = NSRect(x: 180, y: y - 2, width: 230, height: 26)
        licenseKeyField.placeholderString = "XXXX-XXXX-XXXX-XXXX"
        licenseKeyField.font = .systemFont(ofSize: 13)
        if !Settings.shared.licenseKey.isEmpty {
            licenseKeyField.stringValue = Settings.shared.licenseKey
        }
        container.addSubview(licenseKeyField)

        y -= 44

        // Activate button
        activateButton.frame = NSRect(x: 180, y: y, width: 100, height: 28)
        activateButton.bezelStyle = .rounded
        activateButton.target = self
        activateButton.action = #selector(activateLicense)
        container.addSubview(activateButton)

        // Deactivate button (only useful when licensed)
        deactivateButton.frame = NSRect(x: 290, y: y, width: 120, height: 28)
        deactivateButton.bezelStyle = .rounded
        deactivateButton.target = self
        deactivateButton.action = #selector(deactivateLicense)
        deactivateButton.isEnabled = Settings.shared.hasStoredLicenseCredentials
        container.addSubview(deactivateButton)

        y -= 36

        // Result label
        licenseResultLabel.frame = NSRect(x: 20, y: y, width: 410, height: 20)
        licenseResultLabel.font = .systemFont(ofSize: 12)
        licenseResultLabel.alignment = .left
        container.addSubview(licenseResultLabel)

        y -= 50

        // Buy button — solid blue
        let buyBtn = NSButton(title: "Buy Voice ($29)", target: self, action: #selector(openCheckout))
        buyBtn.frame = NSRect(x: 20, y: y, width: 410, height: 36)
        buyBtn.bezelStyle = .rounded
        buyBtn.wantsLayer = true
        buyBtn.layer?.backgroundColor = NSColor.systemBlue.cgColor
        buyBtn.layer?.cornerRadius = 8
        buyBtn.contentTintColor = .white
        buyBtn.isBordered = false
        buyBtn.font = NSFont.boldSystemFont(ofSize: 14)
        let attrTitle = NSAttributedString(string: "Buy Voice ($29)", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.boldSystemFont(ofSize: 14)
        ])
        buyBtn.attributedTitle = attrTitle
        container.addSubview(buyBtn)

        item.view = container
        return item
    }

    private func updateLicenseStatusLabel() {
        let state = LicenseManager.shared.currentState
        licenseStatusLabel.stringValue = LicenseManager.shared.statusText
        switch state {
        case .licensed: licenseStatusLabel.textColor = .systemGreen
        case .offlineGrace: licenseStatusLabel.textColor = .systemYellow
        case .free: licenseStatusLabel.textColor = .controlAccentColor
        case .limitReached, .invalid: licenseStatusLabel.textColor = .systemRed
        }
    }

    @objc private func activateLicense() {
        let key = licenseKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            licenseResultLabel.stringValue = "Please enter a license key"
            licenseResultLabel.textColor = .systemOrange
            return
        }
        licenseResultLabel.stringValue = "Activating..."
        licenseResultLabel.textColor = .secondaryLabelColor
        activateButton.isEnabled = false
        LicenseManager.shared.activate(key: key) { [weak self] success, message in
            self?.licenseResultLabel.stringValue = message
            self?.licenseResultLabel.textColor = success ? .systemGreen : .systemRed
            self?.activateButton.isEnabled = true
            self?.deactivateButton.isEnabled = Settings.shared.hasStoredLicenseCredentials
            self?.updateLicenseStatusLabel()
        }
    }

    @objc private func deactivateLicense() {
        LicenseManager.shared.deactivate()
        licenseKeyField.stringValue = ""
        licenseResultLabel.stringValue = "License deactivated"
        licenseResultLabel.textColor = .secondaryLabelColor
        deactivateButton.isEnabled = false
        updateLicenseStatusLabel()
    }

    @objc private func openCheckout() {
        if let url = URL(string: LicenseManager.shared.checkoutURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func addLabel(_ text: String, at point: NSPoint, in container: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: point.x, y: point.y, width: 160, height: 22)
        container.addSubview(label)
        return label
    }

    private func populateModelPopup() {
        modelPopup.removeAllItems()
        let saved = Settings.shared.aiModel
        modelPopup.addItem(withTitle: saved)
        fetchOllamaModels()
        modelPopup.selectItem(withTitle: saved)
        updateOllamaStatus()
    }

    private func fetchOllamaModels() {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                if error != nil {
                    DispatchQueue.main.async { self?.updateOllamaStatus() }
                }
                return
            }
            let names = models.compactMap { $0["name"] as? String }.sorted()
            guard !names.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let saved = self.modelPopup.selectedItem?.title ?? Settings.shared.aiModel
                self.modelPopup.removeAllItems()
                self.modelPopup.addItems(withTitles: names)
                if self.modelPopup.item(withTitle: saved) == nil {
                    self.modelPopup.addItem(withTitle: saved)
                }
                self.modelPopup.selectItem(withTitle: saved)
            }
        }.resume()
    }

    private func updateOllamaStatus() {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.ollamaStatusLabel.isHidden = true
                    self.ollamaInstallButton.isHidden = true
                } else {
                    self.ollamaStatusLabel.stringValue = "Ollama not found"
                    self.ollamaStatusLabel.textColor = .systemOrange
                    self.ollamaStatusLabel.isHidden = false
                    self.ollamaInstallButton.isHidden = false
                    self.ollamaInstallButton.isEnabled = true
                    self.ollamaInstallButton.title = "Install Ollama"
                }
            }
        }.resume()
    }

    private func updateDownloadButton() {
        let path = Settings.shared.whisperModelPath
        let exists = FileManager.default.fileExists(atPath: path)
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
        alert.informativeText = "This will reset all settings to their defaults. Your license and saved transcripts will not be affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Settings.shared.resetAll()

        // Refresh all visible controls
        hotkeyPopup?.selectItem(at: 0)
        soundsCheckbox?.state = .on
        autoStartCheckbox?.state = .on
        popoStepper?.integerValue = 5
        popoLabel?.stringValue = "5"
        clipboardCheckbox?.state = .on
        aiEnabledCheckbox?.state = .on
        populateModelPopup()
        testResultLabel?.stringValue = ""
        overlayEnabledCheckbox?.state = .on
        overlayAppNameCheckbox?.state = .on
        overlayAppIconCheckbox?.state = .on
        overlayBgSlider?.doubleValue = 0.6
        overlayBgLabel?.stringValue = "60%"
        overlayFontSizeSegment?.selectedSegment = 1  // Medium
        sensitivitySlider?.doubleValue = 30
        sensitivityLabel?.stringValue = "30x"
        overlayPreview?.fontSize = 13
        overlayPreview?.resizeToFit()
        refreshMicList()

        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.inputMonitor.reloadHotkey()
        }
    }

    @objc private func aiEnabledChanged() {
        Settings.shared.aiEnabled = aiEnabledCheckbox.state == .on
    }

    @objc private func modelChanged() {
        if let title = modelPopup.selectedItem?.title {
            Settings.shared.aiModel = title
        }
    }

    @objc private func testConnection() {
        testResultLabel.stringValue = "Testing..."
        testResultLabel.textColor = .secondaryLabelColor

        let client = OllamaClient()
        client.testConnection { [weak self] success, message in
            DispatchQueue.main.async {
                self?.testResultLabel.stringValue = message
                self?.testResultLabel.textColor = success ? .systemGreen : .systemRed
            }
        }
    }

    @objc private func installOllama() {
        ollamaInstallButton.isEnabled = false
        ollamaStatusLabel.stringValue = "Installing Ollama..."
        ollamaStatusLabel.textColor = .secondaryLabelColor

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Step 1: brew install ollama
            let brewInstall = Process()
            brewInstall.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
            brewInstall.arguments = ["install", "ollama"]
            let installPipe = Pipe()
            brewInstall.standardOutput = installPipe
            brewInstall.standardError = installPipe

            do {
                try brewInstall.run()
                brewInstall.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self?.ollamaStatusLabel.stringValue = "Install failed: \(error.localizedDescription)"
                    self?.ollamaStatusLabel.textColor = .systemRed
                    self?.ollamaInstallButton.isEnabled = true
                }
                return
            }

            guard brewInstall.terminationStatus == 0 else {
                let data = installPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                let firstLine = output.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? "brew install failed"
                DispatchQueue.main.async {
                    self?.ollamaStatusLabel.stringValue = firstLine
                    self?.ollamaStatusLabel.textColor = .systemRed
                    self?.ollamaInstallButton.isEnabled = true
                }
                return
            }

            // Step 2: Start Ollama via brew services
            DispatchQueue.main.async {
                self?.ollamaStatusLabel.stringValue = "Starting Ollama..."
            }

            let brewStart = Process()
            brewStart.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
            brewStart.arguments = ["services", "start", "ollama"]
            brewStart.standardOutput = FileHandle.nullDevice
            brewStart.standardError = FileHandle.nullDevice
            try? brewStart.run()
            brewStart.waitUntilExit()

            // Wait for the server to be ready
            Thread.sleep(forTimeInterval: 3.0)

            // Step 3: Pull default model
            DispatchQueue.main.async {
                self?.ollamaStatusLabel.stringValue = "Pulling llama3.2:3b model..."
            }

            let pull = Process()
            pull.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
            pull.arguments = ["pull", "llama3.2:3b"]
            let pullPipe = Pipe()
            pull.standardOutput = pullPipe
            pull.standardError = pullPipe

            do {
                try pull.run()
                pull.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self?.ollamaStatusLabel.stringValue = "Model pull failed: \(error.localizedDescription)"
                    self?.ollamaStatusLabel.textColor = .systemRed
                    self?.ollamaInstallButton.isEnabled = true
                }
                return
            }

            guard pull.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    self?.ollamaStatusLabel.stringValue = "Model pull failed"
                    self?.ollamaStatusLabel.textColor = .systemRed
                    self?.ollamaInstallButton.isEnabled = true
                }
                return
            }

            // Success
            DispatchQueue.main.async {
                self?.ollamaStatusLabel.stringValue = "Ollama ready!"
                self?.ollamaStatusLabel.textColor = .systemGreen
                self?.ollamaInstallButton.isHidden = true
                self?.populateModelPopup()
                // Hide status after a few seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self?.ollamaStatusLabel.isHidden = true
                }
            }
        }
    }

    @objc private func whisperModelChanged() {
        if let title = whisperPopup.selectedItem?.title {
            Settings.shared.whisperModel = title
        }
        updateDownloadButton()
    }

    @objc private func downloadModel() {
        let modelName = Settings.shared.whisperModel
        let modelDir = NSHomeDirectory() + "/Library/Application Support/Voice/Models"
        let modelFile = "\(modelDir)/ggml-\(modelName).bin"
        let urlString = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(modelName).bin"

        downloadButton.isEnabled = false
        downloadStatusLabel.stringValue = "Downloading \(modelName)..."
        downloadStatusLabel.textColor = .secondaryLabelColor

        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: modelDir, withIntermediateDirectories: true)

        guard let url = URL(string: urlString) else {
            downloadStatusLabel.stringValue = "Invalid URL"
            downloadStatusLabel.textColor = .systemRed
            downloadButton.isEnabled = true
            return
        }

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                self?.downloadButton.isEnabled = true

                if let error = error {
                    self?.downloadStatusLabel.stringValue = "Error: \(error.localizedDescription)"
                    self?.downloadStatusLabel.textColor = .systemRed
                    return
                }

                guard let tempURL = tempURL else {
                    self?.downloadStatusLabel.stringValue = "Download failed"
                    self?.downloadStatusLabel.textColor = .systemRed
                    return
                }

                do {
                    // Remove existing file if present
                    if FileManager.default.fileExists(atPath: modelFile) {
                        try FileManager.default.removeItem(atPath: modelFile)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: modelFile))
                    self?.downloadStatusLabel.stringValue = "Download complete"
                    self?.downloadStatusLabel.textColor = .systemGreen
                    self?.updateDownloadButton()
                } catch {
                    self?.downloadStatusLabel.stringValue = "Error: \(error.localizedDescription)"
                    self?.downloadStatusLabel.textColor = .systemRed
                }
            }
        }
        task.resume()
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var appState: AppState = .idle
    var audioEngine: AVAudioEngine?
    var isRestartingEngine = false
    var audioFileHandle: FileHandle?
    var audioDataSize: UInt32 = 0
    var currentAudioLevel: Float = 0.0  // Exposed for waveform overlay (Plan 03)
    var zeroBufferCount: Int = 0
    var zeroSignalWarningShown: Bool = false
    var audioFile: String?
    var previousApp: NSRunningApplication?  // saved before recording to refocus for paste

    var whisperPath: String {
        let bundled = Bundle.main.resourcePath! + "/whisper-cli"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        return "/opt/homebrew/bin/whisper-cli"
    }
    let afplayPath = "/usr/bin/afplay"

    let inputMonitor = InputMonitor()
    let textInjector = TextInjector()
    let ollamaClient = OllamaClient()
    let overlayWindow = OverlayWindow()

    var popoTimer: Timer?

    var dismissTimer: Timer?
    var lastTranscription: String?

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

        // Trial/license status (per D-10) — show for non-licensed users
        let licenseState = LicenseManager.shared.currentState
        if case .licensed = licenseState {
            // Clean menu for licensed users — no status shown
        } else {
            let licenseStatusItem = NSMenuItem(title: LicenseManager.shared.statusText, action: nil, keyEquivalent: "")
            licenseStatusItem.isEnabled = false
            menu.addItem(licenseStatusItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Settings & Quit
        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        if #available(macOS 14.0, *) { settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) }
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Voice", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        // Link text injector to input monitor so it can disable event tap during paste
        textInjector.inputMonitor = inputMonitor

        // Setup input monitor
        inputMonitor.onRecordStart = { [weak self] in
            guard LicenseManager.shared.canRecord else {
                DispatchQueue.main.async {
                    LicenseExpiryWindowController.shared.show()
                }
                return
            }
            self?.startRecording()
        }
        inputMonitor.onRecordStop = { [weak self] in
            self?.stopRecording()
        }
        inputMonitor.onCancel = { [weak self] in
            self?.cancelRecording()
        }
        inputMonitor.onPopoStart = { [weak self] in
            guard LicenseManager.shared.canRecord else {
                DispatchQueue.main.async {
                    LicenseExpiryWindowController.shared.show()
                }
                return
            }
            self?.startPopo()
        }
        inputMonitor.onPopoStop = { [weak self] in
            self?.stopPopo()
        }

        // First-launch onboarding (per D-05)
        if !Settings.shared.onboardingComplete {
            OnboardingWindowController.shared.show()
        }

        // License enforcement (per D-07, D-11)
        LicenseManager.shared.validateIfNeeded()
        if !LicenseManager.shared.canRecord {
            LicenseExpiryWindowController.shared.show()
        }

        // Start accessibility polling for auto-restart (per D-19, D-20)
        startAccessibilityPolling()

        inputMonitor.reloadHotkey()
        if !inputMonitor.start() {
            if Settings.shared.onboardingComplete {
                // Only show notification if onboarding already done (onboarding handles its own UX)
                showNotification(title: "Voice", body: "Accessibility permission required. Add Voice.app in System Settings > Privacy & Security > Accessibility.")
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            // AX polling timer (started above) will handle relaunch when permission is granted
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
            // If currently recording, restart the engine with the new device
            if case .recording = self.appState {
                NSLog("Voice: restarting engine mid-recording due to device change")
                self.audioEngine?.inputNode.removeTap(onBus: 0)
                self.audioEngine?.stop()
                self.audioEngine = nil
                // Small delay for the new device to settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if case .recording = self.appState {
                        self.restartRecordingEngine()
                    }
                }
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

        // License validation for existing subscribers
        LicenseManager.shared.validateIfNeeded()

        // Preflight checks
        if !FileManager.default.fileExists(atPath: Settings.shared.whisperModelPath) {
            showNotification(title: "Voice", body: "Whisper model not found at \(Settings.shared.whisperModelPath)")
        }

        // Ollama health check and warmup for local cleanup.
        if Settings.shared.aiEnabled {
            ollamaClient.healthCheck { [weak self] available in
                if available {
                    self?.ollamaClient.warmup()
                }
            }
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
            // Pass target app context (per D-14, D-15)
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

    // MARK: - Recording

    func startRecording() {
        guard case .idle = appState else { return }

        // Reset zero-signal detection state (per D-08)
        zeroBufferCount = 0
        zeroSignalWarningShown = false

        // Save the currently focused app so we can refocus it before pasting
        previousApp = NSWorkspace.shared.frontmostApplication

        // Show feedback immediately — before engine start
        appState = .recording
        inputMonitor.setRecording(true)
        updateIcon()
        showOverlay(state: .recording)
        if Settings.shared.soundsEnabled { playSound("Tink") }

        let tempFile = NSTemporaryDirectory() + "voice_\(ProcessInfo.processInfo.globallyUniqueString).wav"
        audioFile = tempFile

        // Create WAV file with 44-byte placeholder header
        FileManager.default.createFile(atPath: tempFile, contents: Data(count: 44))
        guard let handle = FileHandle(forWritingAtPath: tempFile) else {
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to create audio file")
            return
        }
        handle.seek(toFileOffset: 44)
        audioFileHandle = handle
        audioDataSize = 0

        var engine = AVAudioEngine()
        var inputNode = engine.inputNode

        // Set selected microphone via CoreAudio (per D-05/D-07)
        let selectedUID = Settings.shared.micDeviceUID
        if !selectedUID.isEmpty {
            let devices = listInputDevices()
            if let device = devices.first(where: { $0.uid == selectedUID }) {
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
                // Per D-07: selected mic disappeared, fall back to system default silently
                NSLog("Voice: Preferred mic %@ not found, using system default", selectedUID)
            }
        }

        var hwFormat = inputNode.outputFormat(forBus: 0)
        NSLog("Voice: hwFormat — sampleRate=%.0f channels=%d", hwFormat.sampleRate, hwFormat.channelCount)

        // If format is invalid (0 channels / 0 sample rate), the device selection failed silently.
        // Reset to system default and retry with a fresh engine.
        if hwFormat.channelCount == 0 || hwFormat.sampleRate == 0 {
            NSLog("Voice: invalid hwFormat — resetting mic to system default")
            Settings.shared.micDeviceUID = ""
            engine = AVAudioEngine()
            inputNode = engine.inputNode
            hwFormat = inputNode.outputFormat(forBus: 0)
            NSLog("Voice: retry hwFormat — sampleRate=%.0f channels=%d", hwFormat.sampleRate, hwFormat.channelCount)
        }

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "No valid microphone found")
            NSLog("Voice: FATAL — no valid audio format even with system default mic")
            return
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to create audio format")
            return
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to create audio converter (hw: \(hwFormat))")
            NSLog("Voice: converter creation failed — hwFormat=%@", hwFormat.description)
            return
        }

        var tapCallCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            tapCallCount += 1
            // Convert to 16kHz mono Int16
            let ratio = 16000.0 / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            if tapCallCount <= 3 {
                NSLog("Voice: tap#%d bufFrames=%d ratio=%.4f capacity=%d fileHandleNil=%d",
                      tapCallCount, Int(buffer.frameLength), ratio, Int(capacity), self.audioFileHandle == nil ? 1 : 0)
            }
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            if tapCallCount <= 3 {
                NSLog("Voice: tap#%d converted frameLength=%d error=%@",
                      tapCallCount, Int(convertedBuffer.frameLength), error?.localizedDescription ?? "nil")
            }
            if error == nil, let channelData = convertedBuffer.int16ChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: frameCount * 2)
                self.audioFileHandle?.write(data)
                self.audioDataSize += UInt32(frameCount * 2)
                // Calculate RMS level from Int16 data for waveform visualization
                var sum: Float = 0
                for i in 0..<frameCount {
                    let sample = Float(channelData[0][i]) / 32768.0
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(max(frameCount, 1)))
                // Zero-signal detection for AirPods/Bluetooth (per D-08)
                DispatchQueue.main.async {
                    self.currentAudioLevel = rms
                    if rms < 0.0001 {
                        self.zeroBufferCount += 1
                        // ~2 seconds of silence at 16kHz with 4096 buffer = ~8 buffers
                        if self.zeroBufferCount > 8 && !self.zeroSignalWarningShown {
                            self.zeroSignalWarningShown = true
                            self.showOverlay(state: .error("No audio detected \u{2014} check your microphone"))
                            // Auto-dismiss warning after 3 seconds and return to recording overlay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                if self.appState == .recording {
                                    self.showOverlay(state: .recording)
                                }
                            }
                        }
                    } else {
                        self.zeroBufferCount = 0
                    }
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.audioEngine = engine
            NSLog("Voice: engine started OK — sampleRate=%.0f channels=%d format=%@",
                  hwFormat.sampleRate, hwFormat.channelCount, hwFormat.description)
        } catch {
            inputNode.removeTap(onBus: 0)
            audioFileHandle?.closeFile()
            audioFileHandle = nil
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to start recording: \(error.localizedDescription)")
            NSLog("Voice: engine.start() FAILED: %@", error.localizedDescription)
        }
    }

    // Re-create AVAudioEngine mid-recording after device change (Bluetooth reconnect)
    func restartRecordingEngine() {
        isRestartingEngine = true
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.isRestartingEngine = false } }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let selectedUID = Settings.shared.micDeviceUID
        if !selectedUID.isEmpty {
            let devices = listInputDevices()
            if let device = devices.first(where: { $0.uid == selectedUID }) {
                var deviceID = device.deviceID
                AudioUnitSetProperty(
                    inputNode.audioUnit!,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
        }

        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            NSLog("Voice: restartRecordingEngine — failed to create format/converter")
            return
        }

        var tapCallCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            tapCallCount += 1
            let ratio = 16000.0 / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            if error == nil, let channelData = convertedBuffer.int16ChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: frameCount * 2)
                self.audioFileHandle?.write(data)
                self.audioDataSize += UInt32(frameCount * 2)
                var sum: Float = 0
                for i in 0..<frameCount {
                    let sample = Float(channelData[0][i]) / 32768.0
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(max(frameCount, 1)))
                DispatchQueue.main.async { self.currentAudioLevel = rms }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.audioEngine = engine
            NSLog("Voice: engine restarted OK after device change — sampleRate=%.0f", hwFormat.sampleRate)
        } catch {
            inputNode.removeTap(onBus: 0)
            NSLog("Voice: restartRecordingEngine FAILED: %@", error.localizedDescription)
        }
    }

    func stopRecording() {
        guard case .recording = appState else { return }

        NSLog("Voice: stopRecording — audioDataSize=%d audioFile=%@", audioDataSize, audioFile ?? "nil")
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        // Delay dealloc — AVAudioIOUnit dispatch queue may have in-flight callbacks
        let engineRef = audioEngine
        audioEngine = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = engineRef }
        // Finalize WAV header with actual data size
        if let handle = audioFileHandle {
            writeWAVHeader(to: handle, dataSize: audioDataSize)
            handle.closeFile()
        }
        audioFileHandle = nil

        appState = .processing
        inputMonitor.setRecording(false)
        updateIcon()
        showOverlay(state: .transcribing)
        if Settings.shared.soundsEnabled { playSound("Pop") }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribeAndProcess()
        }
    }

    func cancelRecording() {
        guard case .recording = appState else {
            // Also handle cancel during POPO
            if case .popo = appState {
                cancelPopo()
            }
            return
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        let engineRef = audioEngine
        audioEngine = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = engineRef }
        audioFileHandle?.closeFile()
        audioFileHandle = nil

        if let file = audioFile {
            cleanup(file)
        }
        audioFile = nil

        appState = .idle
        inputMonitor.setRecording(false)
        updateIcon()
        hideOverlay()
        if Settings.shared.soundsEnabled { playSound("Funk") }
    }

    // MARK: - POPO Mode

    func startPopo() {
        NSLog("Voice: startPopo called — appState=\(appState)")
        guard case .idle = appState else {
            NSLog("Voice: startPopo BLOCKED — appState is not idle")
            return
        }

        // Reset zero-signal detection state (per D-08)
        zeroBufferCount = 0
        zeroSignalWarningShown = false

        previousApp = NSWorkspace.shared.frontmostApplication

        // Show feedback immediately — before engine start
        appState = .popo
        inputMonitor.setRecording(true)
        inputMonitor.setPopo(true)
        updateIcon()
        showOverlay(state: .popo)
        if Settings.shared.soundsEnabled { playSound("Morse") }

        let tempFile = NSTemporaryDirectory() + "voice_\(ProcessInfo.processInfo.globallyUniqueString).wav"
        audioFile = tempFile

        // Create WAV file with 44-byte placeholder header
        FileManager.default.createFile(atPath: tempFile, contents: Data(count: 44))
        guard let handle = FileHandle(forWritingAtPath: tempFile) else {
            appState = .idle
            inputMonitor.setRecording(false)
            inputMonitor.setPopo(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to create audio file")
            return
        }
        handle.seek(toFileOffset: 44)
        audioFileHandle = handle
        audioDataSize = 0

        var engine = AVAudioEngine()
        var inputNode = engine.inputNode

        // Set selected microphone via CoreAudio (per D-05/D-07)
        let selectedUID = Settings.shared.micDeviceUID
        if !selectedUID.isEmpty {
            let devices = listInputDevices()
            if let device = devices.first(where: { $0.uid == selectedUID }) {
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
                    NSLog("Voice: POPO — Failed to set mic device %@ (status %d), using default", selectedUID, status)
                }
            } else {
                NSLog("Voice: POPO — Preferred mic %@ not found, using system default", selectedUID)
            }
        }

        var hwFormat = inputNode.outputFormat(forBus: 0)
        NSLog("Voice: POPO hwFormat — sampleRate=%.0f channels=%d", hwFormat.sampleRate, hwFormat.channelCount)

        // If format is invalid, reset to system default
        if hwFormat.channelCount == 0 || hwFormat.sampleRate == 0 {
            NSLog("Voice: POPO invalid hwFormat — resetting mic to system default")
            Settings.shared.micDeviceUID = ""
            engine = AVAudioEngine()
            inputNode = engine.inputNode
            hwFormat = inputNode.outputFormat(forBus: 0)
            NSLog("Voice: POPO retry hwFormat — sampleRate=%.0f channels=%d", hwFormat.sampleRate, hwFormat.channelCount)
        }

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            audioFileHandle?.closeFile()
            audioFileHandle = nil
            appState = .idle
            inputMonitor.setRecording(false)
            inputMonitor.setPopo(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "No valid microphone found")
            return
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            audioFileHandle?.closeFile()
            audioFileHandle = nil
            appState = .idle
            inputMonitor.setRecording(false)
            inputMonitor.setPopo(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let ratio = 16000.0 / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 1)) else { return }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            if error == nil, let channelData = convertedBuffer.int16ChannelData {
                let frameCount = Int(convertedBuffer.frameLength)
                let data = Data(bytes: channelData[0], count: frameCount * 2)
                self.audioFileHandle?.write(data)
                self.audioDataSize += UInt32(frameCount * 2)
                // Calculate RMS level from Int16 data for waveform visualization
                var sum: Float = 0
                for i in 0..<frameCount {
                    let sample = Float(channelData[0][i]) / 32768.0
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(max(frameCount, 1)))
                // Zero-signal detection for AirPods/Bluetooth (per D-08)
                DispatchQueue.main.async {
                    self.currentAudioLevel = rms
                    if rms < 0.0001 {
                        self.zeroBufferCount += 1
                        // ~2 seconds of silence at 16kHz with 4096 buffer = ~8 buffers
                        if self.zeroBufferCount > 8 && !self.zeroSignalWarningShown {
                            self.zeroSignalWarningShown = true
                            self.showOverlay(state: .error("No audio detected \u{2014} check your microphone"))
                            // Auto-dismiss warning after 3 seconds and return to popo overlay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                                if self.appState == .popo {
                                    self.showOverlay(state: .popo)
                                }
                            }
                        }
                    } else {
                        self.zeroBufferCount = 0
                    }
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.audioEngine = engine

            // Safety timeout
            let timeout = Settings.shared.popoTimeoutSeconds
            popoTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.stopPopo()
                    self?.showNotification(title: "Voice", body: "POPO mode auto-stopped after \(Settings.shared.popoTimeout) minutes.")
                }
            }
        } catch {
            inputNode.removeTap(onBus: 0)
            audioFileHandle?.closeFile()
            audioFileHandle = nil
            appState = .idle
            inputMonitor.setRecording(false)
            inputMonitor.setPopo(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopPopo() {
        guard case .popo = appState else { return }

        popoTimer?.invalidate()
        popoTimer = nil
        inputMonitor.setPopo(false)

        guard audioEngine != nil else {
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            return
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        let popoEngineRef = audioEngine
        audioEngine = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = popoEngineRef }
        // Finalize WAV header with actual data size
        if let handle = audioFileHandle {
            writeWAVHeader(to: handle, dataSize: audioDataSize)
            handle.closeFile()
        }
        audioFileHandle = nil

        appState = .processing
        inputMonitor.setRecording(false)
        updateIcon()
        showOverlay(state: .transcribing)
        if Settings.shared.soundsEnabled { playSound("Submarine") }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribeAndProcess()
        }
    }

    func cancelPopo() {
        popoTimer?.invalidate()
        popoTimer = nil
        inputMonitor.setPopo(false)

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        let cancelPopoEngineRef = audioEngine
        audioEngine = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = cancelPopoEngineRef }
        audioFileHandle?.closeFile()
        audioFileHandle = nil

        if let file = audioFile {
            cleanup(file)
        }
        audioFile = nil

        appState = .idle
        inputMonitor.setRecording(false)
        updateIcon()
        hideOverlay()
        if Settings.shared.soundsEnabled { playSound("Funk") }
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = [
            "--model", Settings.shared.whisperModelPath,
            "--file", audioFile,
            "--no-timestamps",
            "--threads", "8",
            "--language", "en"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            var rawText = String(data: data, encoding: .utf8) ?? ""
            rawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = rawText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            rawText = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            // Fix common whisper punctuation issues: ensure space after . , ! ? : ;
            rawText = rawText.replacingOccurrences(
                of: "([.!?,;:])([A-Za-z])",
                with: "$1 $2",
                options: .regularExpression
            )

            if rawText.isEmpty {
                finishProcessing(error: "Empty transcription")
                cleanup(audioFile)
                return
            }

            // Count words and check free tier limit
            let wordCount = rawText.split(separator: " ").count
            Settings.shared.addWords(wordCount)
            if !LicenseManager.shared.canRecord {
                let errorMessage: String
                switch LicenseManager.shared.currentState {
                case .limitReached:
                    errorMessage = "Weekly limit reached"
                case .invalid:
                    errorMessage = "License invalid"
                case .free, .licensed, .offlineGrace:
                    errorMessage = "Recording unavailable"
                }
                DispatchQueue.main.async {
                    LicenseExpiryWindowController.shared.show()
                }
                finishProcessing(error: errorMessage)
                cleanup(audioFile)
                return
            }

            // If AI cleanup is disabled, inject raw text directly
            guard Settings.shared.aiEnabled else {
                DispatchQueue.main.async { [weak self] in
                    self?.refocusAndInject(rawText)
                    self?.finishProcessing(text: rawText)
                }
                cleanup(audioFile)
                return
            }

            let context = AppContext.current()
            ollamaClient.cleanupText(rawText, appContext: context) { [weak self] cleanedText in
                DispatchQueue.main.async {
                    self?.refocusAndInject(cleanedText)
                    self?.finishProcessing(text: cleanedText)
                }
            }
        } catch {
            finishProcessing(error: error.localizedDescription)
        }

        cleanup(audioFile)
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

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    // NSMenuDelegate — rebuild mic submenu each time menu opens
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Update license status text in menu
        if let item = menu.items.first(where: { $0.title.hasPrefix("Trial:") || $0.title == "Trial expired" || $0.title.hasPrefix("Licensed") || $0.title == "License invalid" }) {
            item.title = LicenseManager.shared.statusText
        }

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

// Disable macOS window restoration BEFORE app.run() — restoration happens during run(),
// before applicationDidFinishLaunching, so this must be set early.
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
// Nuke any saved state left over from a previous run
let savedStatePath = NSHomeDirectory() + "/Library/Saved Application State/com.faradaysoft.voice.savedState"
try? FileManager.default.removeItem(atPath: savedStatePath)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
