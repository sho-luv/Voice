// SPDX-License-Identifier: GPL-3.0-or-later
// DownloadView.swift — First-launch model download, as a big number.

import SwiftUI

/// Published by ModelDownloadWindowController; observed by DownloadView.
final class DownloadProgress: ObservableObject {
    @Published var purpose = "speech"
    @Published var size = ""
    @Published var percent: Double = 0
    @Published var status = ""
    @Published var failed = false
    @Published var complete = false
    var onRetry: (() -> Void)?
}

struct DownloadView: View {
    @ObservedObject var progress: DownloadProgress
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("ONE-TIME DOWNLOAD").font(.mono(11, weight: .bold)).foregroundStyle(theme.mutedInk)
                Spacer()
                Tag(text: progress.size)
            }
            HStack(alignment: .firstTextBaseline) {
                DisplayTitle(lines: [progress.complete ? "GOT IT." : "\(progress.purpose.uppercased())", progress.complete ? "" : "MODEL."], size: 50)
                Spacer()
                Text(progress.complete ? "100%" : String(format: "%.0f%%", progress.percent))
                    .font(.display(64))
                    .foregroundStyle(progress.failed ? theme.warning : theme.accent)
                    .contentTransition(.numericText())
            }
            ZStack(alignment: .leading) {
                Capsule().fill(theme.ink.opacity(0.1)).frame(height: 14)
                GeometryReader { geo in
                    Capsule().fill(progress.failed ? theme.warning : theme.accent)
                        .frame(width: max(14, geo.size.width * CGFloat(progress.percent / 100)), height: 14)
                        .animation(.easeOut(duration: 0.25), value: progress.percent)
                }
                .frame(height: 14)
            }
            Text(progress.status).font(.mono(11)).foregroundStyle(progress.failed ? theme.warning : theme.mutedInk)
                .lineLimit(2)
            Panel(padding: 12) {
                VStack(spacing: 6) {
                    SpecRow(label: "Runs", value: "On this Mac")
                    SpecRow(label: "Audio", value: "Never leaves it")
                    SpecRow(label: "Checksum", value: "SHA-256 verified")
                }
            }
            if progress.failed {
                Button("TRY AGAIN") { progress.onRetry?() }
                    .buttonStyle(ChunkyButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 18)
    }
}
