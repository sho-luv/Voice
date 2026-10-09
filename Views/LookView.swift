// SPDX-License-Identifier: GPL-3.0-or-later
// LookView.swift — "Customize your look": four themes, each previewed on the mic.

import SwiftUI

struct LookView: View {
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    DisplayTitle(lines: ["CUSTOMIZE", "YOUR LOOK."], size: 46)
                    Spacer()
                    IconButton(systemImage: "xmark", label: "Close") { dismiss() }
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Theme.all) { option in
                        ThemeCard(option: option, selected: themes.current.id == option.id) {
                            themes.current = option
                        }
                    }
                }
                DisplayTitle(lines: ["YOUR MIC."], size: 40)
                    .padding(.top, 8)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(MicStyle.allCases) { style in
                        MicCard(style: style, selected: themes.heroStyle == style) {
                            themes.heroStyle = style
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 14) {
                        ThemedToggle(title: "UI sounds", subtitle: "Clicks, pops and clunks, plus the record start and stop sounds.", isOn: $themes.soundsOn)
                        SpecRow(label: "Overlay", value: "Follows the theme")
                        SpecRow(label: "Menu bar", value: "Accent while recording")
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 780)
    }
}

/// One microphone to choose, previewed in the current theme.
private struct MicCard: View {
    let style: MicStyle
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @StateObject private var mic = MicController()

    var body: some View {
        Button {
            Feedback.tick()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                MicSceneView(controller: mic, interactive: false, zoom: 7.4, style: style)
                    .frame(height: 120)
                Text(style.name.uppercased()).font(.display(24)).foregroundStyle(theme.ink)
                Text(style.tagline.uppercased()).font(.mono(8.5, weight: .semibold)).foregroundStyle(theme.mutedInk)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(selected ? theme.accent : theme.ink.opacity(0.1), lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .black)).foregroundStyle(theme.onAccent)
                        .frame(width: 22, height: 22).background(Circle().fill(theme.accent)).padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
    }
}

private struct ThemeCard: View {
    let option: Theme
    let selected: Bool
    let action: () -> Void
    @Environment(\.theme) private var current
    @StateObject private var mic = MicController()

    var body: some View {
        Button {
            Feedback.tick()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                MicSceneView(controller: mic, interactive: false, zoom: 7.2)
                    .frame(height: 110)
                    .environment(\.theme, option)
                Text(option.name.uppercased()).font(.display(26)).foregroundStyle(option.ink)
                Text(option.tagline.uppercased()).font(.mono(8.5, weight: .semibold)).foregroundStyle(option.mutedInk)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(option.background))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(selected ? current.accent : current.ink.opacity(0.1), lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .black)).foregroundStyle(current.onAccent)
                        .frame(width: 22, height: 22).background(Circle().fill(current.accent)).padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
    }
}
