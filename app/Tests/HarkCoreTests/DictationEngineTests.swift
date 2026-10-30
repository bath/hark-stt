import Testing
@testable import HarkCore

@Suite struct DictationEngineTests {
    @Test func pressTalkPressPastesTheText() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        rig.engine.press()
        rig.engine.press()
        let seen = await events.untilPhase(.done)
        #expect(seen.filter(\.isPhase) == [.phase(.recording), .phase(.transcribing), .phase(.done)])
        #expect(seen.contains(.transcript("Hello world.")))
        #expect(await rig.paster.pasted == ["Hello world."])
        #expect(await rig.transcriber.received.first?.count == whisperSampleRate * 2)
    }

    @Test func theTimingsAreReported() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        rig.engine.press()
        // The second press comes after the mic is on, as it does for a person.
        _ = await events.until(\.isLevel)
        rig.engine.press()
        let timings = await events.until { if case .timings = $0 { true } else { false } }.last
        #expect(timings == .timings(DictationTimings(
            pressToFirstBuffer: .milliseconds(60),
            stopToMicOff: .milliseconds(15),
            whisper: .milliseconds(300),
            stopToText: .milliseconds(315),
            audio: .seconds(2)
        )))
    }

    @Test func theTextIsTrimmedAndEmptyTextIsNoSpeech() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.transcriber.set { $0.text = "  \n " }
        rig.engine.press()
        rig.engine.press()
        let seen = await events.until { if case .phase(.error) = $0 { true } else { false } }
        #expect(seen.last == .phase(.error(DictationError.noSpeech)))
        #expect(await rig.paster.pasted.isEmpty)

        await rig.transcriber.set { $0.text = "  Spaced out.\n" }
        rig.engine.press()
        rig.engine.press()
        _ = await events.untilPhase(.done)
        #expect(await rig.paster.pasted == ["Spaced out."])
    }

    @Test func aPressWhileTranscribingDoesNothing() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        rig.engine.press()
        rig.engine.press()
        rig.engine.press()
        let seen = await events.untilPhase(.done)
        #expect(seen.filter(\.isPhase) == [.phase(.recording), .phase(.transcribing), .phase(.done)])
        #expect(await rig.microphone.starts == 1)
        #expect(await rig.paster.pasted.count == 1)
    }

    @Test func aPressBeforeTheModelIsLoadedFailsWithAMessage() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.transcriber.set { $0.loaded = false }
        rig.engine.press()
        #expect(await events.next() == .phase(.error(DictationError.modelLoading)))
        #expect(await rig.microphone.starts == 0)

        // When the model is in, the next press works.
        await rig.transcriber.set { $0.loaded = true }
        rig.engine.press()
        #expect(await events.next() == .phase(.recording))
    }

    @Test func aMicThatCannotStartIsAnErrorAndIsPreparedAgain() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.microphone.set { $0.failStart = true }
        rig.engine.press()
        let seen = await events.until { if case .phase(.error) = $0 { true } else { false } }
        #expect(seen == [.phase(.recording), .phase(.error(DictationError.microphone))])
        // Once at launch, once after the failure.
        #expect(await rig.microphone.prepares == 2)
    }

    @Test func aMicFailureWhileRecordingIsAnError() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        rig.engine.press()
        _ = await events.until(\.isLevel)
        await rig.microphone.breakDown()
        let seen = await events.until { if case .phase(.error) = $0 { true } else { false } }
        #expect(seen.last == .phase(.error(DictationError.microphone)))
        #expect(await rig.microphone.stops == 1)
        #expect(await rig.transcriber.received.isEmpty)
    }

    @Test func aMicThatCannotStopIsAnError() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.microphone.set { $0.failStop = true }
        rig.engine.press()
        rig.engine.press()
        let seen = await events.until { if case .phase(.error) = $0 { true } else { false } }
        #expect(seen.last == .phase(.error(DictationError.microphone)))
        #expect(await rig.transcriber.received.isEmpty)
    }

    @Test func aWhisperFailureIsAnError() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.transcriber.set { $0.fails = true }
        rig.engine.press()
        rig.engine.press()
        let seen = await events.until { if case .phase(.error) = $0 { true } else { false } }
        #expect(seen.last == .phase(.error(DictationError.transcription)))
        #expect(await rig.paster.pasted.isEmpty)
    }

    @Test func aPasteFailureIsAnError() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.paster.set { $0.fails = true }
        rig.engine.press()
        rig.engine.press()
        let seen = await events.until { if case .phase(.error) = $0 { true } else { false } }
        #expect(seen.last == .phase(.error(DictationError.paste)))
    }

    @Test func aStopDuringMicStartUpStopsOnceTheMicIsOn() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.microphone.set { $0.holdStart = true }
        rig.engine.press()
        #expect(await events.next() == .phase(.recording))
        rig.engine.press()
        await rig.microphone.releaseStart()
        let seen = await events.untilPhase(.done)
        #expect(seen.filter(\.isPhase) == [.phase(.transcribing), .phase(.done)])
        #expect(await rig.microphone.stops == 1)
    }

    @Test func levelsArriveOnlyWhileRecording() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        rig.engine.press()
        let recording = await events.until { $0 == .level(0.2) }
        #expect(recording == [.phase(.recording), .level(0.1), .level(0.2)])
        rig.engine.press()
        _ = await events.untilPhase(.transcribing)
        await rig.microphone.sendLevel(0.9)
        let after = await events.untilPhase(.done)
        let leaked = after.contains { $0.isLevel }
        #expect(!leaked)
    }

    @Test func cancelWhileRecordingDropsTheDictation() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        rig.engine.press()
        _ = await events.untilPhase(.recording)
        rig.engine.cancel()
        _ = await events.untilPhase(.idle)
        #expect(await rig.microphone.stops == 1)
        #expect(await rig.transcriber.received.isEmpty)
        // The next press starts a new dictation.
        rig.engine.press()
        #expect(await events.until { $0.isPhase } == [.phase(.recording)])
    }

    @Test func cancelWhileTranscribingPastesNothing() async {
        let rig = Rig()
        var events = EventReader(rig.engine)
        await rig.transcriber.set { $0.hold = true }
        rig.engine.press()
        rig.engine.press()
        _ = await events.untilPhase(.transcribing)
        rig.engine.cancel()
        _ = await events.untilPhase(.idle)
        await rig.transcriber.release()
        rig.engine.shutdown()
        while await events.next() != nil {}
        #expect(await rig.paster.pasted.isEmpty)
    }
}
