// SPDX-License-Identifier: GPL-3.0-or-later
// OnboardingView.swift — First launch: welcome, live permissions checklist, mic test, how it works.

import ApplicationServices
import AVFoundation
import SwiftUI

struct OnboardingView: View {
    let isRerun: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @StateObject private var mic = MicController()
    @State private var step = OnboardingView.initialStep
    @State private var finished = ProcessInfo.processInfo.arguments.contains("-finished")

    /// `-step 2` launch argument, for screenshots.
    private static var initialStep: Int {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-step"), i + 1 < args.count, let n = Int(args[i + 1]) { return max(0, min(3, n)) }
        return 0
    }
    @State private var pulse = 0

    // Mic test
    private enum TestPhase: Equatable { case idle, listening, thinking, done(String), failed }
    @State private var test: TestPhase = .idle
    @State private var baseline: String?

    private let stepCount = 4

    private var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    private var permissionsOK: Bool { AXIsProcessTrusted() && micAuthorized }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(isRerun ? "VOICE SETUP" : "WELCOME").font(.mono(11, weight: .bold)).foregroundStyle(theme.mutedInk)
                    Spacer()
                    Text("STEP \(step + 1) / \(stepCount)").font(.mono(11, weight: .bold)).foregroundStyle(theme.mutedInk)
                }
                Group {
                    switch step {
                    case 0: welcome
                    case 1: setup
                    case 2: testStep
                    default: tour
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 10) {
                    if step > 0 {
                        Button("BACK") { step -= 1 }
                            .buttonStyle(ChunkyButtonStyle(fill: theme.ink.opacity(0.1), label: theme.ink, compact: true))
                    }
                    if step == 2, test == .idle {
                        Button("SKIP") { next() }
                            .buttonStyle(ChunkyButtonStyle(fill: theme.ink.opacity(0.1), label: theme.ink, compact: true))
                    }
                    Button(nextTitle) { primaryAction() }
                        .buttonStyle(ChunkyButtonStyle())
                        .disabled(!canContinue)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 20)
            .opacity(finished ? 0 : 1)

            if finished {
                VStack(alignment: .leading, spacing: 10) {
                    Spacer()
                    HStack {
                        DisplayTitle(lines: ["YOU'RE", "IN."], size: 96)
                        Spacer()
                    }
                    Text("Voice lives in your menu bar now.").font(.mono(12)).foregroundStyle(theme.mutedInk)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .transition(.opacity)
            }
        }
        .onChange(of: model.state) { _, state in
            guard step == 2 else { return }
            switch state {
            case .recording, .popo:
                mic.setListening(true)
                pulse += 1
            case .processing:
                mic.setListening(false)
                if test == .listening { test = .thinking }
            case .idle:
                mic.setListening(false)
                if test == .listening || test == .thinking {
                    if let text = model.lastTranscription, text != baseline, !text.isEmpty {
                        test = .done(text)
                        Feedback.success()
                        mic.bounce()
                    } else {
                        test = .failed
                        Feedback.error()
                    }
                }
            }
        }
    }

    private var nextTitle: String {
        switch step {
        case 0: return "LET'S GO"
        case 1: return "CONTINUE"
        case 2:
            switch test {
            case .idle: return "START TEST"
            case .listening: return "LISTENING..."
            case .thinking: return "THINKING..."
            default: return "NEXT"
            }
        default: return "DONE"
        }
    }

    private func primaryAction() {
        if step == 2, test == .idle { startTest() } else { next() }
    }

    private var canContinue: Bool {
        switch step {
        case 1: return permissionsOK
        case 2: return test != .listening && test != .thinking
        default: return true
        }
    }

    private func next() {
        if step + 1 < stepCount {
            step += 1
        } else {
            complete()
        }
    }

    private func complete() {
        Settings.shared.onboardingComplete = true
        withAnimation(.easeOut(duration: 0.25)) { finished = true }
        mic.celebrate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            AppWindows.shared.closeOnboarding()
            // On first-run completion, start what was deferred during onboarding.
            if !isRerun, let delegate = model.delegate {
                delegate.startAccessibilityPolling()
                _ = delegate.inputMonitor.start()
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 0) {
                DisplayTitle(lines: ["HOLD.", "SPEAK.", "DONE."], size: 66)
                Spacer(minLength: 0)
                MicSceneView(controller: mic, zoom: 5.6) { mic.bounce() }
                    .frame(width: 200, height: 220)
            }
            Text("Hold fn and talk. Let go, and your words land wherever the cursor is. Transcribed and tidied up right here on this Mac.")
                .font(.mono(12)).foregroundStyle(theme.mutedInk).fixedSize(horizontal: false, vertical: true)
            Panel(padding: 14) {
                VStack(spacing: 7) {
                    SpecRow(label: "Audio", value: "Stays on this Mac")
                    SpecRow(label: "Accounts", value: "None")
                    SpecRow(label: "Price", value: "Free, GPL-3.0")
                    SpecRow(label: "Setup", value: "About a minute")
                }
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayTitle(lines: ["SET", "IT UP."], size: 66)
            Text("Voice ticks each one off as you turn it on.").font(.mono(12)).foregroundStyle(theme.mutedInk)
            // The rows re-check live state every second.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 10) {
                    SetupRowView(title: "Accessibility", pending: "Lets Voice see the hotkey and type for you.",
                                 done: "On. Voice can see the hotkey.", button: "Enable", isDone: AXIsProcessTrusted()) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                    SetupRowView(title: "Microphone", pending: "Lets Voice hear you.",
                                 done: "On. Your audio stays here.", button: "Enable", isDone: micAuthorized) {
                        switch AVCaptureDevice.authorizationStatus(for: .audio) {
                        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { _ in }
                        default: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                    SetupRowView(title: "Speech model", pending: "\(Settings.shared.speechModel.displayName) · \(Settings.shared.speechModel.sizeDescription). Optional now; it downloads on first use.",
                                 done: "Downloaded and verified.", button: "Get", isDone: Settings.shared.speechModel.isInstalled) {
                        ModelDownloadWindowController.shared.ensureModels([Settings.shared.speechModel]) { model.modelsVersion += 1 }
                    }
                }
            }
            if !permissionsOK {
                AlertPill(text: "Both permissions are needed")
            }
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 0) {
                DisplayTitle(lines: ["SAY", "SOMETHING."], size: 56)
                Spacer(minLength: 0)
                ZStack {
                    PulseRings(trigger: pulse, color: theme.accent).frame(width: 140, height: 140)
                    MicSceneView(controller: mic, zoom: 6.2) { startTest() }
                }
                .frame(width: 180, height: 190)
            }
            Text("TAP THE MIC · IT LISTENS FOR 3 SECONDS").font(.mono(10.5, weight: .bold)).foregroundStyle(theme.mutedInk)
            switch test {
            case .idle:
                EmptyView()
            case .listening:
                Text("LISTENING...").font(.display(34)).foregroundStyle(theme.accent)
            case .thinking:
                Text("THINKING...").font(.display(34)).foregroundStyle(theme.accent)
            case .done(let text):
                Text("IT WORKS.").font(.display(40)).foregroundStyle(theme.ink)
                Panel(padding: 12) {
                    Text(text).font(.mono(12)).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                Button("TEST AGAIN") { startTest() }.buttonStyle(ChunkyButtonStyle(fill: theme.ink, label: theme.background, compact: true))
            case .failed:
                AlertPill(text: "Nothing heard. Check the mic.")
                Button("TRY AGAIN") { startTest() }.buttonStyle(ChunkyButtonStyle(fill: theme.ink, label: theme.background, compact: true))
            }
        }
    }

    private func startTest() {
        guard test != .listening, test != .thinking, let delegate = model.delegate else { return }
        baseline = model.lastTranscription
        test = .listening
        delegate.startRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            delegate.stopRecording()
        }
        // Belt and braces: if the pipeline never reports back, don't wedge the step.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            if test == .listening || test == .thinking { test = .failed }
        }
    }

    private var tour: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayTitle(lines: ["HOW IT", "WORKS."], size: 66)
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    NumberedStep(number: 1, text: "Hold \(hotkeyOptions[min(Settings.shared.hotkeyIndex, hotkeyOptions.count - 1)].name), talk, let go. The text lands at your cursor.")
                    NumberedStep(number: 2, text: "Double-tap it for hands-free. Tap again to stop.")
                    NumberedStep(number: 3, text: "Escape cancels a recording.")
                    NumberedStep(number: 4, text: "The waveform in the menu bar is Voice. Click it for settings, mics and your last transcript.")
                }
            }
            Text("NO DOCK ICON · NO CLOUD · NO ACCOUNTS").font(.mono(10, weight: .bold)).foregroundStyle(theme.mutedInk)
        }
    }
}

/// One checklist row: status circle, title, live subtitle, and a button that disappears once done.
private struct SetupRowView: View {
    let title: String
    let pending: String
    let done: String
    let button: String
    let isDone: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(isDone ? theme.accent : theme.ink.opacity(0.1)).frame(width: 26, height: 26)
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .black)).foregroundStyle(theme.onAccent)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased()).font(.mono(11.5, weight: .bold)).foregroundStyle(theme.ink)
                Text(isDone ? done : pending).font(.mono(10)).foregroundStyle(theme.mutedInk).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !isDone {
                Button(button.uppercased(), action: action)
                    .buttonStyle(ChunkyButtonStyle(fill: theme.ink, label: theme.background, depth: 3, cornerRadius: 10, compact: true))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.surface))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDone)
    }
}
