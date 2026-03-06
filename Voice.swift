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

        // Debug logging (remove for production)
        // NSLog("Voice: type=%d keyCode=%d flags=0x%llx", type.rawValue, keyCode, flags.rawValue)

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

        // fn key = keycode 63 (flagsChanged)
        guard type == .flagsChanged && keyCode == 63 else {
            return Unmanaged.passRetained(event)
        }

        let fnPressed = flags.contains(.maskSecondaryFn)

        if fnPressed && !monitor.fnDown {
            // fn key DOWN
            monitor.fnDown = true
            monitor.fnDownTime = ProcessInfo.processInfo.systemUptime

            // In POPO mode, fn tap stops it
            if monitor.isPopo {
                DispatchQueue.main.async { monitor.onPopoStop?() }
                return nil  // swallow
            }

            // Space+fn → POPO mode
            if monitor.spaceHeld && !monitor.isRecording {
                DispatchQueue.main.async { monitor.onPopoStart?() }
                return nil  // swallow
            }

            // Start recording (push-to-talk)
            if !monitor.isRecording {
                DispatchQueue.main.async { monitor.onRecordStart?() }
            }
            return nil  // swallow fn to prevent emoji picker

        } else if !fnPressed && monitor.fnDown {
            // fn key UP
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

        // Save current clipboard contents (matching Wispr Flow's approach).
        // Filter to valid UTI types only — legacy types like NSStringPboardType cause errors on restore.
        let savedTypes = pasteboard.types ?? []
        var savedData: [(NSPasteboard.PasteboardType, Data)] = []
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
                // restore original clipboard
                pasteboard.clearContents()
                if !savedData.isEmpty {
                    let restoreItem = NSPasteboardItem()
                    for (type, data) in savedData {
                        restoreItem.setData(data, forType: type)
                    }
                    pasteboard.writeObjects([restoreItem])
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
            // tap disabled to prevent self-interception
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
        // Cmd+V posted to HID

        // Re-enable the event tap after a short delay to let the paste event propagate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if let tap = self?.inputMonitor?.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                // tap re-enabled
            }
        }
    }
}

// MARK: - Ollama Client

class OllamaClient {
    let baseURL = "http://localhost:11434"
    let model = "llama3.2:3b"
    private var isAvailable = false

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

    func cleanupText(_ rawText: String, appContext: AppContext, completion: @escaping (String) -> Void) {
        guard isAvailable else {
            completion(rawText)
            return
        }

        let truncated = String(rawText.prefix(4000))

        let systemPrompt = """
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

        generate(system: systemPrompt, prompt: truncated) { result in
            completion(result ?? rawText)
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var appState: AppState = .idle
    var recProcess: Process?
    var audioFile: String?
    var previousApp: NSRunningApplication?  // saved before recording to refocus for paste

    let modelPath = NSHomeDirectory() + "/.local/share/whisper-models/ggml-small.en.bin"
    let whisperPath = "/opt/homebrew/bin/whisper-cli"
    let recPath = "/opt/homebrew/bin/rec"
    let afplayPath = "/usr/bin/afplay"

    let inputMonitor = InputMonitor()
    let textInjector = TextInjector()
    let ollamaClient = OllamaClient()
    let overlayWindow = OverlayWindow()

    var popoTimer: Timer?
    let popoTimeout: TimeInterval = 300  // 5 minutes safety limit

    var dismissTimer: Timer?
    var lastTranscription: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "fn = Push-to-Talk", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Space+fn = POPO Mode", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Escape = Cancel", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Paste Last", action: #selector(pasteLast), keyEquivalent: "v"))
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
        if !FileManager.default.fileExists(atPath: modelPath) {
            showNotification(title: "Voice", body: "Whisper model not found at \(modelPath)")
        }

        // Ollama health check and warmup
        ollamaClient.healthCheck { [weak self] available in
            if available {
                self?.ollamaClient.warmup()
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
            appState = .recording
            inputMonitor.setRecording(true)
            updateIcon()
            showOverlay(state: .recording)
            playSound("Tink")
        } catch {
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
        playSound("Pop")

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
        playSound("Funk")
    }

    // MARK: - POPO Mode

    func startPopo() {
        guard case .idle = appState else { return }

        previousApp = NSWorkspace.shared.frontmostApplication

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
            appState = .popo
            inputMonitor.setRecording(true)
            inputMonitor.setPopo(true)
            updateIcon()
            showOverlay(state: .popo)
            playSound("Morse")

            // Safety timeout
            popoTimer = Timer.scheduledTimer(withTimeInterval: popoTimeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.stopPopo()
                    self?.showNotification(title: "Voice", body: "POPO mode auto-stopped after 5 minutes.")
                }
            }
        } catch {
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
        playSound("Submarine")

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
        playSound("Funk")
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
            "--model", modelPath,
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
                let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text
                self?.showOverlay(state: .done(preview))
                self?.autoDismissOverlay(after: 1.5)
                self?.playSound("Glass")
            } else if let error = error {
                self?.showOverlay(state: .error(error))
                self?.autoDismissOverlay(after: 2.0)
                self?.playSound("Basso")
            }
        }
    }

    // MARK: - Focus & Inject

    func refocusAndInject(_ text: String) {
        // Re-activate the app that was focused before recording started
        if let app = previousApp, !app.isTerminated {
            // refocus previous app before injection
            app.activate()
            // Give the app time to regain focus before injecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.textInjector.injectText(text)
            }
        } else {
            // no previous app to refocus
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

    @objc func pasteLast() {
        guard let text = lastTranscription else {
            playSound("Basso")
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
