// SPDX-License-Identifier: GPL-3.0-or-later
// HomeView.swift — The main window: hero mic, live status, spec sheet, settings panels.

import AVFoundation
import SwiftUI

/// Bridges `Settings` (plain UserDefaults-backed class) into SwiftUI bindings.
/// Any write pings `objectWillChange`, so every view reading Settings re-renders.
final class SettingsBinder: ObservableObject {
    func bind<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>, onSet: (() -> Void)? = nil) -> Binding<T> {
        Binding(
            get: { Settings.shared[keyPath: keyPath] },
            set: { [weak self] value in
                self?.objectWillChange.send()
                Settings.shared[keyPath: keyPath] = value
                onSet?()
            })
    }

    func refresh() { objectWillChange.send() }
}

struct HomeView: View {
    enum Tab: String, CaseIterable {
        case general, audio, ai, history
        var title: String {
            switch self {
            case .general: return "General"
            case .audio: return "Audio"
            case .ai: return "AI"
            case .history: return "History"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var support: SupportStore
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.theme) private var theme
    @StateObject private var mic = MicController()
    @StateObject private var settings = SettingsBinder()
    @State private var tab: Tab = HomeView.initialTab
    @State private var pulse = 0

    /// `-tab audio` launch argument, for screenshots.
    private static var initialTab: Tab {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let t = Tab(rawValue: args[i + 1]) { return t }
        return .general
    }

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "4.0" }

    private var stateWord: String {
        switch model.state {
        case .idle: return "READY."
        case .recording: return "LISTENING."
        case .popo: return "HANDS-FREE."
        case .processing: return "THINKING."
        }
    }

    private var languageName: String {
        ModelCatalog.languages.first { $0.code == Settings.shared.transcriptionLanguage }?.name ?? "Automatic"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                hero
                specs
                HStack(spacing: 6) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        PillToggle(title: t.title, selected: tab == t) { tab = t }
                    }
                }
                panel
                footer
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 20)
        }
        .sheet(item: $model.route) { route in
            ThemedRoot {
                switch route {
                case .support: SupportView()
                case .look: LookView()
                }
            }
        }
        .onChange(of: model.state) { _, state in
            switch state {
            case .recording, .popo:
                mic.setListening(true)
                pulse += 1
            case .processing, .idle:
                mic.setListening(false)
            }
        }
        .onChange(of: model.lastTranscription) { _, _ in mic.bounce() }
        .onChange(of: model.modelsVersion) { _, _ in settings.refresh() }
    }

    // MARK: Header + hero

    private var header: some View {
        HStack(spacing: 8) {
            Tag(text: "Voice \(version)")
            if support.isSupporter { Tag(text: "♥ Supporter", filled: true) }
            Spacer()
            IconButton(systemImage: "paintpalette.fill", label: "Customize your look") { model.route = .look }
            IconButton(systemImage: "heart.fill", label: "Support Voice", tint: theme.accent) { model.route = .support }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: -20) {
                Text("VOICE").font(.display(78))
                Text(stateWord).font(.display(44)).foregroundStyle(model.state == .idle ? theme.ink : theme.accent)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: stateWord)
            }
            .foregroundStyle(theme.ink)
            Spacer(minLength: 0)
            ZStack {
                PulseRings(trigger: pulse, color: theme.accent).frame(width: 150, height: 150)
                MicSceneView(controller: mic, zoom: 6.0) { toggleHandsFree() }
            }
            .frame(width: 190, height: 200)
            .help("Click to start or stop hands-free dictation. Drag to spin.")
        }
    }

    /// The hero is a control: click it for hands-free dictation.
    private func toggleHandsFree() {
        guard let delegate = model.delegate else { return }
        switch model.state {
        case .idle: delegate.startPopo()
        case .popo: delegate.stopPopo()
        case .recording: delegate.stopRecording()
        case .processing: break
        }
    }

    private var specs: some View {
        VStack(spacing: 7) {
            SpecRow(label: "Hold", value: hotkeyOptions[min(Settings.shared.hotkeyIndex, hotkeyOptions.count - 1)].name)
            SpecRow(label: "Model", value: Settings.shared.speechModel.displayName)
            SpecRow(label: "Cleanup", value: Settings.shared.aiEnabled ? "On · local" : "Off")
            SpecRow(label: "Language", value: languageName)
            SpecRow(label: "Mic", value: themes.heroStyle.name)
            SpecRow(label: "Supporter", value: support.isSupporter ? "♥ since \(support.sinceText)" : "Not yet",
                    valueColor: support.isSupporter ? theme.accent : nil)
        }
    }

    @ViewBuilder private var panel: some View {
        switch tab {
        case .general: GeneralPanel(settings: settings)
        case .audio: AudioPanel(settings: settings)
        case .ai: AIPanel(settings: settings)
        case .history: HistoryPanel(settings: settings)
        }
    }

    private var footer: some View {
        HStack {
            Text("ALL LOCAL · NO ACCOUNTS · GPL-3.0").font(.mono(9.5, weight: .semibold)).foregroundStyle(theme.mutedInk)
            Spacer()
            Button("RESET TO DEFAULTS") { resetToDefaults() }
                .buttonStyle(.plain)
                .font(.mono(9.5, weight: .bold))
                .foregroundStyle(theme.mutedInk)
        }
        .padding(.top, 6)
    }

    private func resetToDefaults() {
        let alert = NSAlert()
        alert.messageText = "Reset to Defaults?"
        alert.informativeText = "This resets all settings. Saved transcripts are not affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Settings.shared.resetAll()
        themes.soundsOn = Settings.shared.soundsEnabled
        settings.refresh()
        model.delegate?.inputMonitor.reloadHotkey()
        Feedback.clunk()
    }
}

// MARK: - General

private struct GeneralPanel: View {
    @ObservedObject var settings: SettingsBinder
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.theme) private var theme

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Push-to-talk key")
                    PillPicker(options: hotkeyOptions.indices.map { ($0, hotkeyOptions[$0].name) },
                               selection: settings.bind(\.hotkeyIndex) { model.delegate?.inputMonitor.reloadHotkey() })
                    Text("Hold to talk. Double-tap for hands-free. Escape cancels.")
                        .font(.mono(10)).foregroundStyle(theme.mutedInk)
                }
                Divider().overlay(theme.ink.opacity(0.08))
                ThemedToggle(title: "UI sounds", subtitle: "Clicks, pops and clunks. Also the record start and stop sounds.", isOn: $themes.soundsOn)
                ThemedToggle(title: "Start at login", subtitle: "Adds a LaunchAgent so Voice is always in the menu bar.", isOn: settings.bind(\.autoStartOnLogin))
                ThemedToggle(title: "Restore clipboard", subtitle: "Put your old clipboard back after a paste-based insert.", isOn: settings.bind(\.clipboardRestore))
                Divider().overlay(theme.ink.opacity(0.08))
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HANDS-FREE TIMEOUT").font(.mono(11.5, weight: .bold)).foregroundStyle(theme.ink)
                        Text("Stops a forgotten hands-free session.").font(.mono(10)).foregroundStyle(theme.mutedInk)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Settings.shared.popoTimeout)").font(.display(30)).foregroundStyle(theme.ink)
                            .contentTransition(.numericText())
                        Text("MIN").font(.mono(10, weight: .bold)).foregroundStyle(theme.mutedInk)
                    }
                    IconButton(systemImage: "minus", label: "Less", size: 30) { bump(-1) }
                    IconButton(systemImage: "plus", label: "More", size: 30) { bump(1) }
                }
                Button("RUN SETUP AGAIN") { AppWindows.shared.showOnboarding(rerun: true) }
                    .buttonStyle(ChunkyButtonStyle(fill: theme.ink, label: theme.background, compact: true))
            }
        }
    }

    private func bump(_ delta: Int) {
        settings.bind(\.popoTimeout).wrappedValue = Settings.shared.popoTimeout + delta
    }
}

// MARK: - Audio

private struct AudioPanel: View {
    @ObservedObject var settings: SettingsBinder
    @Environment(\.theme) private var theme
    @State private var devices: [AudioDevice] = []

    private var micName: String {
        let uid = Settings.shared.micDeviceUID
        if uid.isEmpty { return "System default" }
        return devices.first { $0.uid == uid }?.name ?? "Not connected"
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                ChoiceMenu(label: "Microphone", value: micName,
                           options: [("", "System Default")] + devices.map { ($0.uid, $0.name) }) { uid in
                    settings.bind(\.micDeviceUID).wrappedValue = uid
                }
                if !Settings.shared.micDeviceUID.isEmpty, !devices.contains(where: { $0.uid == Settings.shared.micDeviceUID }) {
                    AlertPill(text: "Preferred mic not connected")
                }
                Divider().overlay(theme.ink.opacity(0.08))
                ThemedToggle(title: "Overlay", subtitle: "The pill at the top of the screen while you talk.", isOn: settings.bind(\.overlayEnabled))
                HStack(spacing: 6) {
                    chip("App name", \.overlayShowAppName)
                    chip("App icon", \.overlayShowAppIcon)
                    chip("Timer", \.overlayShowTimer)
                }
                sliderRow("Background", value: Binding(
                    get: { Double(Settings.shared.overlayBackgroundOpacity * 100) },
                    set: { settings.bind(\.overlayBackgroundOpacity).wrappedValue = CGFloat($0 / 100) }),
                          range: 0...100, step: 5, unit: "%")
                HStack {
                    Text("FONT SIZE").font(.mono(11.5, weight: .bold)).foregroundStyle(theme.ink)
                    Spacer()
                    PillPicker(options: [(10.0, "S"), (13.0, "M"), (16.0, "L")], selection: Binding(
                        get: { Double(Settings.shared.overlayFontSize) },
                        set: { settings.bind(\.overlayFontSize).wrappedValue = CGFloat($0) }))
                }
                sliderRow("Waveform", value: Binding(
                    get: { Double(Settings.shared.overlaySensitivity) },
                    set: { settings.bind(\.overlaySensitivity).wrappedValue = Float($0) }),
                          range: 5...80, step: 5, unit: "x")
                HStack { Spacer(); OverlayPreview(settings: settings); Spacer() }
                    .padding(.top, 4)
            }
        }
        .onAppear { devices = listInputDevices() }
    }

    private func chip(_ title: String, _ keyPath: ReferenceWritableKeyPath<Settings, Bool>) -> some View {
        PillToggle(title: title, selected: Settings.shared[keyPath: keyPath]) {
            settings.bind(keyPath).wrappedValue.toggle()
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased()).font(.mono(11.5, weight: .bold)).foregroundStyle(theme.ink)
                Spacer()
                Text("\(Int(value.wrappedValue))\(unit.uppercased())").font(.display(22)).foregroundStyle(theme.ink)
                    .contentTransition(.numericText())
            }
            TickSlider(value: value, range: range, step: step)
        }
    }
}

/// Mono caps menu button: `MICROPHONE        MACBOOK PRO MIC ⌄`.
struct ChoiceMenu: View {
    let label: String
    let value: String
    let options: [(String, String)]
    let onPick: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Text(label.uppercased()).font(.mono(11.5, weight: .bold)).foregroundStyle(theme.ink)
            Spacer()
            Menu {
                ForEach(options, id: \.0) { option in
                    Button(option.1) { Feedback.tick(); onPick(option.0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(value.uppercased()).font(.mono(11, weight: .bold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(theme.ink.opacity(0.08)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Live preview of the recording overlay, drawn the way OverlayContentView draws it.
struct OverlayPreview: View {
    @ObservedObject var settings: SettingsBinder
    @Environment(\.theme) private var theme

    var body: some View {
        let s = Settings.shared
        let size = s.overlayFontSize
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !s.overlayEnabled)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 5
            HStack(spacing: 6) {
                Circle().fill(theme.accent).frame(width: 8, height: 8)
                if s.overlayShowAppIcon {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Terminal.app"))
                        .resizable().frame(width: 16, height: 16)
                }
                if s.overlayShowAppName {
                    Text("Terminal").font(.system(size: size - 1)).foregroundStyle(theme.ink.opacity(0.7))
                }
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        // Same formula as the real overlay: quiet-speech RMS times the waveform gain.
                        let raw = 0.012 + 0.018 * (0.5 + 0.5 * sin(phase + Double(i) * 0.9))
                        let level = min(1, raw * Double(s.overlaySensitivity))
                        Capsule().fill(theme.ink.opacity(0.9))
                            .frame(width: 3, height: max(4, CGFloat(level) * max(size * 2.4, 28) * 0.6))
                    }
                }
                .padding(.horizontal, 2)
                if s.overlayShowTimer {
                    Text("0:05").font(.system(size: size, weight: .medium)).foregroundStyle(theme.ink)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: max(size * 2.4, 28))
            .background(Capsule().fill(theme.background.opacity(Double(s.overlayBackgroundOpacity))))
            .overlay(Capsule().stroke(theme.ink.opacity(0.12), lineWidth: 1))
            .opacity(s.overlayEnabled ? 1 : 0.3)
        }
    }
}

// MARK: - AI

private struct AIPanel: View {
    @ObservedObject var settings: SettingsBinder
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                ThemedToggle(title: "AI text cleanup",
                             subtitle: "Fixes grammar, drops filler words and keeps only the final version of a correction. Runs on this Mac.",
                             isOn: settings.bind(\.aiEnabled) {
                                 if Settings.shared.aiEnabled {
                                     ModelDownloadWindowController.shared.ensureModels([ModelCatalog.cleanup]) { model.modelsVersion += 1 }
                                 }
                             })
                VStack(spacing: 6) {
                    SpecRow(label: "Model", value: ModelCatalog.cleanup.displayName)
                    SpecRow(label: "Size", value: ModelCatalog.cleanup.sizeDescription)
                    SpecRow(label: "Status", value: ModelCatalog.cleanup.isInstalled ? "Downloaded" : "Not downloaded",
                            valueColor: ModelCatalog.cleanup.isInstalled ? nil : theme.warning)
                }
                Divider().overlay(theme.ink.opacity(0.08))
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Custom instructions")
                    MonoField(placeholder: "e.g. Never change proper nouns like Claude or Gemini", text: settings.bind(\.aiCustomPrompt), lines: 2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Custom vocabulary")
                    MonoField(placeholder: "Kubernetes, kubectl, faradaysoft, GGUF, whisper.cpp", text: settings.bind(\.customVocabulary), lines: 2)
                    Text("Names, acronyms and terms. Their spelling is restored in every transcript; Whisper also hears them as hints.")
                        .font(.mono(10)).foregroundStyle(theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - History (speech model, language, transcripts)

private struct HistoryPanel: View {
    @ObservedObject var settings: SettingsBinder
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var results: [(date: Date, text: String, path: String)] = []
    @State private var copiedPath: String?

    private var languageName: String {
        ModelCatalog.languages.first { $0.code == Settings.shared.transcriptionLanguage }?.name ?? "Automatic"
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Speech model")
                    HStack {
                        PillPicker(options: ModelCatalog.speechModels.map { ($0.id, $0.displayName) },
                                   selection: settings.bind(\.speechModelID))
                        Spacer()
                        if !Settings.shared.speechModel.isInstalled {
                            Button("DOWNLOAD") {
                                ModelDownloadWindowController.shared.ensureModels([Settings.shared.speechModel]) { model.modelsVersion += 1 }
                            }
                            .buttonStyle(ChunkyButtonStyle(compact: true))
                        }
                    }
                    SpecRow(label: "Size", value: Settings.shared.speechModel.sizeDescription)
                    SpecRow(label: "Status", value: Settings.shared.speechModel.isInstalled ? "Downloaded" : "Not downloaded",
                            valueColor: Settings.shared.speechModel.isInstalled ? nil : theme.warning)
                }
                ChoiceMenu(label: "Language", value: languageName,
                           options: ModelCatalog.languages.map { ($0.code, $0.name) }) { code in
                    settings.bind(\.transcriptionLanguage).wrappedValue = code
                }
                Divider().overlay(theme.ink.opacity(0.08))
                ThemedToggle(title: "Save transcripts", subtitle: "One text file per dictation, on this Mac.", isOn: settings.bind(\.saveTranscripts))
                HStack(spacing: 8) {
                    Text(abbreviatedPath).font(.mono(10)).foregroundStyle(theme.mutedInk).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("CHANGE") { chooseDirectory() }
                        .buttonStyle(ChunkyButtonStyle(fill: theme.ink, label: theme.background, depth: 3, cornerRadius: 10, compact: true))
                    Button("OPEN") { openDirectory() }
                        .buttonStyle(ChunkyButtonStyle(fill: theme.ink, label: theme.background, depth: 3, cornerRadius: 10, compact: true))
                }
                HStack {
                    MonoField(placeholder: "Search transcripts", text: $query)
                    Tag(text: results.isEmpty ? (query.isEmpty ? "0" : "No results") : "\(results.count)")
                }
                if results.isEmpty {
                    EmptyState(title: query.isEmpty ? "Nothing yet." : "No match.",
                               message: query.isEmpty ? "Hold \(hotkeyOptions[min(Settings.shared.hotkeyIndex, hotkeyOptions.count - 1)].name) and say something." : "Try another word.")
                } else {
                    VStack(spacing: 6) {
                        ForEach(results.prefix(50), id: \.path) { record in
                            TranscriptRow(record: record, copied: copiedPath == record.path) { copy(record) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: model.lastTranscription) { _, _ in reload() }
    }

    private var abbreviatedPath: String {
        Settings.shared.transcriptDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func reload() {
        results = Settings.shared.searchTranscripts(query: query)
    }

    private func copy(_ record: (date: Date, text: String, path: String)) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
        Feedback.pop()
        copiedPath = record.path
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedPath == record.path { copiedPath = nil } }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Settings.shared.transcriptDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            settings.bind(\.transcriptDirectory).wrappedValue = url.path
            reload()
        }
    }

    private func openDirectory() {
        let dir = Settings.shared.transcriptDirectory
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}

private struct TranscriptRow: View {
    let record: (date: Date, text: String, path: String)
    let copied: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    private var dateText: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(record.date) {
            formatter.dateFormat = "'Today' h:mm a"
        } else if calendar.isDateInYesterday(record.date) {
            formatter.dateFormat = "'Yesterday' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy h:mm a"
        }
        return formatter.string(from: record.date)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))
                        .font(.heavy(12.5)).foregroundStyle(theme.ink).lineLimit(1)
                    Text(dateText.uppercased()).font(.mono(9.5, weight: .semibold)).foregroundStyle(theme.mutedInk)
                }
                Spacer(minLength: 0)
                if copied {
                    Tag(text: "Copied", filled: true)
                } else {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.mutedInk)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.ink.opacity(0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .help("Click to copy")
    }
}
