import Foundation
import HarkCore
import whisper

public enum TranscriberError: Error, CustomStringConvertible {
    case modelNotLoaded
    case modelLoadFailed(String)
    case whisperFailed(Int32)

    public var description: String {
        switch self {
        case .modelNotLoaded: "the Whisper model is not loaded"
        case let .modelLoadFailed(path): "could not load the Whisper model at \(path)"
        case let .whisperFailed(code): "whisper_full failed with code \(code)"
        }
    }
}

/// whisper.cpp in this process, on Metal. The model is loaded once and kept.
/// Audio comes in memory; there is no WAV file, server or HTTP.
public final class WhisperTranscriber: Transcriber, @unchecked Sendable {
    private let modelPath: String
    private let language: String
    private let threads: Int32
    /// whisper.cpp contexts are not thread-safe, so every call runs here, one at a time.
    private let queue = DispatchQueue(label: "works.hark.whisper", qos: .userInitiated)
    private let lock = NSLock()
    // Guarded by `lock`.
    private var context: OpaquePointer?

    public init(modelPath: String, language: String = "en", threads: Int32 = 4) {
        self.modelPath = modelPath
        self.language = language
        self.threads = threads
        quietLogs()
    }

    deinit {
        if let context { whisper_free(context) }
    }

    public var isLoaded: Bool {
        lock.withLock { context != nil }
    }

    /// Loads the model. A few seconds for large-v3-turbo; later calls return at once.
    public func load() async throws {
        try await onQueue { try self.loadOnQueue() }
    }

    /// Frees the model. Call it before the process exits: ggml's Metal
    /// backend asserts at exit while a context is still alive.
    public func unload() async {
        _ = try? await onQueue {
            if let context = self.lock.withLock({ () -> OpaquePointer? in
                defer { self.context = nil }
                return self.context
            }) {
                whisper_free(context)
            }
        }
    }

    public func transcribe(_ samples: Samples) async throws -> String {
        try await onQueue {
            guard let context = self.lock.withLock({ self.context }) else { throw TranscriberError.modelNotLoaded }
            let code = self.run(context, samples)
            guard code == 0 else {
                // A failed context may be broken. Load it again for the next dictation.
                self.lock.withLock { self.context = nil }
                whisper_free(context)
                try? self.loadOnQueue()
                throw TranscriberError.whisperFailed(code)
            }
            var text = ""
            for segment in 0..<whisper_full_n_segments(context) {
                text += String(cString: whisper_full_get_segment_text(context, segment))
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func loadOnQueue() throws {
        if isLoaded { return }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let loaded = whisper_init_from_file_with_params(modelPath, params) else {
            throw TranscriberError.modelLoadFailed(modelPath)
        }
        lock.withLock { context = loaded }
    }

    /// The same settings as whisper-server's defaults, which the Hammerspoon
    /// version used: greedy decoding, best of 2, temperature fallback.
    private func run(_ context: OpaquePointer, _ samples: Samples) -> Int32 {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.greedy.best_of = 2
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        return language.withCString { language in
            params.language = language
            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
    }
}

/// whisper.cpp and ggml print a lot to stderr. Set HARK_WHISPER_LOG=1 to see it.
private func quietLogs() {
    guard ProcessInfo.processInfo.environment["HARK_WHISPER_LOG"] == nil else { return }
    whisper_log_set({ _, _, _ in }, nil)
    ggml_log_set({ _, _, _ in }, nil)
}
