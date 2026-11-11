import FluidAudio
import Foundation
import HarkCore

/// A transcriber whose model the app loads and frees.
public protocol LocalTranscriber: Transcriber {
    func load() async throws
    /// Frees the model.
    func unload() async
}

extension WhisperTranscriber: LocalTranscriber {}

/// Parakeet in this process, on Core ML (the Neural Engine), through
/// FluidAudio. The model is a folder of Core ML bundles next to the Whisper model.
public final class ParakeetTranscriber: LocalTranscriber, @unchecked Sendable {
    /// TDT 0.6B v2: the English model, as Hark dictates English.
    static let version = AsrModelVersion.v2

    /// Where the app keeps its download.
    public static var directory: URL {
        ModelLocation.appSupport.deletingLastPathComponent()
            .appending(path: AsrModels.defaultCacheDirectory(for: version).lastPathComponent)
    }

    /// The complete model is on disk.
    public static var isDownloaded: Bool {
        AsrModels.modelsExist(at: directory, version: version)
    }

    private let manager = AsrManager()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var loaded = false

    public init() {}

    public var isLoaded: Bool {
        lock.withLock { loaded }
    }

    public func load() async throws {
        try await load { _ in }
    }

    /// Downloads the model when it is not on disk (a stopped download goes on
    /// from where it stopped), then loads it. `progress` gets 0…1.
    public func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isLoaded { return }
        let models = try await AsrModels.downloadAndLoad(to: Self.directory, version: Self.version) {
            progress($0.fractionCompleted)
        }
        try Task.checkCancellation()
        try await manager.loadModels(models)
        lock.withLock { loaded = true }
    }

    public func unload() async {
        lock.withLock { loaded = false }
        await manager.cleanup()
    }

    public func transcribe(_ samples: Samples) async throws -> String {
        guard isLoaded else { throw TranscriberError.modelNotLoaded }
        // FluidAudio refuses very short audio; Whisper pads it, so do the same.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: whisperSampleRate)
        let audio = samples.count < minimum ? samples + Samples(repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
