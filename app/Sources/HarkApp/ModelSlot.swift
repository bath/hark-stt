import Foundation
import HarkCore
import HarkMac

/// The engine's transcriber. It starts empty when there is no model yet and
/// takes the real one when the download is done.
final class ModelSlot: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var whisper: WhisperTranscriber?

    var current: WhisperTranscriber? { lock.withLock { whisper } }

    func fill(_ transcriber: WhisperTranscriber) {
        lock.withLock { whisper = transcriber }
    }

    var isLoaded: Bool { current?.isLoaded ?? false }

    func transcribe(_ samples: Samples) async throws -> String {
        guard let current else { throw TranscriberError.modelNotLoaded }
        return try await current.transcribe(samples)
    }
}
