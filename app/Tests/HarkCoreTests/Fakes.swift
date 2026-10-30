import Foundation
@testable import HarkCore

/// A clock that only moves when a fake says so, so timings are exact.
final class TestClock: HarkClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Duration.zero

    func now() -> Duration { lock.withLock { current } }
    func advance(_ by: Duration) { lock.withLock { current += by } }
}

struct FakeError: Error {}

/// A mic that plays set levels and samples, and fails when told to.
actor FakeMicrophone: Microphone {
    let clock: TestClock
    var startDelay = Duration.milliseconds(60)
    var stopDelay = Duration.milliseconds(15)
    var levels: [Float] = [0.1, 0.2]
    var samples: Samples = Samples(repeating: 0.1, count: whisperSampleRate * 2)
    var failStart = false
    var failStop = false
    var holdStart = false

    private(set) var prepares = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private var handler: MicrophoneHandler?
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    init(clock: TestClock) { self.clock = clock }

    func set(_ change: @Sendable (isolated FakeMicrophone) -> Void) { change(self) }

    func prepare() async throws { prepares += 1 }

    func start(_ handler: MicrophoneHandler) async throws {
        starts += 1
        if holdStart {
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiters.forEach { $0.resume() }
                heldWaiters = []
            }
        }
        if failStart { throw FakeError() }
        clock.advance(startDelay)
        self.handler = handler
        levels.forEach(handler.level)
    }

    /// Waits until a start is held, then lets it finish.
    func releaseStart() async {
        if held == nil { await withCheckedContinuation { heldWaiters.append($0) } }
        held?.resume()
        held = nil
    }

    func stop() async throws -> Samples {
        stops += 1
        if failStop { throw FakeError() }
        clock.advance(stopDelay)
        return samples
    }

    /// The mic speaks after it was stopped, or fails while it records.
    func sendLevel(_ rms: Float) { handler?.level(rms) }
    func breakDown() { handler?.failure(FakeError()) }
}

actor FakeTranscriber: Transcriber {
    let clock: TestClock
    var loaded = true
    var text = "Hello world."
    var fails = false
    var delay = Duration.milliseconds(300)
    var hold = false
    private(set) var received: [Samples] = []
    private var held: CheckedContinuation<Void, Never>?

    init(clock: TestClock) { self.clock = clock }

    func set(_ change: @Sendable (isolated FakeTranscriber) -> Void) { change(self) }

    var isLoaded: Bool { loaded }

    func transcribe(_ samples: Samples) async throws -> String {
        received.append(samples)
        if hold { await withCheckedContinuation { held = $0 } }
        clock.advance(delay)
        if fails { throw FakeError() }
        return text
    }

    func release() {
        held?.resume()
        held = nil
    }
}

actor FakePaster: Paster {
    var fails = false
    private(set) var pasted: [String] = []

    func set(_ change: @Sendable (isolated FakePaster) -> Void) { change(self) }

    func paste(_ text: String) async throws {
        if fails { throw FakeError() }
        pasted.append(text)
    }
}

/// Reads the engine's events in order.
struct EventReader {
    var iterator: AsyncStream<DictationEvent>.Iterator

    init(_ engine: DictationEngine) { iterator = engine.events.makeAsyncIterator() }

    mutating func next() async -> DictationEvent? { await iterator.next() }

    /// The events up to and including the first one that matches.
    mutating func until(_ stop: (DictationEvent) -> Bool) async -> [DictationEvent] {
        var seen: [DictationEvent] = []
        while let event = await iterator.next() {
            seen.append(event)
            if stop(event) { break }
        }
        return seen
    }

    mutating func untilPhase(_ phase: DictationPhase) async -> [DictationEvent] {
        await until { $0 == .phase(phase) }
    }
}

struct Rig {
    let clock = TestClock()
    let microphone: FakeMicrophone
    let transcriber: FakeTranscriber
    let paster = FakePaster()
    let engine: DictationEngine

    init() {
        microphone = FakeMicrophone(clock: clock)
        transcriber = FakeTranscriber(clock: clock)
        engine = DictationEngine(microphone: microphone, transcriber: transcriber, paster: paster, clock: clock)
    }
}

extension DictationEvent {
    var isLevel: Bool { if case .level = self { true } else { false } }
    var isPhase: Bool { if case .phase = self { true } else { false } }
}
