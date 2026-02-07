import Cocoa
import Carbon
import UserNotifications

// MARK: - Global Hotkey Registration (Carbon)

func registerHotkey(callback: @escaping () -> Void) {
    // Store callback globally
    HotkeyManager.shared.callback = callback

    // Register Cmd+L
    var hotKeyRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x564D4943), id: 1) // "VMIC"

    // L = keycode 37, Cmd = cmdKey
    let modifiers: UInt32 = UInt32(cmdKey)
    RegisterEventHotKey(37, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)

    // Install handler
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetEventDispatcherTarget(), { (_, event, _) -> OSStatus in
        HotkeyManager.shared.callback?()
        return noErr
    }, 1, &eventType, nil, nil)
}

class HotkeyManager {
    static let shared = HotkeyManager()
    var callback: (() -> Void)?
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var isRecording = false
    var isTranscribing = false
    var recProcess: Process?
    var audioFile: String?
    let modelPath = NSHomeDirectory() + "/.local/share/whisper-models/ggml-small.en.bin"
    let whisperPath = "/opt/homebrew/bin/whisper-cli"
    let recPath = "/opt/homebrew/bin/rec"
    let afplayPath = "/usr/bin/afplay"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        // Build menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Recording (⌘L)", action: #selector(toggleRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceMic", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu

        // Also support click-to-toggle (left click)
        if let button = statusItem.button {
            button.target = self
            // Menu handles clicks, but we also add the action
        }

        // Register global hotkey: Ctrl+Shift+R
        registerHotkey { [weak self] in
            DispatchQueue.main.async {
                self?.toggleRecording()
            }
        }

        // Preflight check
        if !FileManager.default.fileExists(atPath: modelPath) {
            showNotification(title: "VoiceMic", body: "Whisper model not found at \(modelPath)")
        }
    }

    func updateIcon() {
        if let button = statusItem.button {
            if isTranscribing {
                button.title = "⏳"
            } else if isRecording {
                button.title = "🔴"
            } else {
                button.title = "🎙"
            }
        }
    }

    @objc func toggleRecording() {
        if isTranscribing { return } // ignore while transcribing

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        let tempFile = NSTemporaryDirectory() + "voicemic_\(ProcessInfo.processInfo.globallyUniqueString).wav"
        audioFile = tempFile

        let process = Process()
        process.executableURL = URL(fileURLWithPath: recPath)
        process.arguments = ["-r", "16000", "-c", "1", "-b", "16", tempFile]
        // Suppress sox output
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            recProcess = process
            isRecording = true
            updateIcon()
            playSound("Tink")
        } catch {
            showNotification(title: "VoiceMic", body: "Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard let process = recProcess, process.isRunning else { return }

        process.terminate()
        process.waitUntilExit()
        recProcess = nil
        isRecording = false
        isTranscribing = true
        updateIcon()
        playSound("Pop")

        // Transcribe in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribe()
        }
    }

    func transcribe() {
        guard let audioFile = audioFile else {
            finishTranscribing(text: nil, error: "No audio file")
            return
        }

        // Check file exists and has content
        guard FileManager.default.fileExists(atPath: audioFile),
              let attrs = try? FileManager.default.attributesOfItem(atPath: audioFile),
              let size = attrs[.size] as? Int, size > 1000 else {
            finishTranscribing(text: nil, error: "Recording too short")
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
            var text = String(data: data, encoding: .utf8) ?? ""

            // Clean up whisper output
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if text.isEmpty {
                finishTranscribing(text: nil, error: "Empty transcription")
            } else {
                // Copy to clipboard
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)

                finishTranscribing(text: text, error: nil)
            }
        } catch {
            finishTranscribing(text: nil, error: error.localizedDescription)
        }

        cleanup(audioFile)
    }

    func finishTranscribing(text: String?, error: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.isTranscribing = false
            self?.updateIcon()

            if let text = text {
                let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text
                self?.showNotification(title: "Copied to clipboard", body: preview)
                self?.playSound("Glass")
            } else if let error = error {
                self?.showNotification(title: "VoiceMic", body: "Error: \(error)")
                self?.playSound("Basso")
            }
        }
    }

    func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    func playSound(_ name: String) {
        let path = "/System/Library/Sounds/\(name).aiff"
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

    // Show notifications even when app is frontmost
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc func quitApp() {
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
app.setActivationPolicy(.accessory) // No dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
