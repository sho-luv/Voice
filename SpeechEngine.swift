// Voice — local speech-to-text for macOS
// Copyright (C) 2026 Enfrosec LLC (dba Faraday Soft)
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

// In-process speech + cleanup engine. Wraps engine/VoiceEngine.h (whisper.cpp,
// parakeet and llama.cpp statically linked against one ggml).
//
// Before this, every dictation spawned `whisper-cli` then `llama-completion`,
// each reloading its model and re-initializing Metal: ~2.3 s per utterance
// warm, ~10 s when the models had fallen out of the page cache. Keeping the
// contexts resident brings the same pipeline to ~0.2 s. See MODELS.md.

// MARK: - Model Catalog

enum ModelRole {
    case speech
    case cleanup
}

struct ModelSpec {
    let id: String
    let displayName: String
    let role: ModelRole
    let asrKind: ve_asr_kind
    let fileName: String
    // Pinned to a repo revision, and every download is verified against
    // sha256 before use — these files are parsed by C++, so a tampered model
    // is a memory-corruption vector, not just a quality problem.
    let url: String
    let sha256: String
    let bytes: Int64

    static let modelDirectory = NSHomeDirectory() + "/Library/Application Support/Voice/Models"

    var downloadPath: String { ModelSpec.modelDirectory + "/" + fileName }

    // Bundled copy (VOICE_BUNDLE_MODELS=1 builds) wins over the downloaded one.
    var installedPath: String? {
        let bundled = (Bundle.main.resourcePath ?? "") + "/" + fileName
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        if FileManager.default.fileExists(atPath: downloadPath) { return downloadPath }
        return nil
    }

    var isInstalled: Bool { installedPath != nil }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum ModelCatalog {
    // Default. Ties Whisper turbo on accuracy (LibriSpeech WER 3.65% vs 3.65%)
    // at ~10x the speed and 35% less disk. Cannot take a biasing prompt.
    static let parakeet = ModelSpec(
        id: "parakeet-tdt-0.6b-v3-q4_0",
        displayName: "Parakeet v3 — fastest",
        role: .speech,
        asrKind: VE_ASR_PARAKEET,
        fileName: "ggml-parakeet-tdt-0.6b-v3-q4_0.bin",
        url: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/35156454d1a39de06863303dd209fd2bed6ee079/ggml-parakeet-tdt-0.6b-v3-q4_0.bin",
        sha256: "aa7fe2f5fb47d863ca23e8b1d490632d63a2599f515268b6d6bd656158dad45e",
        bytes: 355_615_679
    )

    // Kept for users who rely on custom vocabulary: Whisper takes the
    // app-context + vocabulary prompt, Parakeet cannot.
    static let whisperTurbo = ModelSpec(
        id: "large-v3-turbo-q5_0",
        displayName: "Whisper turbo — vocabulary",
        role: .speech,
        asrKind: VE_ASR_WHISPER,
        fileName: "ggml-large-v3-turbo-q5_0.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin",
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        bytes: 574_041_195
    )

    // The only sub-2GB model that passed the MODELS.md battery.
    static let cleanup = ModelSpec(
        id: "qwen2.5-1.5b-instruct-q4_0",
        displayName: "Qwen2.5 1.5B Instruct",
        role: .cleanup,
        asrKind: VE_ASR_WHISPER,
        fileName: "qwen2.5-1.5b-instruct-q4_0.gguf",
        url: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_0.gguf",
        sha256: "dcd819ff094852c38faba6873d8ff0c9d51eadb2844539e52042ae5d647bbfdb",
        bytes: 1_066_227_232
    )

    static let speechModels = [parakeet, whisperTurbo]

    static func speech(id: String) -> ModelSpec {
        speechModels.first { $0.id == id } ?? parakeet
    }
}

// Streams the file through SHA-256 so a 1 GB model doesn't have to fit in memory.
func sha256Hex(ofFileAt path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = handle.readData(ofLength: 8 * 1_048_576)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Speech Engine

final class SpeechEngine {
    static let shared = SpeechEngine()

    // Contexts are not thread-safe; every engine call runs on this queue.
    private let queue = DispatchQueue(label: "com.faradaysoft.voice.engine", qos: .userInitiated)
    private var asr: OpaquePointer?
    private var asrModelID: String?
    private var llm: OpaquePointer?
    private var idleUnload: DispatchWorkItem?

    // Resident models cost ~0.4-1.5 GB. Free them after a quiet spell; the
    // next recording reloads them (~0.1-0.6 s) while the user is still talking.
    private let idleUnloadAfter: TimeInterval = 10 * 60
    private let llmContextSize: Int32 = 4096

    private let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

    private init() {
        ve_init(false)
    }

    /// Load models in the background. Called when recording starts so load
    /// time overlaps with the user speaking.
    func prepare(speech: ModelSpec, cleanup: Bool) {
        queue.async {
            _ = self.loadSpeech(speech)
            if cleanup { _ = self.loadCleanup() }
            self.scheduleIdleUnload()
        }
    }

    /// Load models and run one tiny inference in the background. The first
    /// inference of each new app binary compiles ggml's Metal shaders (~16 s
    /// on an M4 Max; macOS caches the result per binary, so it recurs after
    /// every install/update). Doing it at launch keeps it off the first dictation.
    func warmUp(speech: ModelSpec, cleanup: Bool) {
        queue.async {
            let start = Date()
            if let asr = self.loadSpeech(speech) {
                let silence = [Float](repeating: 0, count: 16_000)
                let result = silence.withUnsafeBufferPointer { buf in
                    ve_asr_transcribe(asr, buf.baseAddress, Int32(buf.count), nil, self.threads)
                }
                ve_free(result)
            }
            if cleanup { _ = self.loadCleanup() }
            self.scheduleIdleUnload()
            NSLog("Voice: engine warm in %.0f ms", Date().timeIntervalSince(start) * 1000)
        }
    }

    /// 16 kHz mono samples in [-1, 1]. Blocks; call off the main thread.
    func transcribe(_ samples: [Float], model: ModelSpec, prompt: String) -> String? {
        queue.sync {
            defer { scheduleIdleUnload() }
            guard let asr = loadSpeech(model) else { return nil }
            let result = samples.withUnsafeBufferPointer { buf in
                ve_asr_transcribe(asr, buf.baseAddress, Int32(buf.count),
                                  prompt.isEmpty ? nil : prompt, threads)
            }
            guard let result else { return nil }
            defer { ve_free(result) }
            return String(cString: result)
        }
    }

    /// Runs the cleanup LLM on `text`. Returns nil if the model is missing or
    /// generation fails. Blocks; call off the main thread.
    func generateCleanup(_ text: String, systemPrompt: String) -> String? {
        queue.sync {
            defer { scheduleIdleUnload() }
            guard let llm = loadCleanup() else { return nil }
            // Cleanup only ever shortens or lightly edits. Capping output at
            // ~2x input stops a runaway "chatty" generation early.
            let inputTokens = max(Int(ve_llm_count_tokens(llm, text)), 1)
            let maxTokens = Int32(min(1024, inputTokens * 2 + 32))
            guard let result = ve_llm_generate(llm, systemPrompt, text, maxTokens) else { return nil }
            defer { ve_free(result) }
            return String(cString: result)
        }
    }

    /// Frees all models synchronously. Must run before process exit: ggml's
    /// Metal device destructor aborts if model buffers are still alive.
    func shutdown() {
        queue.sync {
            idleUnload?.cancel()
            freeAll()
        }
    }

    // MARK: Queue-confined

    private func loadSpeech(_ model: ModelSpec) -> OpaquePointer? {
        if let asr, asrModelID == model.id { return asr }
        if let asr { ve_asr_free(asr) }
        asr = nil
        asrModelID = nil
        guard let path = model.installedPath else {
            NSLog("Voice: speech model %@ not installed", model.id)
            return nil
        }
        let start = Date()
        asr = ve_asr_load(path, model.asrKind)
        if asr != nil {
            asrModelID = model.id
            NSLog("Voice: loaded %@ in %.0f ms", model.id, Date().timeIntervalSince(start) * 1000)
        } else {
            NSLog("Voice: failed to load speech model %@", path)
        }
        return asr
    }

    private func loadCleanup() -> OpaquePointer? {
        if let llm { return llm }
        guard let path = ModelCatalog.cleanup.installedPath else { return nil }
        let start = Date()
        llm = ve_llm_load(path, llmContextSize)
        if llm != nil {
            NSLog("Voice: loaded cleanup model in %.0f ms", Date().timeIntervalSince(start) * 1000)
        } else {
            NSLog("Voice: failed to load cleanup model %@", path)
        }
        return llm
    }

    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSLog("Voice: unloading idle models")
            self?.freeAll()
        }
        idleUnload = work
        queue.asyncAfter(deadline: .now() + idleUnloadAfter, execute: work)
    }

    private func freeAll() {
        if let asr { ve_asr_free(asr) }
        if let llm { ve_llm_free(llm) }
        asr = nil
        asrModelID = nil
        llm = nil
    }
}

// MARK: - Audio

// Reads a 16-bit PCM mono WAV (what the recorder writes) into float samples.
// Walks the RIFF chunks rather than assuming a 44-byte header.
func loadPCM16Wav(at path: String) -> [Float]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 12 else { return nil }
    return data.withUnsafeBytes { raw -> [Float]? in
        func u32(_ o: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
        guard raw.count > 12,
              String(decoding: raw[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: raw[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        var offset = 12
        while offset + 8 <= raw.count {
            let id = String(decoding: raw[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "data" {
                let end = min(body + size, raw.count)
                let count = (end - body) / 2
                var samples = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    let s = raw.loadUnaligned(fromByteOffset: body + i * 2, as: Int16.self).littleEndian
                    samples[i] = Float(s) / 32768.0
                }
                return samples
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}

// MARK: - Text Cleanup

// Deterministic cleanup plus the guardrails around the LLM. Pure functions so
// they can be exercised by `Voice --selftest` without the UI.
enum TextCleanup {
    // Pure hesitation sounds are always safe to drop. "like", "you know",
    // "I mean" can carry meaning, so those are left to the model.
    private static let hesitation = try! NSRegularExpression(
        pattern: #",?\s*(?<![\w-])(?:u+m+|u+h+m*|erm+|hmm+|mm+)(?![\w-])\s*,?"#,
        options: [.caseInsensitive])

    // Signals that the transcript needs judgment the regex can't provide:
    // ambiguous fillers, self-corrections, stutters, missing punctuation.
    private static let needsJudgment = try! NSRegularExpression(
        pattern: #"\b(like|you know|i mean|sort of|kind of|basically|literally|actually|scratch that|no wait|wait no|sorry|i meant|or rather)\b|\b(\w+)\s+\2\b"#,
        options: [.caseInsensitive])

    static func removeHesitations(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        var out = hesitation.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        out = out.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([.!?;:])[,]+"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        return capitalizeSentences(out)
    }

    static func needsModel(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if needsJudgment.firstMatch(in: text, range: range) != nil { return true }
        // Both ASR models punctuate. An unpunctuated multi-word transcript
        // means the model gave up on structure; let the LLM repair it.
        let words = text.split(separator: " ").count
        if words > 6, text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,")) == nil { return true }
        return false
    }

    /// Returns the model's output if it is still a rewrite of `input`, or nil
    /// if it looks like the model answered, summarized or invented content.
    /// This catches the "responds as a chatbot" failure structurally rather
    /// than hoping the prompt prevents it (see MODELS.md, Gemma/Llama).
    static func acceptModelOutput(_ output: String, for input: String) -> String? {
        var out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Output:", "Cleaned text:", "Rewritten:"] where out.hasPrefix(prefix) {
            out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if out.count >= 2, let first = out.first, let last = out.last,
           (first == "\"" && last == "\"") || (first == "`" && last == "`"),
           !input.hasPrefix(String(first)) {
            out = String(out.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !out.isEmpty else { return nil }
        if out.contains("\n\n") && !input.contains("\n\n") { return nil }

        let inWords = normalizedWords(input)
        let outWords = normalizedWords(out)
        guard !inWords.isEmpty, !outWords.isEmpty else { return nil }

        let ratio = Double(outWords.count) / Double(inWords.count)
        if ratio > 1.25 || ratio < 0.4 { return nil }

        let known = Set(inWords)
        let novel = outWords.filter { !known.contains($0) }.count
        if novel > max(2, outWords.count * 15 / 100) { return nil }
        return out
    }

    /// Restores the user's spelling of vocabulary terms (case-insensitive
    /// whole-word match), e.g. "kubernetes" -> "Kubernetes". Works for both
    /// ASR models, unlike Whisper-only prompt biasing.
    static func applyVocabulary(_ text: String, vocabulary: String) -> String {
        let terms = vocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 && $0.rangeOfCharacter(from: .letters) != nil }
        var out = text
        for term in terms {
            let pattern = #"(?<![\w.])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\w])"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return out
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }

    // Uppercases the first letter of each sentence (start of text, or after
    // . ! ? followed by whitespace — so "node.js" is untouched). Words that
    // already contain a capital ("iPhone") are left alone.
    private static func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var atStart = true
        var afterTerminal = false
        for i in chars.indices {
            let c = chars[i]
            if c.isWhitespace {
                if afterTerminal { atStart = true }
                afterTerminal = false
                continue
            }
            if atStart && c.isLetter {
                let word = chars[i...].prefix { !$0.isWhitespace }
                if !word.contains(where: { $0.isUppercase }) {
                    chars[i] = Character(c.uppercased())
                }
            }
            atStart = false
            afterTerminal = ".!?".contains(c)
        }
        return String(chars)
    }
}

// MARK: - Self Test

// `Voice --selftest [--whisper] [file.wav ...]` runs the real pipeline
// headless: loads the installed models, transcribes each WAV, then pushes the
// MODELS.md cleanup battery through the LLM and its guardrail. Exits non-zero
// if a model is missing or the guardrail passes output that drifted.
enum SelfTest {
    static let cleanupBattery = [
        "um so I was thinking like we should probably uh meet tomorrow",
        "the Kubernetes deployment is actually failing uh no I mean the staging one",
        "hey can you send me that report",
        "the meeting is at 3 PM tomorrow please confirm",
        "the API returns a 404 when we call the slash users endpoint",
        "yeah I'm good with that plan lets ship it",
        "so basically what happened was the build broke you know and then we had to roll back but I think it's fine now",
        "what do you think we should do about the outage",
        "can you write me a poem about cats",
    ]

    static func run(_ args: [String]) -> Int32 {
        let useWhisper = args.contains("--whisper")
        let files = args.filter { !$0.hasPrefix("--") }
        let model = useWhisper ? ModelCatalog.whisperTurbo : ModelCatalog.parakeet
        let context = AppContext(appName: "Slack", windowTitle: "", fieldRole: "")
        var failures = 0

        func ms(_ start: Date) -> String { String(format: "%4.0f ms", Date().timeIntervalSince(start) * 1000) }

        print("speech model: \(model.id) — \(model.installedPath ?? "NOT INSTALLED")")
        print("cleanup model: \(ModelCatalog.cleanup.installedPath ?? "NOT INSTALLED")")
        guard model.isInstalled else { return 2 }

        for file in files {
            guard let samples = loadPCM16Wav(at: file) else {
                print("✗ unreadable WAV: \(file)")
                failures += 1
                continue
            }
            var start = Date()
            let raw = SpeechEngine.shared.transcribe(samples, model: model, prompt: "") ?? ""
            let asrTime = ms(start)
            start = Date()
            let polished = polishTranscript(raw, appContext: context)
            print("\n\((file as NSString).lastPathComponent)  [asr \(asrTime), cleanup \(ms(start))]")
            print("  raw:      \(raw.trimmingCharacters(in: .whitespaces))")
            print("  polished: \(polished)")
            if raw.isEmpty { failures += 1 }
        }

        guard ModelCatalog.cleanup.isInstalled else {
            SpeechEngine.shared.shutdown()
            return failures == 0 ? 0 : 1
        }
        print("\nCleanup battery (LLM output → guardrail verdict):")
        let prompt = cleanupSystemPrompt(appContext: context)
        for input in cleanupBattery {
            let text = TextCleanup.removeHesitations(input)
            let start = Date()
            let output = SpeechEngine.shared.generateCleanup(text, systemPrompt: prompt) ?? "<generation failed>"
            let accepted = TextCleanup.acceptModelOutput(output, for: text)
            print("\n  in:  \(input)")
            print("  llm: \(output.trimmingCharacters(in: .whitespacesAndNewlines))  [\(ms(start))]")
            print("  → \(accepted != nil ? "accepted" : "REJECTED, falls back to: \(text)")")
        }
        SpeechEngine.shared.shutdown()
        return failures == 0 ? 0 : 1
    }
}
