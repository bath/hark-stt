import Foundation
import Testing
@testable import HarkCore
@testable import HarkMac

@Suite struct ResampleTests {
    @Test func fortyEightKilohertzBecomesSixteen() {
        let tone = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.5 }
        let out = resample(tone, from: 48_000)
        #expect(abs(out.count - 16_000) < 64)
        let rms = (out.map { $0 * $0 }.reduce(0, +) / Float(out.count)).squareRoot()
        #expect(abs(rms - 0.354) < 0.02)
    }

    @Test func sixteenKilohertzIsUnchanged() {
        let samples: Samples = [0.1, 0.2, 0.3]
        #expect(resample(samples, from: 16_000) == samples)
    }
}

/// Real whisper.cpp with the real model. Slow, so it runs only with
/// HARK_SLOW_TESTS=1 and the model in ~/Library/Application Support/Hark.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HARK_SLOW_TESTS"] == "1"
                && ModelLocation.existing() != nil))
struct WhisperSlowTests {
    @Test func transcribesTheFixture() async throws {
        let transcriber = WhisperTranscriber(modelPath: ModelLocation.existing()!.path)
        try await transcriber.load()
        let url = try #require(Bundle.module.url(forResource: "speech", withExtension: "wav", subdirectory: "Fixtures"))
        let samples = try readWav(url)
        #expect(samples.count > 16_000 * 3)

        _ = try await transcriber.transcribe(samples) // warms Metal
        let clock = ContinuousClock()
        var text = ""
        let elapsed = try await clock.measure { text = try await transcriber.transcribe(samples) }
        print("whisper: \(elapsed) for \(Double(samples.count) / 16_000) s: \(text)")
        #expect(text.lowercased().contains("speech into text"))
        #expect(elapsed < .seconds(2))
    }
}

/// Real Parakeet on Core ML. Runs only with HARK_SLOW_TESTS=1 and the model
/// on disk, so it never downloads.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HARK_SLOW_TESTS"] == "1"
                && ParakeetTranscriber.isDownloaded))
struct ParakeetSlowTests {
    @Test func transcribesTheFixture() async throws {
        let transcriber = ParakeetTranscriber()
        #expect(await !transcriber.isLoaded)
        try await transcriber.load()
        let url = try #require(Bundle.module.url(forResource: "speech", withExtension: "wav", subdirectory: "Fixtures"))
        let samples = try readWav(url)

        _ = try await transcriber.transcribe(samples) // warms Core ML
        let clock = ContinuousClock()
        var text = ""
        let elapsed = try await clock.measure { text = try await transcriber.transcribe(samples) }
        print("parakeet: \(elapsed) for \(Double(samples.count) / 16_000) s: \(text)")
        #expect(text.lowercased().contains("speech into text"))
        #expect(elapsed < .seconds(2))

        // Whisper pads a very short recording; Parakeet must not fail on one.
        _ = try await transcriber.transcribe(Samples(repeating: 0, count: 1_600))

        await transcriber.unload()
        #expect(await !transcriber.isLoaded)
        await #expect(throws: TranscriberError.self) { try await transcriber.transcribe(samples) }
    }
}
