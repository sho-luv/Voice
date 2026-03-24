import Cocoa
import ApplicationServices
import UserNotifications
import AVFoundation
import CoreAudio

// MARK: - App State

enum AppState {
    case idle
    case recording
    case popo          // POPO lock mode (continuous until fn tap)
    case processing
}

// MARK: - AI Provider

enum AIProvider: String, CaseIterable {
    case ollama = "Ollama (local)"
    case openai = "OpenAI"
    case anthropic = "Anthropic"
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
            "aiProvider": AIProvider.ollama.rawValue,
            "aiModelOllama": "llama3.2:3b",
            "aiModelOpenAI": "gpt-4o-mini",
            "aiModelAnthropic": "claude-sonnet-4-20250514",
            "apiKeyOpenAI": "",
            "apiKeyAnthropic": "",
            "whisperModel": "large-v3-turbo-q5_0",
            "micDeviceUID": "",
            "overlayShowAppName": true,
            "overlayShowAppIcon": true,
            "overlayShowWindowTitle": false,
            "overlayShowTimer": true,
        ])
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

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .ollama }
        set { defaults.set(newValue.rawValue, forKey: "aiProvider") }
    }

    var aiModel: String {
        get {
            switch aiProvider {
            case .ollama:    return defaults.string(forKey: "aiModelOllama") ?? "llama3.2:3b"
            case .openai:    return defaults.string(forKey: "aiModelOpenAI") ?? "gpt-4o-mini"
            case .anthropic: return defaults.string(forKey: "aiModelAnthropic") ?? "claude-sonnet-4-20250514"
            }
        }
        set {
            switch aiProvider {
            case .ollama:    defaults.set(newValue, forKey: "aiModelOllama")
            case .openai:    defaults.set(newValue, forKey: "aiModelOpenAI")
            case .anthropic: defaults.set(newValue, forKey: "aiModelAnthropic")
            }
        }
    }

    var apiKey: String {
        get {
            switch aiProvider {
            case .ollama:    return ""
            case .openai:    return defaults.string(forKey: "apiKeyOpenAI") ?? ""
            case .anthropic: return defaults.string(forKey: "apiKeyAnthropic") ?? ""
            }
        }
        set {
            switch aiProvider {
            case .ollama:    break
            case .openai:    defaults.set(newValue, forKey: "apiKeyOpenAI")
            case .anthropic: defaults.set(newValue, forKey: "apiKeyAnthropic")
            }
        }
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

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: "onboardingComplete") }
        set { defaults.set(newValue, forKey: "onboardingComplete") }
    }

    // Trial & License
    var trialStartDate: Date? {
        get { defaults.object(forKey: "trialStartDate") as? Date }
        set { defaults.set(newValue, forKey: "trialStartDate") }
    }

    var licenseKey: String {
        get { defaults.string(forKey: "licenseKey") ?? "" }
        set { defaults.set(newValue, forKey: "licenseKey") }
    }

    var licenseInstanceId: String {
        get { defaults.string(forKey: "licenseInstanceId") ?? "" }
        set { defaults.set(newValue, forKey: "licenseInstanceId") }
    }

    var isLicensed: Bool {
        get { defaults.bool(forKey: "isLicensed") }
        set { defaults.set(newValue, forKey: "isLicensed") }
    }

    var lastLicenseValidation: Date? {
        get { defaults.object(forKey: "lastLicenseValidation") as? Date }
        set { defaults.set(newValue, forKey: "lastLicenseValidation") }
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

// MARK: - AIClient Protocol

protocol AIClient {
    func cleanupText(_ text: String, appContext: AppContext, completion: @escaping (String) -> Void)
    func testConnection(completion: @escaping (Bool, String) -> Void)
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

        // Track Space key state (for POPO activation)
        if type == .keyDown && keyCode == 49 {
            monitor.spaceHeld = true
            return Unmanaged.passRetained(event)
        }
        if type == .keyUp && keyCode == 49 {
            monitor.spaceHeld = false
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

        if keyPressed && !monitor.fnDown {
            // Key DOWN
            monitor.fnDown = true
            monitor.fnDownTime = ProcessInfo.processInfo.systemUptime

            // In POPO mode, tap stops it
            if monitor.isPopo {
                DispatchQueue.main.async { monitor.onPopoStop?() }
                return nil  // swallow
            }

            // Space+key -> POPO mode
            if monitor.spaceHeld && !monitor.isRecording {
                DispatchQueue.main.async { monitor.onPopoStart?() }
                return nil  // swallow
            }

            // Start recording (push-to-talk)
            if !monitor.isRecording {
                DispatchQueue.main.async { monitor.onRecordStart?() }
            }
            return nil  // swallow to prevent emoji picker / other default behavior

        } else if !keyPressed && monitor.fnDown {
            // Key UP
            monitor.fnDown = false
            let holdDuration = ProcessInfo.processInfo.systemUptime - monitor.fnDownTime

            // In POPO mode, don't stop on release
            if monitor.isPopo {
                return nil  // swallow
            }

            // If held too briefly, cancel rather than transcribe garbage
            if monitor.isRecording && holdDuration < monitor.minHoldDuration {
                DispatchQueue.main.async { monitor.onCancel?() }
                return nil
            }

            // Stop recording (push-to-talk release)
            if monitor.isRecording {
                DispatchQueue.main.async { monitor.onRecordStop?() }
            }
            return nil  // swallow
        }

        return Unmanaged.passRetained(event)
    }
}

// MARK: - Overlay Window

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
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.maxY - frame.height - 12
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
            let amplified = min(Float(1.0), level * 12.0)
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        path.fill()

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
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]
        let fullText = icon + " " + text
        let size = fullText.size(withAttributes: attrs)
        let textPoint = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        fullText.draw(at: textPoint, withAttributes: attrs)
    }

    private func drawRecordingOverlay() {
        var x: CGFloat = 12

        // Red dot (recording) or blue dot (POPO)
        let isRecordingState: Bool
        if case .recording = overlayState { isRecordingState = true } else { isRecordingState = false }
        let dotColor: NSColor = isRecordingState
            ? NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
            : NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0)
        let dotSize: CGFloat = 8
        let dotRect = NSRect(x: x, y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)
        dotColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        x += dotSize + 6

        let textAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)
        ]
        let smallAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.7, alpha: 1.0),
            .font: NSFont.systemFont(ofSize: 10, weight: .regular)
        ]

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
            x += min(nameSize.width, 60) + 8  // cap app name width to avoid overflow
        }

        // Waveform bars — WhatsApp-style: center bars tallest, mirrored outward
        let barCount = 7  // visible bars (odd number for center symmetry)
        let barWidth: CGFloat = 3.0
        let barGap: CGFloat = 2.0
        let maxBarHeight: CGFloat = bounds.height * 0.7
        let minBarHeight: CGFloat = 4.0
        let waveformWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap

        // Build mirrored levels: center gets latest (loudest), sides get older/quieter
        // audioLevels has 12 samples; pick recent ones and mirror around center
        let center = barCount / 2  // index 3 of 0-6
        var barLevels = [Float](repeating: 0, count: barCount)
        let latest = audioLevels.count - 1
        // Center bar = most recent level
        barLevels[center] = audioLevels[latest]
        // Mirror outward: each step from center uses an older sample, slightly reduced
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
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            let timerStr = String(format: "%d:%02d", minutes, seconds) as NSString
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

class OllamaClient: AIClient {
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

// MARK: - OpenAI Client

class OpenAIClient: AIClient {
    func cleanupText(_ text: String, appContext: AppContext, completion: @escaping (String) -> Void) {
        let apiKey = Settings.shared.apiKey
        guard !apiKey.isEmpty else {
            completion(text)
            return
        }

        let truncated = String(text.prefix(4000))
        let systemPrompt = cleanupSystemPrompt(appContext: appContext)

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": Settings.shared.aiModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": truncated]
            ],
            "temperature": 0.1,
            "max_tokens": 2048
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                completion(text)
                return
            }
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(cleaned.isEmpty ? text : cleaned)
        }.resume()
    }

    func testConnection(completion: @escaping (Bool, String) -> Void) {
        let apiKey = Settings.shared.apiKey
        guard !apiKey.isEmpty else {
            completion(false, "No API key set")
            return
        }

        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            completion(false, "Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "Error: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(false, "No response")
                return
            }
            if httpResponse.statusCode == 200 {
                completion(true, "Connected to OpenAI, model: \(Settings.shared.aiModel)")
            } else if httpResponse.statusCode == 401 {
                completion(false, "Invalid API key")
            } else {
                completion(false, "HTTP \(httpResponse.statusCode)")
            }
        }.resume()
    }
}

// MARK: - Anthropic Client

class AnthropicClient: AIClient {
    func cleanupText(_ text: String, appContext: AppContext, completion: @escaping (String) -> Void) {
        let apiKey = Settings.shared.apiKey
        guard !apiKey.isEmpty else {
            completion(text)
            return
        }

        let truncated = String(text.prefix(4000))
        let systemPrompt = cleanupSystemPrompt(appContext: appContext)

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(text)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": Settings.shared.aiModel,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": truncated]
            ],
            "temperature": 0.1,
            "max_tokens": 2048
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let responseText = first["text"] as? String else {
                completion(text)
                return
            }
            let cleaned = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(cleaned.isEmpty ? text : cleaned)
        }.resume()
    }

    func testConnection(completion: @escaping (Bool, String) -> Void) {
        let apiKey = Settings.shared.apiKey
        guard !apiKey.isEmpty else {
            completion(false, "No API key set")
            return
        }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            completion(false, "Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": Settings.shared.aiModel,
            "messages": [["role": "user", "content": "Hi"]],
            "max_tokens": 1
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(false, "Error: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(false, "No response")
                return
            }
            if httpResponse.statusCode == 200 {
                completion(true, "Connected to Anthropic, model: \(Settings.shared.aiModel)")
            } else if httpResponse.statusCode == 401 {
                completion(false, "Invalid API key")
            } else {
                completion(false, "HTTP \(httpResponse.statusCode)")
            }
        }.resume()
    }
}

// MARK: - License Manager

enum LicenseState {
    case trial(daysLeft: Int)
    case trialExpired
    case licensed
    case offlineGrace  // licensed but can't re-validate, working but warning
    case invalid
}

class LicenseManager {
    static let shared = LicenseManager()

    // IMPORTANT: Replace these with actual values from LemonSqueezy dashboard
    // User must retrieve from: LemonSqueezy Dashboard -> Products -> Voice
    private let lsStoreId: Int = 0       // TODO: Set from LemonSqueezy dashboard
    private let lsProductId: Int = 0     // TODO: Set from LemonSqueezy dashboard
    let checkoutURL = "https://voice.lemonsqueezy.com/checkout"  // TODO: Set actual URL

    private let trialDays = 14
    private let revalidationIntervalDays = 7
    private let offlineGraceDays = 3

    private init() {
        // Set trial start date on very first launch
        if Settings.shared.trialStartDate == nil {
            Settings.shared.trialStartDate = Date()
        }
    }

    // MARK: - State

    var currentState: LicenseState {
        // If licensed, check revalidation
        if Settings.shared.isLicensed && !Settings.shared.licenseKey.isEmpty {
            if let lastCheck = Settings.shared.lastLicenseValidation {
                let daysSince = Date().timeIntervalSince(lastCheck) / 86400
                if daysSince > Double(revalidationIntervalDays + offlineGraceDays) {
                    return .invalid  // too long without validation
                } else if daysSince > Double(revalidationIntervalDays) {
                    return .offlineGrace
                }
            }
            return .licensed
        }

        // Trial logic
        guard let startDate = Settings.shared.trialStartDate else {
            return .trial(daysLeft: trialDays)
        }
        let elapsed = Date().timeIntervalSince(startDate) / 86400
        let daysLeft = trialDays - Int(elapsed)
        if daysLeft > 0 {
            return .trial(daysLeft: daysLeft)
        } else {
            return .trialExpired
        }
    }

    var canRecord: Bool {
        switch currentState {
        case .trial, .licensed, .offlineGrace:
            return true
        case .trialExpired, .invalid:
            return false
        }
    }

    var trialDaysRemaining: Int? {
        if case .trial(let days) = currentState { return days }
        return nil
    }

    var statusText: String {
        switch currentState {
        case .trial(let days): return "Trial: \(days) day\(days == 1 ? "" : "s") left"
        case .trialExpired: return "Trial expired"
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

            // Verify store_id matches (prevent cross-product key use)
            let meta = json["meta"] as? [String: Any]
            let storeId = meta?["store_id"] as? Int
            if self.lsStoreId != 0 && storeId != self.lsStoreId {
                DispatchQueue.main.async { completion(false, "Invalid license key for this product") }
                return
            }

            if activated, let instanceId = instanceId, licenseStatus == "active" {
                Settings.shared.licenseKey = key
                Settings.shared.licenseInstanceId = instanceId
                Settings.shared.isLicensed = true
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
        guard Settings.shared.isLicensed, !Settings.shared.licenseKey.isEmpty else { return }
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
                Settings.shared.isLicensed = false
            }
        }.resume()
    }

    // MARK: - Deactivation

    func deactivate() {
        Settings.shared.licenseKey = ""
        Settings.shared.licenseInstanceId = ""
        Settings.shared.isLicensed = false
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

        // Title: "Your trial has ended" (per D-11)
        let title = NSTextField(labelWithString: "Your trial has ended")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 40, y: 230, width: 340, height: 30)
        contentView.addSubview(title)

        // Subtitle
        let subtitle = NSTextField(wrappingLabelWithString: "Enter your license key to continue using Voice, or purchase a license.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 40, y: 190, width: 340, height: 40)
        contentView.addSubview(subtitle)

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

        // Buy button (per D-13): opens LemonSqueezy checkout
        let buyBtn = NSButton(title: "Buy Voice ($29)", target: nil, action: nil)
        buyBtn.frame = NSRect(x: 130, y: 45, width: 160, height: 32)
        buyBtn.bezelStyle = .rounded
        buyBtn.contentTintColor = .controlAccentColor
        contentView.addSubview(buyBtn)

        // Quit button
        let quitBtn = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quitBtn.frame = NSRect(x: 20, y: 15, width: 80, height: 28)
        quitBtn.bezelStyle = .rounded
        contentView.addSubview(quitBtn)

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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
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

class SettingsViewController: NSViewController {
    private let openaiModels = ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "o4-mini"]
    private let anthropicModels = ["claude-sonnet-4-20250514", "claude-haiku-4-20250414", "claude-opus-4-20250514"]

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
    private var providerPopup: NSPopUpButton!
    private var modelPopup: NSPopUpButton!
    private var ollamaStatusLabel: NSTextField!
    private var ollamaInstallButton: NSButton!
    private var apiKeyLabel: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var testButton: NSButton!
    private var testResultLabel: NSTextField!

    // Audio tab controls
    private var micPopup: NSPopUpButton!
    private var micStatusLabel: NSTextField!
    private var overlayAppNameCheckbox: NSButton!
    private var overlayAppIconCheckbox: NSButton!
    private var overlayWindowTitleCheckbox: NSButton!
    private var overlayTimerCheckbox: NSButton!

    // Transcription tab controls
    private var whisperPopup: NSPopUpButton!
    private var downloadButton: NSButton!
    private var downloadStatusLabel: NSTextField!

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

        item.view = container
        return item
    }

    // MARK: - Audio Tab

    private func makeAudioTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "audio")
        item.label = "Audio"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        var y: CGFloat = 260

        // Microphone selector
        addLabel("Microphone:", at: NSPoint(x: 20, y: y), in: container)
        micPopup = NSPopUpButton(frame: NSRect(x: 180, y: y - 2, width: 240, height: 26), pullsDown: false)
        micPopup.target = self
        micPopup.action = #selector(micChanged)
        container.addSubview(micPopup)
        refreshMicList()

        y -= 26
        micStatusLabel = NSTextField(labelWithString: "")
        micStatusLabel.frame = NSRect(x: 180, y: y, width: 240, height: 16)
        micStatusLabel.font = NSFont.systemFont(ofSize: 10)
        micStatusLabel.textColor = .secondaryLabelColor
        container.addSubview(micStatusLabel)

        y -= 40

        // Overlay display options section header
        addLabel("Overlay Display:", at: NSPoint(x: 20, y: y), in: container)
        y -= 30

        overlayAppNameCheckbox = NSButton(checkboxWithTitle: "Show app name", target: self, action: #selector(overlaySettingChanged))
        overlayAppNameCheckbox.frame = NSRect(x: 40, y: y, width: 200, height: 22)
        overlayAppNameCheckbox.state = Settings.shared.overlayShowAppName ? .on : .off
        container.addSubview(overlayAppNameCheckbox)
        y -= 28

        overlayAppIconCheckbox = NSButton(checkboxWithTitle: "Show app icon", target: self, action: #selector(overlaySettingChanged))
        overlayAppIconCheckbox.frame = NSRect(x: 40, y: y, width: 200, height: 22)
        overlayAppIconCheckbox.state = Settings.shared.overlayShowAppIcon ? .on : .off
        container.addSubview(overlayAppIconCheckbox)
        y -= 28

        overlayWindowTitleCheckbox = NSButton(checkboxWithTitle: "Show window title", target: self, action: #selector(overlaySettingChanged))
        overlayWindowTitleCheckbox.frame = NSRect(x: 40, y: y, width: 200, height: 22)
        overlayWindowTitleCheckbox.state = Settings.shared.overlayShowWindowTitle ? .on : .off
        container.addSubview(overlayWindowTitleCheckbox)
        y -= 28

        overlayTimerCheckbox = NSButton(checkboxWithTitle: "Show recording timer", target: self, action: #selector(overlaySettingChanged))
        overlayTimerCheckbox.frame = NSRect(x: 40, y: y, width: 200, height: 22)
        overlayTimerCheckbox.state = Settings.shared.overlayShowTimer ? .on : .off
        container.addSubview(overlayTimerCheckbox)

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
        Settings.shared.overlayShowAppName = overlayAppNameCheckbox.state == .on
        Settings.shared.overlayShowAppIcon = overlayAppIconCheckbox.state == .on
        Settings.shared.overlayShowWindowTitle = overlayWindowTitleCheckbox.state == .on
        Settings.shared.overlayShowTimer = overlayTimerCheckbox.state == .on
    }

    // MARK: - AI Tab

    private func makeAITab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "ai")
        item.label = "AI"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        var y: CGFloat = 260

        // AI text cleanup
        aiEnabledCheckbox = NSButton(checkboxWithTitle: "AI text cleanup", target: self, action: #selector(aiEnabledChanged))
        aiEnabledCheckbox.frame = NSRect(x: 20, y: y, width: 200, height: 22)
        aiEnabledCheckbox.state = Settings.shared.aiEnabled ? .on : .off
        container.addSubview(aiEnabledCheckbox)

        y -= 40

        // Provider
        addLabel("Provider:", at: NSPoint(x: 20, y: y), in: container)
        providerPopup = NSPopUpButton(frame: NSRect(x: 180, y: y - 2, width: 200, height: 26), pullsDown: false)
        for provider in AIProvider.allCases {
            providerPopup.addItem(withTitle: provider.rawValue)
        }
        providerPopup.selectItem(withTitle: Settings.shared.aiProvider.rawValue)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        container.addSubview(providerPopup)

        y -= 40

        // Model
        addLabel("Model:", at: NSPoint(x: 20, y: y), in: container)
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

        y -= 34

        // API Key
        apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 20, y: y, width: 150, height: 22)
        container.addSubview(apiKeyLabel)

        apiKeyField = NSSecureTextField(frame: NSRect(x: 180, y: y - 2, width: 200, height: 24))
        apiKeyField.stringValue = Settings.shared.apiKey
        apiKeyField.target = self
        apiKeyField.action = #selector(apiKeyChanged)
        container.addSubview(apiKeyField)

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

        updateAPIKeyVisibility()

        item.view = container
        return item
    }

    // MARK: - Transcription Tab

    private func makeTranscriptionTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "transcription")
        item.label = "Transcription"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        var y: CGFloat = 260

        // Whisper model
        addLabel("Whisper model:", at: NSPoint(x: 20, y: y), in: container)
        whisperPopup = NSPopUpButton(frame: NSRect(x: 180, y: y - 2, width: 200, height: 26), pullsDown: false)
        let models = ["large-v3-turbo-q5_0", "small.en", "medium.en", "large-v3"]
        for m in models {
            whisperPopup.addItem(withTitle: m)
        }
        whisperPopup.selectItem(withTitle: Settings.shared.whisperModel)
        whisperPopup.target = self
        whisperPopup.action = #selector(whisperModelChanged)
        container.addSubview(whisperPopup)

        y -= 44

        // Download button
        downloadButton = NSButton(title: "Download Model", target: self, action: #selector(downloadModel))
        downloadButton.frame = NSRect(x: 20, y: y, width: 140, height: 28)
        downloadButton.bezelStyle = .rounded
        container.addSubview(downloadButton)

        downloadStatusLabel = NSTextField(labelWithString: "")
        downloadStatusLabel.frame = NSRect(x: 170, y: y + 4, width: 260, height: 22)
        downloadStatusLabel.textColor = .secondaryLabelColor
        downloadStatusLabel.font = NSFont.systemFont(ofSize: 11)
        downloadStatusLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(downloadStatusLabel)

        updateDownloadButton()

        item.view = container
        return item
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
        deactivateButton.isEnabled = Settings.shared.isLicensed
        container.addSubview(deactivateButton)

        y -= 36

        // Result label
        licenseResultLabel.frame = NSRect(x: 20, y: y, width: 410, height: 20)
        licenseResultLabel.font = .systemFont(ofSize: 12)
        licenseResultLabel.alignment = .left
        container.addSubview(licenseResultLabel)

        y -= 50

        // Buy button
        let buyBtn = NSButton(title: "Buy Voice ($29)", target: self, action: #selector(openCheckout))
        buyBtn.frame = NSRect(x: 20, y: y, width: 150, height: 28)
        buyBtn.bezelStyle = .rounded
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
        case .trial: licenseStatusLabel.textColor = .controlAccentColor
        case .trialExpired, .invalid: licenseStatusLabel.textColor = .systemRed
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
            self?.deactivateButton.isEnabled = Settings.shared.isLicensed
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

        switch Settings.shared.aiProvider {
        case .openai:
            modelPopup.addItems(withTitles: openaiModels)
        case .anthropic:
            modelPopup.addItems(withTitles: anthropicModels)
        case .ollama:
            modelPopup.addItem(withTitle: saved)
            fetchOllamaModels()
        }

        if modelPopup.item(withTitle: saved) == nil {
            modelPopup.addItem(withTitle: saved)
        }
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

    private func updateAPIKeyVisibility() {
        let needsKey = Settings.shared.aiProvider != .ollama
        apiKeyLabel.isHidden = !needsKey
        apiKeyField.isHidden = !needsKey
    }

    private func updateOllamaStatus() {
        guard Settings.shared.aiProvider == .ollama else {
            ollamaStatusLabel.isHidden = true
            ollamaInstallButton.isHidden = true
            return
        }

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

    @objc private func aiEnabledChanged() {
        Settings.shared.aiEnabled = aiEnabledCheckbox.state == .on
    }

    @objc private func providerChanged() {
        if let title = providerPopup.selectedItem?.title,
           let provider = AIProvider.allCases.first(where: { $0.rawValue == title }) {
            Settings.shared.aiProvider = provider
        }
        // Update model popup, API key visibility, and Ollama status for new provider
        populateModelPopup()
        apiKeyField.stringValue = Settings.shared.apiKey
        updateAPIKeyVisibility()
        updateOllamaStatus()
        testResultLabel.stringValue = ""
    }

    @objc private func modelChanged() {
        if let title = modelPopup.selectedItem?.title {
            Settings.shared.aiModel = title
        }
    }

    @objc private func apiKeyChanged() {
        Settings.shared.apiKey = apiKeyField.stringValue
    }

    @objc private func testConnection() {
        testResultLabel.stringValue = "Testing..."
        testResultLabel.textColor = .secondaryLabelColor

        let client: AIClient
        switch Settings.shared.aiProvider {
        case .ollama:    client = OllamaClient()
        case .openai:    client = OpenAIClient()
        case .anthropic: client = AnthropicClient()
        }

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
        let popoItem = NSMenuItem(title: "  POPO Mode", action: nil, keyEquivalent: "")
        popoItem.isEnabled = false
        if #available(macOS 14.0, *) { popoItem.image = NSImage(systemSymbolName: "mic.badge.plus", accessibilityDescription: nil) }
        menu.addItem(popoItem)

        menu.addItem(NSMenuItem.separator())

        // Actions
        let pasteItem = NSMenuItem(title: "Paste Last Transcription", action: #selector(pasteLast), keyEquivalent: "v")
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
        if #available(macOS 14.0, *) { settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) }
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Voice", action: #selector(quitApp), keyEquivalent: "q")
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

        // Preflight checks
        if !FileManager.default.fileExists(atPath: Settings.shared.whisperModelPath) {
            showNotification(title: "Voice", body: "Whisper model not found at \(Settings.shared.whisperModelPath)")
        }

        // Ollama health check and warmup (only if Ollama is the selected provider)
        if Settings.shared.aiProvider == .ollama {
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

    func startAccessibilityPolling() {
        wasAccessibilityGranted = AXIsProcessTrusted()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Skip checks for 5 seconds after wake — AXIsProcessTrusted can flicker
            if Date().timeIntervalSince(self.lastWakeTime) < 5.0 { return }
            let isNowGranted = AXIsProcessTrusted()
            guard isNowGranted != self.wasAccessibilityGranted else { return }
            self.wasAccessibilityGranted = isNowGranted
            if isNowGranted {
                // Permission was just granted — relaunch to re-create event tap
                self.relaunchSilently()
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

    func makeWaveformImage() -> NSImage {
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
        NSColor.black.setFill()
        for i in 0..<barCount {
            let bh = maxH * heights[i]
            let x = startX + CGFloat(i) * (barW + gap)
            let y = centerY - bh / 2.0
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: bh),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        switch appState {
        case .idle:
            button.title = ""
            button.image = makeWaveformImage()
        case .recording:
            button.image = nil
            button.title = "\u{1F534}"  // red circle
        case .popo:
            button.image = nil
            button.title = "\u{1F535}"  // blue circle
        case .processing:
            button.image = nil
            button.title = "\u{23F3}"   // hourglass
        }
    }

    // MARK: - Overlay

    func showOverlay(state: OverlayState) {
        dismissTimer?.invalidate()
        dismissTimer = nil

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

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

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

        let hwFormat = inputNode.outputFormat(forBus: 0)
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
            showNotification(title: "Voice", body: "Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            // Convert to 16kHz mono Int16
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
        } catch {
            inputNode.removeTap(onBus: 0)
            audioFileHandle?.closeFile()
            audioFileHandle = nil
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard case .recording = appState else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
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
        audioEngine = nil
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
        guard case .idle = appState else { return }

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

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

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

        let hwFormat = inputNode.outputFormat(forBus: 0)
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
        audioEngine = nil
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
        audioEngine = nil
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

            if rawText.isEmpty {
                finishProcessing(error: "Empty transcription")
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
            let client: AIClient
            switch Settings.shared.aiProvider {
            case .ollama:    client = ollamaClient
            case .openai:    client = OpenAIClient()
            case .anthropic: client = AnthropicClient()
            }

            client.cleanupText(rawText, appContext: context) { [weak self] cleanedText in
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
