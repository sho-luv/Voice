// SPDX-License-Identifier: GPL-3.0-or-later
// ModelDownload.swift — Downloads missing models (SHA-256 pinned) and shows DownloadView.

import AppKit
import Foundation

final class ModelDownloadWindowController: NSObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloadWindowController()

    let progress = DownloadProgress()
    private var session: URLSession?
    private var queue: [ModelSpec] = []
    private var completions: [() -> Void] = []

    /// Calls `completion` once every model in `specs` is installed. Missing
    /// models are downloaded; calls made while a download is running join it.
    func ensureModels(_ specs: [ModelSpec], completion: @escaping () -> Void) {
        let missing = specs.filter { spec in
            !spec.isInstalled && !queue.contains { $0.id == spec.id }
        }
        let busy = !queue.isEmpty
        if missing.isEmpty && !busy {
            completion()
            return
        }
        queue.append(contentsOf: missing)
        completions.append(completion)
        if !busy {
            progress.onRetry = { [weak self] in self?.startNext() }
            AppWindows.shared.showDownload(progress: progress)
            startNext()
        }
    }

    private var current: ModelSpec? { queue.first }

    private func startNext() {
        guard let spec = current, let url = URL(string: spec.url) else { return }
        progress.purpose = spec.role == .speech ? "speech" : "cleanup"
        progress.size = spec.sizeDescription
        progress.percent = 0
        progress.failed = false
        progress.complete = false
        progress.status = "Fetching \(spec.displayName) from Hugging Face..."

        try? FileManager.default.createDirectory(atPath: ModelSpec.modelDirectory, withIntermediateDirectories: true)
        if session == nil {
            session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        }
        session?.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (self.current?.bytes ?? 0)
            guard total > 0 else { return }
            self.progress.percent = Double(totalBytesWritten) / Double(total) * 100
            self.progress.status = String(format: "%.0f of %.0f MB", Double(totalBytesWritten) / 1_048_576, Double(total) / 1_048_576)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns, so move it now
        // and verify afterwards.
        guard let spec = DispatchQueue.main.sync(execute: { current }) else { return }
        let partial = spec.downloadPath + ".partial"
        try? FileManager.default.removeItem(atPath: partial)
        do {
            try FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: partial))
        } catch {
            fail("Error: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async { self.progress.status = "Verifying checksum..." }
        guard sha256Hex(ofFileAt: partial) == spec.sha256 else {
            try? FileManager.default.removeItem(atPath: partial)
            NSLog("Voice: checksum mismatch for %@", spec.fileName)
            fail("The download was corrupted. Try again.")
            return
        }
        do {
            try? FileManager.default.removeItem(atPath: spec.downloadPath)
            try FileManager.default.moveItem(atPath: partial, toPath: spec.downloadPath)
        } catch {
            fail("Error: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async {
            self.queue.removeFirst()
            if self.queue.isEmpty {
                self.finish()
            } else {
                self.startNext()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        fail("Download failed: \(error.localizedDescription)")
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.progress.failed = true
            self.progress.status = message
            Feedback.error()
        }
    }

    private func finish() {
        progress.complete = true
        progress.percent = 100
        progress.status = "Verified. Ready to go."
        Feedback.success()
        // Brief pause so the user sees "got it", then close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            AppWindows.shared.closeDownload()
            if Settings.shared.onboardingComplete {
                NSApp.setActivationPolicy(.accessory)
            }
            AppModel.shared.modelsVersion += 1
            let done = self.completions
            self.completions = []
            done.forEach { $0() }
        }
    }
}
