import AppKit
import AVFoundation
import HarkCore
import HarkMac
import OSLog

let log = Logger(subsystem: "works.hark.Hark", category: "app")

/// Wires the engine to the keys, the menu and the sounds.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    enum ModelState: Equatable {
        case missing, loading, loaded, failed
    }

    let settings = HarkSettings()
    let sounds: SoundPlayer
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
            case let .error(message):
                sounds.play(.error)
                menu.flash(message)
            case .idle: break
            }
            menu.update()
            writeStatus()
        case .level, .transcript:
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
