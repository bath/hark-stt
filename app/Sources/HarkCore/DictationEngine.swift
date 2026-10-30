import Foundation

public enum DictationPhase: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case done
    case error(String)
}

/// How long each part of one dictation took.
public struct DictationTimings: Sendable, Equatable {
    /// From the key press to the first mic buffer.
    public var pressToFirstBuffer: Duration
    /// From the second key press until the mic is off.
    public var stopToMicOff: Duration
    /// Whisper alone.
    public var whisper: Duration
    /// From the second key press until the text is pasted.
    public var stopToText: Duration
    /// The length of the recording.
    public var audio: Duration

    public init(pressToFirstBuffer: Duration, stopToMicOff: Duration, whisper: Duration, stopToText: Duration, audio: Duration) {
        self.pressToFirstBuffer = pressToFirstBuffer
        self.stopToMicOff = stopToMicOff
        self.whisper = whisper
        self.stopToText = stopToText
        self.audio = audio
    }
}

public enum DictationEvent: Sendable, Equatable {
    case phase(DictationPhase)
    /// Mic RMS level, 0…1. Only while recording.
    case level(Float)
    case transcript(String)
    case timings(DictationTimings)
}

/// The short messages the island shows when a dictation fails.
public enum DictationError {
    public static let modelLoading = "Model loading"
    public static let microphone = "Mic error"
    public static let transcription = "Failed"
    public static let noSpeech = "No speech"
    public static let paste = "Paste failed"
}

/// Owns the whole life of a dictation: press to start, press to stop,
/// transcribe, paste. Commands go in through `press()` and `cancel()`, and
/// everything the user should see or hear comes out of `events`.
///
/// The rules are the ones the Hammerspoon version uses: a press while
/// recording stops; a press while transcribing does nothing; a press before
/// the model is loaded fails with a message.
public final class DictationEngine: Sendable {
    public let events: AsyncStream<DictationEvent>
    private let commands: AsyncStream<Command>.Continuation
    private let clock: any HarkClock
    private let loop: Task<Void, Never>

    public init(
        microphone: any Microphone,
        transcriber: any Transcriber,
        paster: any Paster,
        clock: any HarkClock = SystemClock()
    ) {
        let (events, output) = AsyncStream<DictationEvent>.makeStream()
        let (commandStream, commands) = AsyncStream<Command>.makeStream()
        self.events = events
        self.commands = commands
        self.clock = clock
        loop = Task {
            let machine = Machine(
                microphone: microphone, transcriber: transcriber, paster: paster,
                clock: clock, output: output, commands: commands
            )
            await machine.prepareMicrophone()
            for await command in commandStream {
                await machine.handle(command)
            }
            output.finish()
        }
    }

    deinit {
        commands.finish()
    }

    /// The hotkey: starts a dictation, or stops the one that is recording.
    public func press() {
        commands.yield(.press(at: clock.now()))
    }

    /// Drops the current dictation without pasting anything.
    public func cancel() {
        commands.yield(.cancel)
    }

    /// Ends the engine. `events` finishes after the commands already sent.
    public func shutdown() {
        commands.finish()
    }
}

enum Command: Sendable {
    case press(at: Duration)
    case cancel
    case level(Float, dictation: Int)
    case microphoneFailed(dictation: Int)
    case transcribed(Result<String, any Error>, whisper: Duration, dictation: Int)
}

/// The state of the engine. It lives inside the engine's one loop task, so
/// commands are handled one at a time, in order.
private final class Machine {
    let microphone: any Microphone
    let transcriber: any Transcriber
    let paster: any Paster
    let clock: any HarkClock
    let output: AsyncStream<DictationEvent>.Continuation
    let commands: AsyncStream<Command>.Continuation

    var phase = DictationPhase.idle
    /// Counts dictations, so a late level, failure or transcript from an old
    /// dictation is dropped.
    var dictation = 0
    var pressedAt = Duration.zero
    var firstBufferAt = Duration.zero
    var stoppedAt = Duration.zero
    var micOffAt = Duration.zero
    var audioLength = Duration.zero
    var transcription: Task<Void, Never>?

    init(
        microphone: any Microphone, transcriber: any Transcriber, paster: any Paster, clock: any HarkClock,
        output: AsyncStream<DictationEvent>.Continuation, commands: AsyncStream<Command>.Continuation
    ) {
        self.microphone = microphone
        self.transcriber = transcriber
        self.paster = paster
        self.clock = clock
        self.output = output
        self.commands = commands
    }

    func prepareMicrophone() async {
        // A failure here is not shown: `start` prepares again and reports it.
        try? await microphone.prepare()
    }

    func handle(_ command: Command) async {
        switch command {
        case let .press(at):
            switch phase {
            case .recording: await stop(at: at)
            case .transcribing: break
            case .idle, .done, .error: await start(at: at)
            }
        case .cancel:
            await cancel()
        case let .level(rms, id):
            if id == dictation && phase == .recording { output.yield(.level(rms)) }
        case let .microphoneFailed(id):
            guard id == dictation && phase == .recording else { return }
            _ = try? await microphone.stop()
            fail(DictationError.microphone)
            await prepareMicrophone()
        case let .transcribed(result, whisper, id):
            guard id == dictation && phase == .transcribing else { return }
            transcription = nil
            await finish(result, whisper: whisper)
        }
    }

    private func set(_ new: DictationPhase) {
        phase = new
        output.yield(.phase(new))
    }

    private func fail(_ message: String) {
        set(.error(message))
    }

    private func start(at: Duration) async {
        guard await transcriber.isLoaded else {
            fail(DictationError.modelLoading)
            return
        }
        dictation += 1
        pressedAt = at
        set(.recording)
        let id = dictation
        let commands = commands
        let handler = MicrophoneHandler(
            level: { commands.yield(.level($0, dictation: id)) },
            failure: { _ in commands.yield(.microphoneFailed(dictation: id)) }
        )
        do {
            try await microphone.start(handler)
            firstBufferAt = clock.now()
        } catch {
            fail(DictationError.microphone)
            await prepareMicrophone()
        }
    }

    private func stop(at: Duration) async {
        stoppedAt = at
        set(.transcribing)
        let samples: Samples
        do {
            samples = try await microphone.stop()
        } catch {
            fail(DictationError.microphone)
            await prepareMicrophone()
            return
        }
        micOffAt = clock.now()
        audioLength = .seconds(Double(samples.count) / Double(whisperSampleRate))
        let id = dictation
        let (transcriber, clock, commands) = (transcriber, clock, commands)
        transcription = Task {
            let started = clock.now()
            let result: Result<String, any Error>
            do {
                result = .success(try await transcriber.transcribe(samples))
            } catch {
                result = .failure(error)
            }
            commands.yield(.transcribed(result, whisper: clock.now() - started, dictation: id))
        }
    }

    private func finish(_ result: Result<String, any Error>, whisper: Duration) async {
        guard case let .success(raw) = result else {
            fail(DictationError.transcription)
            return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail(DictationError.noSpeech)
            return
        }
        do {
            try await paster.paste(text)
        } catch {
            fail(DictationError.paste)
            return
        }
        output.yield(.transcript(text))
        output.yield(.timings(DictationTimings(
            pressToFirstBuffer: firstBufferAt - pressedAt,
            stopToMicOff: micOffAt - stoppedAt,
            whisper: whisper,
            stopToText: clock.now() - stoppedAt,
            audio: audioLength
        )))
        set(.done)
    }

    private func cancel() async {
        switch phase {
        case .recording:
            _ = try? await microphone.stop()
        case .transcribing:
            transcription?.cancel()
            transcription = nil
        case .idle, .done, .error:
            return
        }
        dictation += 1
        set(.idle)
    }
}
