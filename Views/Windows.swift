// SPDX-License-Identifier: GPL-3.0-or-later
// Windows.swift — SwiftUI screens hosted in AppKit windows, plus the model that
// bridges AppDelegate state (recording, last transcription) into SwiftUI.

import AppKit
import SwiftUI

/// What SwiftUI needs to know about the app's state. AppDelegate writes, views observe.
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var state: AppState = .idle
    @Published var lastTranscription: String?
    /// Sheet to present on the home screen (support, look). Set from the menu bar or a URL.
    @Published var route: HomeRoute?
    /// Bumped whenever a model finishes downloading, so views re-read `isInstalled`.
    @Published var modelsVersion = 0
    private init() {}

    var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }
}

enum HomeRoute: String, Identifiable {
    case support, look
    var id: String { rawValue }
}

/// Injects the theme, the stores and the color scheme into every hosted screen.
struct ThemedRoot<Content: View>: View {
    @ObservedObject var themes = ThemeStore.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.theme, themes.current)
            .environmentObject(themes)
            .environmentObject(SupportStore.shared)
            .environmentObject(AppModel.shared)
            .preferredColorScheme(themes.current.isDark ? .dark : .light)
            // Not `.themedBackground()`: a modifier here would read the theme from the
            // environment *outside* the one set above (the default), not the current one.
            .background(themes.current.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .tint(themes.current.ink)
    }
}

/// Owns the app's windows. One of each; showing again just brings it forward.
final class AppWindows {
    static let shared = AppWindows()

    private var home: NSWindow?
    private var onboarding: NSWindow?
    private var download: NSWindow?

    private init() {
        NotificationCenter.default.addObserver(forName: .voiceThemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyWindowColors()
        }
        // A closed window keeps its NSHostingView alive, and SceneKit keeps a display
        // link running for every SCNView in it. Drop the content on close; it's rebuilt
        // on the next show.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            if window === self.home { self.home = nil }
            if window === self.onboarding { self.onboarding = nil }
            if window === self.download { self.download = nil }
            DispatchQueue.main.async { window.contentView = nil }
        }
    }

    func showHome(route: HomeRoute? = nil) {
        if let route { AppModel.shared.route = route }
        if let home, home.isVisible {
            home.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = makeWindow(size: NSSize(width: 560, height: 780), title: "Voice", resizable: true)
        window.minSize = NSSize(width: 520, height: 600)
        window.contentView = host(ThemedRoot { HomeView() })
        window.center()
        home = window
        present(window)
    }

    func showOnboarding(rerun: Bool) {
        if let onboarding, onboarding.isVisible {
            onboarding.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Show the Dock icon during onboarding so the window is discoverable.
        NSApp.setActivationPolicy(.regular)
        let window = makeWindow(size: NSSize(width: 520, height: 660), title: rerun ? "Voice Setup" : "Welcome to Voice",
                                resizable: false, closable: rerun)
        window.level = .floating
        window.contentView = host(ThemedRoot { OnboardingView(isRerun: rerun) })
        window.center()
        onboarding = window
        present(window)
    }

    func closeOnboarding() {
        onboarding?.close()
        onboarding = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func showDownload(progress: DownloadProgress) {
        if let download, download.isVisible {
            download.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(size: NSSize(width: 460, height: 330), title: "Downloading Models", resizable: false, closable: false)
        window.level = .floating
        window.contentView = host(ThemedRoot { DownloadView(progress: progress) })
        window.center()
        download = window
        NSApp.setActivationPolicy(.regular)
        present(window)
    }

    func closeDownload() {
        download?.close()
        download = nil
    }

    func closeAll() {
        for window in [home, onboarding, download] { window?.close() }
    }

    /// The window keeps its own size; SwiftUI must not grow it to the content's ideal height.
    private func host<V: View>(_ root: V) -> NSHostingView<V> {
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        return view
    }

    private func present(_ window: NSWindow) {
        applyWindowColors()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(size: NSSize, title: String, resizable: Bool, closable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
        if closable { style.insert(.closable) }
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        return window
    }

    /// The titlebar strip is AppKit, so it needs the theme color by hand.
    private func applyWindowColors() {
        let theme = ThemeStore.shared.current
        for window in [home, onboarding, download] {
            window?.backgroundColor = theme.nsBackground
            window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        }
    }

    // MARK: Screenshot QA

    /// Writes a PNG of the given window (what's actually on screen, SceneKit included).
    static func snapshot(_ window: NSWindow, to path: String) {
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            NSLog("Voice: snapshot failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// For screenshots: a presented sheet first, then whichever of our windows is up.
    var frontWindow: NSWindow? {
        if let sheet = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent != nil }) { return sheet }
        return [onboarding, download, home].compactMap { $0 }.first { $0.isVisible }
    }
}
