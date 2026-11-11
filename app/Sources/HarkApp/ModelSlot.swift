import Foundation
import HarkCore
import HarkMac

/// The engine's transcriber. It starts empty when there is no model yet and
/// takes the real one when the download is done, or when the user chooses
/// another model.
final class ModelSlot: Transcriber, @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: (any LocalTranscriber)?

    var current: (any LocalTranscriber)? { lock.withLock { transcriber } }

    func fill(_ new: any LocalTranscriber) {
        lock.withLock { transcriber = new }
    }

    /// Takes the transcriber out, so the caller can free it.
    func empty() -> (any LocalTranscriber)? {
        lock.withLock {
            defer { transcriber = nil }
            return transcriber
        }
    }

    var isLoaded: Bool { get async { await current?.isLoaded ?? false } }

    func transcribe(_ samples: Samples) async throws -> String {
        guard let current else { throw TranscriberError.modelNotLoaded }
        return try await current.transcribe(samples)
    }
}
