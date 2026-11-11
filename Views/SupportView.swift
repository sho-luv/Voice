// SPDX-License-Identifier: GPL-3.0-or-later
// SupportView.swift — "Keep it free.": the pay-what-you-want supporter screen.

import SwiftUI

struct SupportView: View {
    @EnvironmentObject private var support: SupportStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var mic = MicController()
    @State private var thanks = false
    @State private var pulse = 0

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("SUPPORT VOICE").font(.mono(11, weight: .bold)).foregroundStyle(theme.mutedInk)
                        Spacer()
                        IconButton(systemImage: "xmark", label: "Not now") { dismiss() }
                    }
                    HStack(alignment: .center, spacing: 0) {
                        DisplayTitle(lines: ["KEEP IT", "FREE."], size: 64)
                        Spacer(minLength: 0)
                        ZStack {
                            PulseRings(trigger: pulse, color: theme.accent).frame(width: 140, height: 140)
                            MicSceneView(controller: mic, zoom: 7.4) { mic.bounce() }
                        }
                        .frame(width: 160, height: 170)
                    }
                    Text("Voice is free, open source and runs only on your Mac. Nothing is locked and nothing ever will be. If it earns its keep, chip in whatever you like. It covers the developer account, notarizing and the odd coffee.")
                        .font(.mono(11.5)).foregroundStyle(theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                    Panel {
                        VStack(spacing: 8) {
                            SpecRow(label: "Price", value: "$3 to whatever", valueColor: theme.accent)
                            SpecRow(label: "Unlocks", value: "Nothing. It's all free")
                            SpecRow(label: "Pay", value: "Once")
                            SpecRow(label: "License", value: "GPL-3.0")
                            SpecRow(label: "Telemetry", value: "None")
                            SpecRow(label: "Checkout", value: "Stripe, in your browser")
                        }
                    }
                    if support.isSupporter {
                        AlertPill(text: "You're a supporter. Thank you!", color: .green)
                        SpecRow(label: "Since", value: support.sinceText)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(SupportStore.amounts, id: \.self) { amount in
                                Button {
                                    support.openCheckout(amount)
                                } label: {
                                    Text("$\(amount)").font(.display(26)).frame(maxWidth: .infinity)
                                }
                                .buttonStyle(ChunkyButtonStyle(cornerRadius: 14))
                            }
                        }
                        Button("PICK YOUR OWN AMOUNT") { support.openCheckout("custom") }
                            .buttonStyle(ChunkyButtonStyle(fill: theme.ink.opacity(0.1), label: theme.ink, depth: 3, cornerRadius: 12, compact: true))
                            .frame(maxWidth: .infinity)
                        Button("ALREADY CHIPPED IN? MARK IT") { support.markSupported(source: "manual") }
                            .buttonStyle(.plain)
                            .font(.mono(10.5, weight: .bold))
                            .foregroundStyle(theme.mutedInk)
                            .frame(maxWidth: .infinity)
                        if !SupportStore.isConfigured {
                            AlertPill(text: "Payment link not set up yet")
                        }
                    }
                    Text("Voice never checks. The badge is for you.")
                        .font(.mono(10, weight: .semibold)).foregroundStyle(theme.mutedInk)
                }
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 20)
            }
            .opacity(thanks ? 0 : 1)

            if thanks {
                VStack(alignment: .leading, spacing: 12) {
                    Spacer()
                    HStack {
                        DisplayTitle(lines: ["THANK", "YOU."], size: 96)
                        Spacer()
                    }
                    Text("Seriously. That keeps the lights on. If you went big: are you hiring?\nI'll think of you every time it types for me.")
                        .font(.mono(12)).foregroundStyle(theme.mutedInk).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .transition(.opacity)
            }
        }
        .frame(width: 480, height: 660)
        .onAppear {
            if support.pendingThanks {
                support.pendingThanks = false
                playThanks()
            }
        }
        .onChange(of: support.isSupporter) { _, now in
            if now { playThanks() }
        }
    }

    private func playThanks() {
        pulse += 1
        mic.celebrate()
        withAnimation(.easeOut(duration: 0.3)) { thanks = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeOut(duration: 0.3)) { thanks = false }
        }
    }
}
