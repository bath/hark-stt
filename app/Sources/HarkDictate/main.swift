// hark-dictate: dictate from the terminal with the Swift engine.
//
//   swift run -c release hark-dictate [--model PATH] [--device NAME]
//   swift run -c release hark-dictate --file speech.wav    (16 kHz mono 16-bit)
//
// Press Return to start, talk, press Return to stop. The text and the timings
// are printed instead of pasted. Ctrl-D quits. With --file, it transcribes the
// file three times and prints the Whisper time of each run.

import Foundation
import HarkCore
import HarkMac

struct PrintPaster: Paster {
    func paste(_ text: String) async throws {}
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func ms(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.1f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
}

func err(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

let modelPath = option("--model") ?? ModelLocation.legacy.path
guard FileManager.default.fileExists(atPath: modelPath) else {
    err("No model at \(modelPath). Pass --model PATH.")
    exit(1)
}

let transcriber = WhisperTranscriber(modelPath: modelPath)
let microphone = CoreAudioMicrophone(deviceName: option("--device"))
let engine = DictationEngine(microphone: microphone, transcriber: transcriber, paster: PrintPaster())

err("Loading \(modelPath)…")
let loadStart = ContinuousClock.now
do {
    try await transcriber.load()
} catch {
    err("\(error)")
    exit(1)
}
err("Model loaded in \(ms(ContinuousClock.now - loadStart)).")

if let file = option("--file") {
    let samples = try readWav(URL(fileURLWithPath: file))
    for _ in 0..<3 {
        let started = ContinuousClock.now
        let text = try await transcriber.transcribe(samples)
        err("whisper \(ms(ContinuousClock.now - started)) for \(Double(samples.count) / Double(whisperSampleRate)) s of audio")
        print(text)
    }
    await transcriber.unload()
    exit(0)
}

err("Mic: \(microphone.deviceInUse ?? "not ready yet").")
err("Press Return to start, Return to stop. Ctrl-D quits.")

let printer = Task {
    for await event in engine.events {
        switch event {
        case let .phase(phase):
            err("[\(phase)]")
        case let .level(rms):
            let bars = Int(max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 35)) * 30)
            FileHandle.standardError.write(Data(("\r" + String(repeating: "▮", count: bars).padding(toLength: 30, withPad: " ", startingAt: 0)).utf8))
        case let .transcript(text):
            print(text)
            fflush(stdout)
        case let .timings(t):
            err("first buffer \(ms(t.pressToFirstBuffer)) · mic off \(ms(t.stopToMicOff)) · whisper \(ms(t.whisper)) for \(ms(t.audio)) of audio · stop to text \(ms(t.stopToText))")
        }
    }
}

while readLine() != nil {
    engine.press()
}
engine.shutdown()
await printer.value
await transcriber.unload()
