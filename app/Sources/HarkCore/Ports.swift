import Foundation

/// Mono audio at 16 kHz, in −1…1. This is what Whisper reads.
public typealias Samples = [Float]

public let whisperSampleRate = 16_000

/// The mic. The adapter keeps the input prepared but stopped between
/// dictations, so `start` only has to start the hardware.
public protocol Microphone: Sendable {
    /// Opens the input without starting it. Called at launch and after a failure.
    func prepare() async throws
    /// Starts the mic and returns when the first buffer has arrived.
    func start(_ handler: MicrophoneHandler) async throws
    /// Stops the mic, waits until it is off, and returns everything since `start`.
    func stop() async throws -> Samples
}

/// How the mic reports while it records. Both closures may run on any thread.
public struct MicrophoneHandler: Sendable {
    /// RMS level, 0…1, about 30 times a second.
    public var level: @Sendable (Float) -> Void
    /// The mic stopped working while it recorded, for example because it was unplugged.
    public var failure: @Sendable (any Error) -> Void

    public init(level: @escaping @Sendable (Float) -> Void, failure: @escaping @Sendable (any Error) -> Void) {
        self.level = level
        self.failure = failure
    }
}

/// Speech to text.
public protocol Transcriber: Sendable {
    /// False until the model is in memory.
    var isLoaded: Bool { get async }
    func transcribe(_ samples: Samples) async throws -> String
}

/// Puts the text where the user's cursor is. The text stays on the clipboard.
public protocol Paster: Sendable {
    func paste(_ text: String) async throws
}

/// A monotonic clock. Only differences between two readings mean anything.
public protocol HarkClock: Sendable {
    func now() -> Duration
}

public struct SystemClock: HarkClock {
    public init() {}
    public func now() -> Duration {
        .nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds))
    }
}
