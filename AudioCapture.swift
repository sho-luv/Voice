// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

import AudioToolbox
import CoreAudio
import Foundation

/// Microphone capture on AudioQueue, delivering 16 kHz mono Int16 frames.
///
/// Why not AVAudioEngine: on macOS 26 its `inputNode` getter can spin forever inside
/// AVFAudio's sub-device enumeration (stale device IDs after a Bluetooth profile switch),
/// which froze Voice's main thread twice in October 2026 and made the hotkey go dead. It
/// also delivers no buffers at all from the AirPods Max mic, whose voice link runs at
/// 24 kHz while AVAudioEngine insists on 48 kHz. AudioQueue does its own rate conversion,
/// selects the device by UID so a recreated device ID doesn't matter, and runs callbacks
/// on a plain dispatch queue.
///
/// Every CoreAudio call happens on `workQueue`, never on the caller's thread, and both
/// start and stop are guarded by a watchdog, so a wedged coreaudiod degrades to an error
/// message instead of a frozen app.
final class AudioCapture {
    static let sampleRate: Double = 16000
    static let startTimeout: TimeInterval = 5
    static let stopTimeout: TimeInterval = 3
    /// 100 ms per buffer, three in flight: enough slack for a Bluetooth mic that wakes late.
    private static let bufferBytes: UInt32 = 3200
    private static let bufferCount = 3

    private let deviceUID: String
    /// Start and stop run here. Buffers are delivered on `callbackQueue`. They must be
    /// different queues: a synchronous AudioQueueStop waits for in-flight callbacks, so
    /// stopping from the callback queue deadlocks until the watchdog fires.
    private let controlQueue = DispatchQueue(label: "net.sholuv.voice.capture.control", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "net.sholuv.voice.capture.audio", qos: .userInitiated)
    private var queue: AudioQueueRef?    // controlQueue only
    private let running = Flag()
    private let abandoned = Flag()
    private var onBuffer: ((UnsafePointer<Int16>, Int) -> Void)?   // set before start, cleared after stop

    /// An empty `deviceUID` means the system default input.
    init(deviceUID: String) {
        self.deviceUID = deviceUID
    }

    /// Creates and starts the queue off the caller's thread. `completion` runs on the main
    /// queue exactly once: nil on success, otherwise a user-facing message. `onBuffer` runs
    /// on the capture's own serial queue for as long as the capture is running.
    func start(onBuffer: @escaping (UnsafePointer<Int16>, Int) -> Void, completion: @escaping (String?) -> Void) {
        let once = Once(completion)
        // Watchdog: a HAL call can block indefinitely when coreaudiod is wedged. The work
        // item is left to finish (or not) on its own queue; the app moves on without it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startTimeout) { [weak self] in
            guard once.fire("Microphone did not start in time") else { return }
            NSLog("Voice: capture start timed out after %.0f s", Self.startTimeout)
            self?.abandoned.set(true)
        }
        controlQueue.async { [self] in
            self.onBuffer = onBuffer
            let error = openAndStart()
            DispatchQueue.main.async {
                if !once.fire(error) {
                    // Finished after the watchdog gave up: nobody is listening, tear down.
                    self.stop(completion: nil)
                }
            }
        }
    }

    /// Stops and disposes the queue off the caller's thread. `completion` runs on the main
    /// queue exactly once, after the last buffer was delivered or after the watchdog fires.
    func stop(completion: (() -> Void)?) {
        let once = Once { _ in completion?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopTimeout) { [weak self] in
            guard once.fire(nil) else { return }
            NSLog("Voice: capture stop timed out after %.0f s", Self.stopTimeout)
            self?.abandoned.set(true)
        }
        controlQueue.async { [self] in
            running.set(false)
            if let q = queue {
                // Synchronous stop: returns once the last callback has run.
                AudioQueueStop(q, true)
                AudioQueueDispose(q, true)
                queue = nil
            }
            onBuffer = nil
            DispatchQueue.main.async { once.fire(nil) }
        }
    }

    // MARK: - Private

    private func openAndStart() -> String? {
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var newQueue: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&newQueue, &format, 0, callbackQueue) { [weak self] q, buffer, _, _, _ in
            guard let self = self, !self.abandoned.isSet else { return }
            // A stopping queue hands back its part-filled buffer one last time. That is
            // up to 100 ms of the end of the recording, so it is still delivered; only
            // the re-enqueue is skipped once the capture is no longer running.
            let bytes = Int(buffer.pointee.mAudioDataByteSize)
            if bytes >= 2, let handler = self.onBuffer {
                handler(buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self), bytes / 2)
            }
            guard self.running.isSet else { return }
            AudioQueueEnqueueBuffer(q, buffer, 0, nil)
        }
        guard status == noErr, let q = newQueue else {
            return "Microphone unavailable (AudioQueue error \(status))"
        }
        queue = q

        // A mic that has disappeared is skipped and the queue stays on the system default,
        // which is what the old engine did too. The existence check matters: selecting an
        // unknown UID doesn't fail, it blocks until the start watchdog fires.
        if !deviceUID.isEmpty {
            if Self.inputDeviceExists(uid: deviceUID) {
                var uid = deviceUID as CFString
                let set = withUnsafePointer(to: &uid) {
                    AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, $0, UInt32(MemoryLayout<CFString>.size))
                }
                if set != noErr {
                    NSLog("Voice: mic %@ not selectable (status %d), using system default", deviceUID, set)
                }
            } else {
                NSLog("Voice: preferred mic %@ not found, using system default", deviceUID)
            }
        }

        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(q, Self.bufferBytes, &buffer) == noErr, let b = buffer else {
                AudioQueueDispose(q, true)
                queue = nil
                return "Microphone unavailable (buffer allocation failed)"
            }
            AudioQueueEnqueueBuffer(q, b, 0, nil)
        }

        // Set before the start call: a buffer that arrives while it is still returning
        // must be re-enqueued, or the queue runs dry after three buffers.
        running.set(true)
        let started = AudioQueueStart(q, nil)
        guard started == noErr else {
            running.set(false)
            AudioQueueDispose(q, true)
            queue = nil
            return "Failed to start recording (AudioQueue error \(started))"
        }
        return nil
    }

    /// True when a device with this UID is currently present.
    private static func inputDeviceExists(uid: String) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for id in ids {
            var ref: Unmanaged<CFString>? = nil
            var refSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &refSize, &ref) == noErr else { continue }
            if (ref?.takeRetainedValue() as String?) == uid { return true }
        }
        return false
    }
}

/// Runs its body at most once, from any thread.
private final class Once {
    private let lock = NSLock()
    private var done = false
    private let body: (String?) -> Void

    init(_ body: @escaping (String?) -> Void) {
        self.body = body
    }

    /// Runs the body the first time; returns false if it already ran.
    @discardableResult
    func fire(_ value: String?) -> Bool {
        lock.lock()
        if done {
            lock.unlock()
            return false
        }
        done = true
        lock.unlock()
        body(value)
        return true
    }
}

/// A boolean readable and writable from any thread.
private final class Flag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
