import Cocoa
import ApplicationServices
import UserNotifications

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
            "whisperModel": "small.en",
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
        get { defaults.string(forKey: "whisperModel") ?? "small.en" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    var whisperModelPath: String {
        NSHomeDirectory() + "/.local/share/whisper-models/ggml-\(whisperModel).bin"
    }

    private func updateLaunchAgent(enabled: Bool) {
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.local.voice.plist"
        if enabled {
            // Find the current executable
            let execPath = Bundle.main.executablePath ?? "\(NSHomeDirectory())/home/projects/voice/Voice.app/Contents/MacOS/Voice"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.local.voice</string>
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

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: InputMonitor.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
        let frame = NSRect(x: 0, y: 0, width: 220, height: 44)
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

    private var pulseTimer: Timer?
    private var pulseAlpha: CGFloat = 1.0
    private var pulseDirection: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func startPulse() {
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulseAlpha += self.pulseDirection * 0.04
            if self.pulseAlpha <= 0.3 { self.pulseDirection = 1 }
            if self.pulseAlpha >= 1.0 { self.pulseDirection = -1 }
            self.needsDisplay = true
        }
    }

    func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseAlpha = 1.0
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]

        let text: String
        let indicator: String

        switch overlayState {
        case .recording:
            indicator = "\u{25CF}"  // filled circle
            text = " Recording..."
            // Draw pulsing red dot
            let dotRect = NSRect(x: 14, y: bounds.midY - 5, width: 10, height: 10)
            NSColor(red: 1.0, green: 0.2, blue: 0.2, alpha: pulseAlpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            let textPoint = NSPoint(x: 30, y: bounds.midY - 8)
            text.draw(at: textPoint, withAttributes: attrs)
            return

        case .popo:
            indicator = "\u{25CF}"
            text = " POPO Mode..."
            let dotRect = NSRect(x: 14, y: bounds.midY - 5, width: 10, height: 10)
            NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: pulseAlpha).setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            let textPoint = NSPoint(x: 30, y: bounds.midY - 8)
            text.draw(at: textPoint, withAttributes: attrs)
            return

        case .transcribing:
            indicator = "\u{23F3}"
            text = " Transcribing..."
        case .done(let preview):
            indicator = "\u{2713}"
            let truncated = preview.count > 25 ? String(preview.prefix(25)) + "..." : preview
            text = " " + truncated
        case .error(let msg):
            indicator = "\u{2717}"
            let truncated = msg.count > 25 ? String(msg.prefix(25)) + "..." : msg
            text = " " + truncated
        }

        let fullText = indicator + text
        let size = fullText.size(withAttributes: attrs)
        let textPoint = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
        fullText.draw(at: textPoint, withAttributes: attrs)
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
    private var modelField: NSTextField!
    private var apiKeyLabel: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var testButton: NSButton!
    private var testResultLabel: NSTextField!

    // Transcription tab controls
    private var whisperPopup: NSPopUpButton!
    private var downloadButton: NSButton!
    private var downloadStatusLabel: NSTextField!

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabView = NSTabView(frame: view.bounds.insetBy(dx: 12, dy: 12))
        tabView.autoresizingMask = [.width, .height]
        view.addSubview(tabView)

        tabView.addTabViewItem(makeGeneralTab())
        tabView.addTabViewItem(makeAITab())
        tabView.addTabViewItem(makeTranscriptionTab())
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
        modelField = NSTextField(frame: NSRect(x: 180, y: y - 2, width: 200, height: 24))
        modelField.stringValue = Settings.shared.aiModel
        modelField.target = self
        modelField.action = #selector(modelChanged)
        container.addSubview(modelField)

        y -= 40

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
        let models = ["small.en", "medium.en", "large-v3"]
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

    // MARK: - Helpers

    @discardableResult
    private func addLabel(_ text: String, at point: NSPoint, in container: NSView) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: point.x, y: point.y, width: 160, height: 22)
        container.addSubview(label)
        return label
    }

    private func updateAPIKeyVisibility() {
        let needsKey = Settings.shared.aiProvider != .ollama
        apiKeyLabel.isHidden = !needsKey
        apiKeyField.isHidden = !needsKey
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
        // Update model field and API key visibility for new provider
        modelField.stringValue = Settings.shared.aiModel
        apiKeyField.stringValue = Settings.shared.apiKey
        updateAPIKeyVisibility()
        testResultLabel.stringValue = ""
    }

    @objc private func modelChanged() {
        Settings.shared.aiModel = modelField.stringValue
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

    @objc private func whisperModelChanged() {
        if let title = whisperPopup.selectedItem?.title {
            Settings.shared.whisperModel = title
        }
        updateDownloadButton()
    }

    @objc private func downloadModel() {
        let modelName = Settings.shared.whisperModel
        let modelDir = NSHomeDirectory() + "/.local/share/whisper-models"
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var appState: AppState = .idle
    var recProcess: Process?
    var audioFile: String?
    var previousApp: NSRunningApplication?  // saved before recording to refocus for paste

    let whisperPath = "/opt/homebrew/bin/whisper-cli"
    let recPath = "/opt/homebrew/bin/rec"
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

        // Prevent duplicate instances — if another Voice is already running, quit silently
        let myPid = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.voice"
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
        let hotkeyName = hotkeyOptions[Settings.shared.hotkeyIndex].name
        menu.addItem(NSMenuItem(title: "\(hotkeyName) = Push-to-Talk", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Space+\(hotkeyName) = POPO Mode", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Escape = Cancel", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Paste Last", action: #selector(pasteLast), keyEquivalent: "v"))
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Voice", action: #selector(quitApp), keyEquivalent: "q"))
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

        inputMonitor.reloadHotkey()
        if !inputMonitor.start() {
            showNotification(title: "Voice", body: "Accessibility permission required. Add Voice.app in System Settings > Privacy & Security > Accessibility, then relaunch.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }

        // Re-create event tap after wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.inputMonitor.stop()
            _ = self?.inputMonitor.start()
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

    func updateIcon() {
        guard let button = statusItem.button else { return }
        switch appState {
        case .idle:       button.title = "\u{1F3A4}"  // microphone
        case .recording:  button.title = "\u{1F534}"  // red circle
        case .popo:       button.title = "\u{1F535}"  // blue circle
        case .processing: button.title = "\u{23F3}"   // hourglass
        }
    }

    // MARK: - Overlay

    func showOverlay(state: OverlayState) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let contentView = overlayWindow.contentView as? OverlayContentView else { return }
        contentView.overlayState = state

        switch state {
        case .recording, .popo:
            contentView.startPulse()
        default:
            contentView.stopPulse()
        }

        overlayWindow.positionOnScreen()
        overlayWindow.orderFrontRegardless()
    }

    func hideOverlay() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        (overlayWindow.contentView as? OverlayContentView)?.stopPulse()
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

        // Save the currently focused app so we can refocus it before pasting
        previousApp = NSWorkspace.shared.frontmostApplication

        // Show feedback immediately — before process launch
        appState = .recording
        inputMonitor.setRecording(true)
        updateIcon()
        showOverlay(state: .recording)
        if Settings.shared.soundsEnabled { playSound("Tink") }

        let tempFile = NSTemporaryDirectory() + "voice_\(ProcessInfo.processInfo.globallyUniqueString).wav"
        audioFile = tempFile

        let process = Process()
        process.executableURL = URL(fileURLWithPath: recPath)
        process.arguments = ["-r", "16000", "-c", "1", "-b", "16", tempFile]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            recProcess = process
        } catch {
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            showNotification(title: "Voice", body: "Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard case .recording = appState else { return }
        guard let process = recProcess, process.isRunning else { return }

        process.terminate()
        process.waitUntilExit()
        recProcess = nil
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

        if let process = recProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        recProcess = nil

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

        previousApp = NSWorkspace.shared.frontmostApplication

        // Show feedback immediately — before process launch
        appState = .popo
        inputMonitor.setRecording(true)
        inputMonitor.setPopo(true)
        updateIcon()
        showOverlay(state: .popo)
        if Settings.shared.soundsEnabled { playSound("Morse") }

        let tempFile = NSTemporaryDirectory() + "voice_\(ProcessInfo.processInfo.globallyUniqueString).wav"
        audioFile = tempFile

        let process = Process()
        process.executableURL = URL(fileURLWithPath: recPath)
        process.arguments = ["-r", "16000", "-c", "1", "-b", "16", tempFile]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            recProcess = process

            // Safety timeout
            let timeout = Settings.shared.popoTimeoutSeconds
            popoTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.stopPopo()
                    self?.showNotification(title: "Voice", body: "POPO mode auto-stopped after \(Settings.shared.popoTimeout) minutes.")
                }
            }
        } catch {
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

        guard let process = recProcess, process.isRunning else {
            appState = .idle
            inputMonitor.setRecording(false)
            updateIcon()
            hideOverlay()
            return
        }

        process.terminate()
        process.waitUntilExit()
        recProcess = nil
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

        if let process = recProcess, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        recProcess = nil

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
        if let process = recProcess, process.isRunning {
            process.terminate()
        }
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
let savedStatePath = NSHomeDirectory() + "/Library/Saved Application State/com.local.voice.savedState"
try? FileManager.default.removeItem(atPath: savedStatePath)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
