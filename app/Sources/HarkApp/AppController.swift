import AppKit
import AVFoundation
import HarkCore
import HarkMac
import OSLog
import QuartzCore

let log = Logger(subsystem: "works.hark.Hark", category: "app")

/// Wires the engine to the keys, the menu and the sounds.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    enum ModelState: Equatable {
        case missing, loading, loaded, failed
    }

    let settings = HarkSettings()
    let sounds: SoundPlayer
    let island = NotchIsland()
    private(set) var phase = DictationPhase.idle
    private(set) var modelState = ModelState.missing
    private(set) var lastTimings: DictationTimings?
    private var transcriber: WhisperTranscriber?
    private var engine: DictationEngine!
    private var menu: StatusMenu!
    private var hotkeys: Hotkeys!
    private var events: Task<Void, Never>?
    private var hotkeysTaken: [String] = []
    private var statusTimer: Timer?
    private var previewTimers: [Timer] = []

    override init() {
        let directory = Bundle.main.resourceURL!.appending(path: "sounds")
        sounds = SoundPlayer(library: (try? SoundLibrary(directory: directory)) ?? .empty, settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let transcriber = ModelLocation.existing().map { WhisperTranscriber(modelPath: $0.path) }
        self.transcriber = transcriber
        engine = DictationEngine(
            microphone: CoreAudioMicrophone(),
            transcriber: transcriber ?? MissingModel(),
            paster: PasteboardPaster()
        )
        menu = StatusMenu(controller: self)
        hotkeys = Hotkeys { [weak self] in self?.press() }
        hotkeysTaken = hotkeys.register()
        if !hotkeysTaken.isEmpty { log.error("Hotkeys taken by another app: \(self.hotkeysTaken.joined(separator: ", "))") }
        listen()
        loadModel()
        writeStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeStatus() }
        }
        if CommandLine.arguments.contains("--preview") { preview() }
    }

    /// For `Hark doctor`, which runs in another process.
    func writeStatus() {
        let microphone = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not_determined"
        @unknown default: "unknown"
        }
        let status = AppStatus(
            version: harkVersion,
            pid: ProcessInfo.processInfo.processIdentifier,
            phase: phase.name,
            model: "\(modelState)",
            accessibility: AXIsProcessTrusted(),
            microphone: microphone,
            hotkeysTaken: hotkeysTaken,
            updated: Date()
        )
        do { try status.write() } catch { log.error("status: \(String(describing: error))") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        hotkeys.unregister()
        statusTimer?.invalidate()
        try? FileManager.default.removeItem(at: AppStatus.file)
        engine.shutdown()
        guard let transcriber else { return .terminateNow }
        // whisper.cpp must free its Metal context before the process exits.
        Task {
            await transcriber.unload()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Dictation

    func press() {
        engine.press()
    }

    /// A fake dictation with speech-like levels, so the island and the
    /// current sound pack can be tried without recording or pasting.
    func preview() {
        guard phase != .recording && phase != .transcribing else { return }
        previewTimers.forEach { $0.invalidate() }
        let signal: (DictationPhase, SoundTransition) -> Void = { [weak self] phase, sound in
            guard let self else { return }
            self.sounds.play(sound)
            if self.settings.notchIsland { self.island.show(phase) }
        }
        signal(.recording, .start)
        var nextChange = 0.0, rms: Float = 0
        let levels = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if now > nextChange {
                    let pause = Double.random(in: 0..<1) < 0.2
                    rms = pause ? 0.003 : Float.random(in: 0.01..<0.15)
                    nextChange = now + (pause ? 0.3 : Double.random(in: 0.08..<0.25))
                }
                self?.island.level(rms)
            }
        }
        let after: (Double, @escaping @MainActor () -> Void) -> Timer = { delay, work in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated(work) }
        }
        previewTimers = [
            levels,
            after(3) { levels.invalidate(); signal(.transcribing, .stop) },
            after(4.4) { signal(.done, .done) },
        ]
    }

    func setNotchIsland(_ on: Bool) {
        settings.notchIsland = on
        if !on { island.hide() }
    }

    private func listen() {
        let engine = engine!
        events = Task { [weak self] in
            for await event in engine.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: DictationEvent) {
        switch event {
        case let .phase(new):
            phase = new
            switch new {
            case .recording: sounds.play(.start)
            case .transcribing: sounds.play(.stop)
            case .done: sounds.play(.done)
            case .error: sounds.play(.error)
            case .idle: break
            }
            if settings.notchIsland {
                island.show(new)
            } else if case let .error(message) = new {
                menu.flash(message)
            }
            menu.update()
            writeStatus()
        case let .level(rms):
            if settings.notchIsland { island.level(rms) }
        case .transcript:
            break
        case let .timings(timings):
            lastTimings = timings
            log.info("first buffer \(timings.pressToFirstBuffer), whisper \(timings.whisper), stop to text \(timings.stopToText)")
        }
    }

    private func loadModel() {
        guard let transcriber else {
            modelState = .missing
            menu.update()
            return
        }
        modelState = .loading
        menu.update()
        Task {
            do {
                try await transcriber.load()
                modelState = .loaded
            } catch {
                log.error("\(String(describing: error))")
                modelState = .failed
            }
            menu.update()
            writeStatus()
        }
    }
}

/// The transcriber when there is no model on disk yet.
private struct MissingModel: Transcriber {
    var isLoaded: Bool { false }
    func transcribe(_ samples: Samples) async throws -> String { throw TranscriberError.modelNotLoaded }
}
