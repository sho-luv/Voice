// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Audio preparation

/// Turns a raw recording into what the recognizer should hear: only the stretches with
/// speech in them, at a sane level, in pieces short enough for the model.
///
/// Why it exists (measured with `Voice --bench`, see MODELS.md "Audio preparation"):
/// - Whisper invents text for audio with no speech in it ("Thank you.", "Okay.", "you"),
///   so a recording without speech must never reach it.
/// - Both models lose accuracy on long recordings handed over in one piece. Cutting at
///   pauses and transcribing the pieces separately gets it back.
/// - Silence around the speech costs a little accuracy and all of the decode time.
/// The old peak normalization, by contrast, measured as no change for either model:
/// their log-mel front ends don't care about level. A gain is still applied because it
/// is free and keeps very quiet input away from the bottom of the Float range.
enum AudioPrep {
    static let sampleRate = 16_000
    /// Kept on each side of the speech so a soft first or last consonant isn't shaved off.
    static let padSeconds = 0.3
    /// Less speech than this in the whole recording is a click or a breath, not dictation.
    static let minSpeechSeconds = 0.12
    /// A pause this long is a new thought: always start a new piece there.
    static let longPauseSeconds = 2.0
    /// Longest piece handed to the recognizer. Whisper's window is 30 s; Parakeet has no
    /// hard limit but measured best with pieces well under a minute.
    static var maxChunkSeconds = 28.0

    /// Speech stretches as sample ranges, from the voice activity detector.
    typealias Segment = (start: Int, end: Int)

    /// Pieces to transcribe in order. Empty when the recording holds no speech.
    static func chunks(of samples: [Float], speech: [Segment]) -> [[Float]] {
        let total = speech.reduce(0) { $0 + ($1.end - $1.start) }
        guard total >= Int(minSpeechSeconds * Double(sampleRate)) else { return [] }

        let maxChunk = Int(maxChunkSeconds * Double(sampleRate))
        let longPause = Int(longPauseSeconds * Double(sampleRate))
        // Group the speech stretches. A group closes at a long pause, or when the next
        // stretch would push it past the limit; in that case it closes at the widest
        // pause in its second half, which is the likeliest sentence boundary.
        var groups: [[Segment]] = []
        var current: [Segment] = []
        for seg in speech {
            guard let first = current.first, let last = current.last else {
                current = [seg]
                continue
            }
            if seg.start - last.end >= longPause {
                groups.append(current)
                current = [seg]
            } else if seg.end - first.start > maxChunk {
                var cut = current.count
                var widest = -1
                for i in 1..<max(current.count, 1) where current[i].start - first.start >= maxChunk / 2 {
                    let gap = current[i].start - current[i - 1].end
                    if gap > widest {
                        widest = gap
                        cut = i
                    }
                }
                groups.append(Array(current[..<cut]))
                current = Array(current[cut...]) + [seg]
            } else {
                current.append(seg)
            }
        }
        if !current.isEmpty { groups.append(current) }

        let pad = Int(padSeconds * Double(sampleRate))
        var out: [[Float]] = []
        for (i, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            // Padding never reaches past the middle of the pause it shares with a neighbour.
            var start = max(0, first.start - pad)
            var end = min(samples.count, last.end + pad)
            if i > 0, let prev = groups[i - 1].last { start = max(start, (prev.end + first.start) / 2) }
            if i + 1 < groups.count, let next = groups[i + 1].first { end = min(end, (last.end + next.start) / 2) }
            guard end > start else { continue }
            out.append(Array(samples[start..<end]))
        }
        return out
    }

    /// Raises quiet speech toward a consistent level. The level is read from the speech
    /// only and from a high percentile instead of the single loudest sample, so one key
    /// click or a cough can't decide the gain for the whole recording.
    ///
    /// Called twice: once over the whole recording before speech detection (the detector
    /// misses speech that sits near digital silence: 23% word errors on a -54 dBFS test
    /// set against 5% once boosted), then over the detected speech only.
    static func normalize(_ samples: inout [Float], speech: [Segment]? = nil) {
        var magnitudes: [Float] = []
        for seg in speech ?? [(start: 0, end: samples.count)] {
            var i = seg.start
            while i < min(seg.end, samples.count) {
                magnitudes.append(abs(samples[i]))
                i += 8
            }
        }
        guard magnitudes.count > 100 else { return }
        magnitudes.sort()
        let level = magnitudes[min(magnitudes.count - 1, magnitudes.count * 999 / 1000)]
        guard level > 0 else { return }
        // Target about -6 dBFS for the loud parts; never turn anything down, and cap the
        // boost at 30x so a near-silent recording doesn't become a wall of hiss.
        let gain = min(30, 0.5 / level)
        guard gain > 1.05 else { return }
        for i in samples.indices {
            samples[i] = max(-1, min(1, samples[i] * gain))
        }
    }
}

// MARK: - Bench

// `Voice --bench [--whisper] [--prep old|new|none] [--chunk seconds] dir ...` transcribes every WAV in each
// directory through the same audio preparation the app uses and prints "dir/name<TAB>text",
// one line per file. tools/bench/wer.py turns that into word error rates. This is how a
// change to capture, preparation or decoding gets measured instead of guessed at.
enum Bench {
    static func run(_ args: [String]) -> Int32 {
        var prep = "new"
        var dirs: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--prep", i + 1 < args.count {
                prep = args[i + 1]
                i += 1
            } else if args[i] == "--chunk", i + 1 < args.count, let seconds = Double(args[i + 1]) {
                AudioPrep.maxChunkSeconds = seconds
                i += 1
            } else if !args[i].hasPrefix("--") {
                dirs.append(args[i])
            }
            i += 1
        }
        let model = args.contains("--whisper") ? ModelCatalog.whisperTurbo : ModelCatalog.parakeet
        guard model.isInstalled else {
            FileHandle.standardError.write("speech model \(model.id) not installed\n".data(using: .utf8)!)
            return 2
        }
        for dir in dirs {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".wav") }.sorted()
            let start = Date()
            for name in names {
                let path = dir + "/" + name
                let text = transcribe(path: path, prep: prep, model: model)
                let id = (dir as NSString).lastPathComponent + "/" + (name as NSString).deletingPathExtension
                print("\(id)\t\(text.replacingOccurrences(of: "\n", with: " "))")
            }
            let line = String(format: "# %@ %@ prep=%@: %d files in %.1f s\n", (dir as NSString).lastPathComponent,
                              model.id, prep, names.count, Date().timeIntervalSince(start))
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
        SpeechEngine.shared.shutdown()
        return 0
    }

    private static func transcribe(path: String, prep: String, model: ModelSpec) -> String {
        var samples: [Float]?
        switch prep {
        case "old":
            // The 4.0.2 path: peak-normalize the file in place, then load it.
            let copy = NSTemporaryDirectory() + "voice_bench_\(ProcessInfo.processInfo.globallyUniqueString).wav"
            try? FileManager.default.copyItem(atPath: path, toPath: copy)
            normalizeWavFile(at: copy)
            samples = loadPCM16Wav(at: copy)
            try? FileManager.default.removeItem(atPath: copy)
        default:
            samples = loadPCM16Wav(at: path)
        }
        guard let samples, !samples.isEmpty else { return "" }
        if prep == "new" {
            switch SpeechEngine.shared.transcribeRecording(samples, model: model, prompt: "", language: "en") {
            case .text(let text): return text
            case .noSpeech: return "<no speech>"
            case .failed: return "<failed>"
            }
        }
        let text = SpeechEngine.shared.transcribe(samples, model: model, prompt: "", language: "en") ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
