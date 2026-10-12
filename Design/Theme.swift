// SPDX-License-Identifier: GPL-3.0-or-later
// Theme.swift — The "(Not Boring)" design system, macOS edition.
//
// Few colors on purpose: a ground, one raised surface, ink, and ONE loud accent
// (plus warning yellow). Depth comes only from the 3D hero and the pressable
// buttons, never from gradients. Three type styles, each with a job:
// display (huge squeezed numbers / shouted words), heavy (titles), mono (labels).

import AppKit
import SwiftUI

struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let tagline: String
    let isDark: Bool
    let backgroundHex: UInt32
    let surfaceHex: UInt32
    let inkHex: UInt32
    let mutedOpacity: Double
    let accentHex: UInt32
    let onAccentHex: UInt32
    let warningHex: UInt32
    let heroPrimaryHex: UInt32
    let heroSecondaryHex: UInt32

    var background: Color { Color(hex: backgroundHex) }
    var surface: Color { Color(hex: surfaceHex) }
    var ink: Color { Color(hex: inkHex) }
    var mutedInk: Color { ink.opacity(mutedOpacity) }
    var accent: Color { Color(hex: accentHex) }
    /// Text and icons drawn on top of `accent`.
    var onAccent: Color { Color(hex: onAccentHex) }
    var warning: Color { Color(hex: warningHex) }

    // AppKit colors for the overlay, the menu bar and SceneKit.
    var nsBackground: NSColor { NSColor(hex: backgroundHex) }
    var nsSurface: NSColor { NSColor(hex: surfaceHex) }
    var nsInk: NSColor { NSColor(hex: inkHex) }
    var nsAccent: NSColor { NSColor(hex: accentHex) }
    var nsWarning: NSColor { NSColor(hex: warningHex) }
    var heroPrimary: NSColor { NSColor(hex: heroPrimaryHex) }
    var heroSecondary: NSColor { NSColor(hex: heroSecondaryHex) }

    static let midnight = Theme(
        id: "midnight", name: "Midnight", tagline: "Signal red after dark", isDark: true,
        backgroundHex: 0x141414, surfaceHex: 0x222222, inkHex: 0xF3EEE6, mutedOpacity: 0.5,
        accentHex: 0xFF2E2E, onAccentHex: 0xFFFFFF, warningHex: 0xFFB800,
        heroPrimaryHex: 0xFF2E2E, heroSecondaryHex: 0x2B2B2B)

    static let paper = Theme(
        id: "paper", name: "Paper", tagline: "Warm cream, black ink", isDark: false,
        backgroundHex: 0xEEE7DC, surfaceHex: 0xFFFFFF, inkHex: 0x141414, mutedOpacity: 0.5,
        accentHex: 0xFF2E2E, onAccentHex: 0xFFFFFF, warningHex: 0xFFB800,
        heroPrimaryHex: 0xFF2E2E, heroSecondaryHex: 0x1C1C1C)

    static let electric = Theme(
        id: "electric", name: "Electric", tagline: "Black glass, blue voltage", isDark: true,
        backgroundHex: 0x050505, surfaceHex: 0x161616, inkHex: 0xFFFFFF, mutedOpacity: 0.5,
        accentHex: 0x14A8FF, onAccentHex: 0x000000, warningHex: 0xFFB800,
        heroPrimaryHex: 0x14A8FF, heroSecondaryHex: 0xE8E8E8)

    static let hazard = Theme(
        id: "hazard", name: "Hazard", tagline: "Caution tape energy", isDark: false,
        backgroundHex: 0xFFC400, surfaceHex: 0xFFD94A, inkHex: 0x111111, mutedOpacity: 0.55,
        accentHex: 0x111111, onAccentHex: 0xFFC400, warningHex: 0xFF2E2E,
        heroPrimaryHex: 0x1A1A1A, heroSecondaryHex: 0xF3EEE6)

    static let all = [midnight, paper, electric, hazard]

    static func named(_ id: String?) -> Theme { all.first { $0.id == id } ?? .midnight }
}

extension Notification.Name {
    /// Posted on the main thread whenever the theme changes, for AppKit views
    /// (overlay, menu bar) that don't observe the SwiftUI environment.
    static let voiceThemeChanged = Notification.Name("VoiceThemeChanged")
}

/// The chosen theme and the UI-sound preference, persisted in UserDefaults.
/// One instance for the whole app; AppKit code reads `ThemeStore.shared.current`.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var current: Theme {
        didSet {
            UserDefaults.standard.set(current.id, forKey: "theme")
            NotificationCenter.default.post(name: .voiceThemeChanged, object: nil)
        }
    }
    /// Which microphone is the hero (home window, overlay, previews).
    @Published var heroStyle: MicStyle {
        didSet {
            UserDefaults.standard.set(heroStyle.rawValue, forKey: "heroStyle")
            NotificationCenter.default.post(name: .voiceThemeChanged, object: nil)
        }
    }
    /// Same key as the old "Sounds" checkbox, so upgrades keep the preference.
    @Published var soundsOn: Bool {
        didSet {
            UserDefaults.standard.set(soundsOn, forKey: "soundsEnabled")
            Feedback.soundsOn = soundsOn
        }
    }

    private init() {
        var id = UserDefaults.standard.string(forKey: "theme")
        // `-theme <id>` launch argument, for the screenshot QA loop.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-theme"), i + 1 < args.count { id = args[i + 1] }
        current = Theme.named(id)
        var style = UserDefaults.standard.string(forKey: "heroStyle")
        if let i = args.firstIndex(of: "-mic"), i + 1 < args.count { style = args[i + 1] }
        heroStyle = MicStyle(rawValue: style ?? "") ?? .stage
        soundsOn = UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true
        Feedback.soundsOn = soundsOn
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.midnight
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// `Color.mix` needs macOS 15; this does the same blend through NSColor.
    func mixed(with other: Color, by fraction: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let b = NSColor(other).usingColorSpace(.sRGB) ?? NSColor(other)
        return Color(nsColor: a.blended(withFraction: CGFloat(fraction), of: b) ?? a)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Type

extension Font {
    /// Huge squeezed numerals and shouty words, used as graphics ("4.0", "YOU'RE IN.").
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black).width(.compressed) }
    /// Chunky headlines.
    static func heavy(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    /// Spec-sheet labels and data.
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// `LABEL ............ VALUE`, like a spec sheet.
struct SpecRow: View {
    let label: String
    let value: String
    var valueColor: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label.uppercased())
            DottedLine()
                .stroke(theme.mutedInk.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
                .frame(height: 1)
            Text(value.uppercased())
                .foregroundStyle(valueColor ?? theme.ink)
                .multilineTextAlignment(.trailing)
        }
        .font(.mono(11.5))
        .foregroundStyle(theme.mutedInk)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

struct DottedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

/// `! NO MIC !` — warnings are an event, not a footnote.
struct AlertPill: View {
    let text: String
    var color: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        Text("!  \(text.uppercased())  !")
            .font(.mono(12.5, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(color ?? theme.warning))
    }
}

/// Small mono caps tag.
struct Tag: View {
    let text: String
    var filled = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(.mono(10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(filled ? theme.background : theme.mutedInk)
            .background(Capsule().fill(filled ? theme.ink : theme.ink.opacity(0.08)))
    }
}

// MARK: - Buttons

/// A physical, extruded button: the face sits on a darker base and presses down
/// into it, with a click sound and a haptic tap.
struct ChunkyButtonStyle: ButtonStyle {
    var fill: Color?
    var label: Color?
    var depth: CGFloat = 5
    var cornerRadius: CGFloat = 16
    var compact = false
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let face = fill ?? theme.accent
        let pressed = configuration.isPressed
        configuration.label
            .font(.heavy(compact ? 12.5 : 15))
            .foregroundStyle(label ?? theme.onAccent)
            .padding(.vertical, compact ? 9 : 14)
            .padding(.horizontal, compact ? 14 : 22)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(face))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1).blendMode(.plusLighter)
            )
            .offset(y: pressed ? depth : 0)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(face.mixed(with: .black, by: 0.35))
                    .offset(y: depth)
            )
            .padding(.bottom, depth)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: pressed)
            .onChange(of: pressed) { _, down in
                if down { Feedback.press() } else { Feedback.release() }
            }
    }
}

/// Round extruded button (play, record, close).
struct RoundChunkyStyle: ButtonStyle {
    let size: CGFloat
    let fill: Color
    let label: Color

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let depth = size * 0.08
        configuration.label
            .foregroundStyle(label)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .offset(y: pressed ? depth : 0)
            .background(Circle().fill(fill.mixed(with: .black, by: 0.4)).offset(y: depth))
            .padding(.bottom, depth)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.5), value: pressed)
            .onChange(of: pressed) { _, down in
                if down { Feedback.press() } else { Feedback.release() }
            }
    }
}

/// Mono caps pill that toggles, like a DAY ● WEEK switch.
struct PillToggle: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            Feedback.tick()
            action()
        } label: {
            Text(title.uppercased())
                .font(.mono(11, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? theme.background : theme.ink)
                .background(Capsule().fill(selected ? theme.ink : theme.ink.opacity(0.08)))
                .overlay(Capsule().stroke(theme.ink.opacity(selected ? 0 : 0.12), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }
}

/// A row of pills where exactly one is selected.
struct PillPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { option in
                PillToggle(title: option.1, selected: selection == option.0) { selection = option.0 }
            }
        }
    }
}

/// Round icon button for toolbars and headers.
struct IconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 36
    var tint: Color?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            Feedback.tick()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(tint ?? theme.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(theme.ink.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A physical switch: capsule track, round knob, tick on flip.
struct ThemedToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased()).font(.mono(11.5, weight: .bold)).foregroundStyle(theme.ink)
                if let subtitle {
                    Text(subtitle).font(.mono(10)).foregroundStyle(theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                Feedback.tick()
                isOn.toggle()
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? theme.accent : theme.ink.opacity(0.15))
                        .frame(width: 44, height: 26)
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .padding(3)
                        .frame(width: 26, height: 26)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }
}

/// Slider with a ruler of tick marks and a round knob; clicks at every step like a detent.
struct TickSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var ticks = 21
    @Environment(\.theme) private var theme

    private let knob: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let travel = max(1, width - knob)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<ticks, id: \.self) { i in
                        Rectangle()
                            .fill(theme.mutedInk.opacity(0.6))
                            .frame(width: 1, height: i % 5 == 0 ? 10 : 5)
                        if i < ticks - 1 { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, knob / 2)
                .frame(height: 10)
                .offset(y: 11)
                Capsule().fill(theme.ink.opacity(0.12)).frame(height: 4).padding(.horizontal, knob / 2)
                Capsule().fill(theme.ink).frame(width: fraction * travel + knob / 2, height: 4).padding(.leading, knob / 2)
                Circle()
                    .fill(theme.ink)
                    .overlay(Circle().stroke(theme.background, lineWidth: 3))
                    .frame(width: knob, height: knob)
                    .offset(x: fraction * travel)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = min(1, max(0, (drag.location.x - knob / 2) / travel))
                        let raw = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        let snapped = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
                        if snapped != value {
                            value = snapped
                            Feedback.ratchet()
                        }
                    }
            )
        }
        .frame(height: 34)
    }
}
