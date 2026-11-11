// SPDX-License-Identifier: GPL-3.0-or-later
// Feedback.swift — Tiny synthesized UI sounds and trackpad haptics for every interaction.
//
// The sounds are rendered into memory at first use (no audio assets) and played
// through a small AVAudioEngine, so they work without any system sound setting.
// Haptics go through NSHapticFeedbackManager, which only does anything on a
// Force Touch trackpad. The in-app "UI sounds" toggle is the one off switch.
// Recording start/stop/done also use these, replacing afplay of system sounds.

import AVFoundation
import AppKit
import Foundation

enum Feedback {
    static var soundsOn = true

    private static let engine = AVAudioEngine()
    private static var voices: [AVAudioPlayerNode] = []
    private static var buffers: [Synth: AVAudioPCMBuffer] = [:]
    private static var nextVoice = 0
    private static var lastPlayed: [Synth: CFTimeInterval] = [:]
    private static let haptics = NSHapticFeedbackManager.defaultPerformer
    /// A running AVAudioEngine costs about 1% CPU for its IO thread, so it stops a few
    /// seconds after the last sound and restarts on the next one.
    private static var idleStop: DispatchWorkItem?
    private static let idleStopDelay: TimeInterval = 4

    enum Synth: String, CaseIterable {
        case tick, press, release, pop, clunk, success, error
        /// Dial detent while spinning the mic or dragging a slider.
        case ratchet
        /// Hard flick.
        case whoosh
        /// Hands-free lock-on.
        case clink
        /// Tapping the mic.
        case thock
    }

    /// Chip taps, toggles, small selections.
    static func tick() { haptics.perform(.alignment, performanceTime: .now); play(.tick) }
    /// Button goes down.
    static func press() { haptics.perform(.generic, performanceTime: .now); play(.press) }
    /// Button comes back up.
    static func release() { play(.release) }
    /// Recording starts, something got copied.
    static func pop() { haptics.perform(.levelChange, performanceTime: .now); play(.pop) }
    /// The big moment.
    static func clunk() { haptics.perform(.levelChange, performanceTime: .now); play(.clunk) }
    static func success() { play(.success) }
    static func error() { haptics.perform(.generic, performanceTime: .now); play(.error) }
    /// One detent. Rate-limited so fast spins don't turn into a buzz.
    static func ratchet() {
        guard throttle(.ratchet, 0.035) else { return }
        haptics.perform(.alignment, performanceTime: .now)
        play(.ratchet, volume: 0.8)
    }
    static func whoosh() { play(.whoosh) }
    static func clink() { haptics.perform(.levelChange, performanceTime: .now); play(.clink) }
    static func thock() { haptics.perform(.generic, performanceTime: .now); play(.thock) }

    private static func throttle(_ synth: Synth, _ interval: CFTimeInterval) -> Bool {
        let now = CACurrentMediaTime()
        if let last = lastPlayed[synth], now - last < interval { return false }
        lastPlayed[synth] = now
        return true
    }

    private static func play(_ synth: Synth, volume: Float = 1) {
        guard soundsOn else { return }
        let work = {
            prepare()
            guard let buffer = buffers[synth] else { return }
            if !engine.isRunning {
                do { try engine.start() } catch { return }
            }
            // Round-robin voices so overlapping sounds don't cut each other off.
            let voice = voices[nextVoice % voices.count]
            nextVoice += 1
            voice.stop()
            voice.volume = volume
            voice.scheduleBuffer(buffer, at: nil, options: [])
            voice.play()
            idleStop?.cancel()
            let stop = DispatchWorkItem { engine.stop() }
            idleStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + idleStopDelay, execute: stop)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Renders every UI sound into memory and wires up the engine. Cheap; safe to call often.
    static func prepare() {
        guard buffers.isEmpty else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        for synth in Synth.allCases {
            let samples = render(synth)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            buffers[synth] = buffer
        }
        for _ in 0..<6 {
            let voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
            voices.append(voice)
        }
        engine.mainMixerNode.outputVolume = 0.9
        engine.prepare()
        // Output device changes (headphones) stop the engine; it restarts on the next sound.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            engine.stop()
        }
    }

    // MARK: Synthesis

    private static let rate = 44_100.0

    static func render(_ synth: Synth) -> [Float] {
        switch synth {
        case .tick:
            return tone(duration: 0.012, from: 3_200, to: 2_400, level: 0.25, decay: 300, noise: 0.3)
        case .press:
            return tone(duration: 0.035, from: 900, to: 500, level: 0.35, decay: 120, noise: 0.15)
        case .release:
            return tone(duration: 0.03, from: 1_300, to: 1_700, level: 0.18, decay: 140, noise: 0.05)
        case .pop:
            return tone(duration: 0.08, from: 420, to: 900, level: 0.45, decay: 45, noise: 0)
        case .clunk:
            // Low thud plus a metallic ping.
            let thud = tone(duration: 0.22, from: 140, to: 55, level: 0.7, decay: 22, noise: 0.25)
            let ping = tone(duration: 0.22, from: 2_300, to: 2_250, level: 0.1, decay: 30, noise: 0)
            return zip(thud, ping).map(+)
        case .success:
            return tone(duration: 0.09, from: 880, to: 880, level: 0.3, decay: 25, noise: 0)
                + tone(duration: 0.18, from: 1_320, to: 1_320, level: 0.3, decay: 18, noise: 0)
        case .ratchet:
            return tone(duration: 0.018, from: 4_200, to: 3_000, level: 0.22, decay: 260, noise: 0.6)
        case .whoosh:
            let count = Int(0.32 * rate)
            var seed: UInt32 = 0x2545_F491
            var lowpass: Float = 0
            return (0..<count).map { i in
                let t = Double(i) / Double(count)
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let white = Float(seed >> 8) / Float(1 << 24) * 2 - 1
                lowpass += (white - lowpass) * Float(0.05 + 0.25 * sin(t * .pi))
                return lowpass * Float(sin(t * .pi)) * 0.9
            }
        case .clink:
            let a = tone(duration: 0.16, from: 2_900, to: 2_880, level: 0.22, decay: 28, noise: 0)
            let b = tone(duration: 0.16, from: 4_350, to: 4_320, level: 0.12, decay: 34, noise: 0)
            return zip(a, b).map(+)
        case .thock:
            return tone(duration: 0.09, from: 260, to: 150, level: 0.6, decay: 55, noise: 0.15)
        case .error:
            return tone(duration: 0.1, from: 300, to: 300, level: 0.3, decay: 20, noise: 0.05)
                + tone(duration: 0.16, from: 220, to: 200, level: 0.3, decay: 16, noise: 0.05)
        }
    }

    /// A pitch-swept sine with an exponential decay and optional noise burst. Peak stays under 1.0.
    private static func tone(duration: Double, from: Double, to: Double, level: Float, decay: Double, noise: Float) -> [Float] {
        let count = Int(duration * rate)
        var phase = 0.0
        var seed: UInt32 = 0x9E37_79B9
        return (0..<count).map { i in
            let t = Double(i) / rate
            let frequency = from + (to - from) * (t / duration)
            phase += 2 * .pi * frequency / rate
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Float(seed >> 8) / Float(1 << 24) * 2 - 1
            let envelope = Float(exp(-t * decay)) * min(1, Float(t * rate / 32)) // 32-sample attack, no click
            return level * envelope * (Float(sin(phase)) + noise * white)
        }
    }
}
