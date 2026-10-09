// SPDX-License-Identifier: GPL-3.0-or-later
// Components.swift — Panels, labels and empty states for the Not Boring look.

import SwiftUI

/// Cards sink a little when pressed.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Raised panel on the theme's surface color.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.surface))
    }
}

/// Small mono caps heading above a group.
struct SectionLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text.uppercased())
            .font(.mono(10.5, weight: .bold))
            .foregroundStyle(theme.mutedInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// Big, opinionated empty state.
struct EmptyState: View {
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.display(40)).foregroundStyle(theme.ink)
            Text(message).font(.mono(12)).foregroundStyle(theme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
        .padding(.horizontal, 6)
    }
}

/// "1  Hold fn." — a numbered how-it-works step with a big accent digit.
struct NumberedStep: View {
    let number: Int
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)").font(.display(34)).foregroundStyle(theme.accent).frame(width: 22, alignment: .leading)
            Text(text).font(.heavy(14)).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Two-line display title with tight negative leading ("CUSTOMIZE / YOUR LOOK.").
struct DisplayTitle: View {
    let lines: [String]
    var size: CGFloat = 64
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: -size * 0.3) {
            ForEach(lines, id: \.self) { line in
                Text(line.uppercased()).font(.display(size))
            }
        }
        .foregroundStyle(theme.ink)
        .fixedSize()
    }
}

/// A themed single-line text box in mono.
struct MonoField: View {
    let placeholder: String
    @Binding var text: String
    var lines = 1
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if lines > 1 {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: CGFloat(lines) * 18)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder).foregroundStyle(theme.mutedInk.opacity(0.7))
                                .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
            }
        }
        .font(.mono(11.5))
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.ink.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.ink.opacity(0.1), lineWidth: 1))
    }
}

/// Screen background that fills edge to edge.
struct ThemedBackground: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(theme.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .tint(theme.ink)
    }
}

extension View {
    func themedBackground() -> some View { modifier(ThemedBackground()) }
}
