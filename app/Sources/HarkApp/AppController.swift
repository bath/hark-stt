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
        case missing, downloading, loading, loaded, failed
    }

    let settings = HarkSettings()
    let sounds: SoundPlayer
    let island = NotchIsland()
    private(set) var phase = DictationPhase.idle
    private(set) var modelState = ModelState.missing
    private(set) var lastTimings: DictationTimings?
    private let slot = ModelSlot()
    private let setupModel = SetupModel()
    private lazy var setup = SetupWindow(model: setupModel)
    private var download: Task<Void, Never>?
    private var engine: DictationEngine!
    private var menu: StatusMenu!
    private var hotkeys: Hotkeys!
    private var events: Task<Void, Never>?
    private var hotkeysTaken: [String] = []
    private var statusTimer: Timer?
    private var previewTimers: [Timer] = []
    private(set) var checkingForUpdates = false
    private lazy var welcome = WelcomeCard(settings: settings) { [weak self] start in
        if start { self?.engine.press() }
    }

    override init() {
        let directory = Bundle.main.resourceURL!.appending(path: "sounds")
        sounds = SoundPlayer(library: (try? SoundLibrary(directory: directory)) ?? .empty, settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = DictationEngine(microphone: CoreAudioMicrophone(), transcriber: slot, paster: PasteboardPaster())
        menu = StatusMenu(controller: self)
        hotkeys = Hotkeys { [weak self] in self?.press() }
        hotkeysTaken = hotkeys.register()
        if !hotkeysTaken.isEmpty { log.error("Hotkeys taken by another app: \(self.hotkeysTaken.joined(separator: ", "))") }
        listen()
        setup.onRetry = { [weak self] in self?.downloadModel() }
        if let model = ModelLocation.existing() {
            loadModel(at: model)
        } else {
            downloadModel()
        }
        firstRun()
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
        var progress: Double?
        if case let .downloading(step) = setupModel.model { progress = step?.fraction ?? 0 }
        let status = AppStatus(
            version: harkVersion,
            pid: ProcessInfo.processInfo.processIdentifier,
            phase: phase.name,
            model: "\(modelState)",
            modelProgress: progress,
            accessibility: AXIsProcessTrusted(),
            microphone: microphone,
            hotkeysTaken: hotkeysTaken,
            loginItem: LoginItem.status,
            updated: Date()
        )
        do { try status.write() } catch { log.error("status: \(String(describing: error))") }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        hotkeys.unregister()
        statusTimer?.invalidate()
        try? FileManager.default.removeItem(at: AppStatus.file)
        engine.shutdown()
        download?.cancel()
        guard let transcriber = slot.current else { return .terminateNow }
        // whisper.cpp must free its Metal context before the process exits.
        Task {
            await transcriber.unload()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Dictation

    /// The dictation key. The first press ever shows the welcome card instead.
    func press() {
        if welcome.isShown {
            welcome.close(startRecording: true)
        } else if phase != .recording && welcome.isPending {
            welcome.show()
        } else {
            engine.press()
        }
    }

    func showWelcome() {
        welcome.show()
    }

    var isReady: Bool {
        modelState == .loaded && phase != .recording && phase != .transcribing
    }

    func checkForUpdates() {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        Task {
            defer { checkingForUpdates = false }
            let alert = NSAlert()
            do {
                switch try await Updates.check(current: harkVersion) {
                case .upToDate:
                    alert.messageText = "Hark is up to date"
                    alert.informativeText = "Version \(harkVersion) is the latest."
                case let .available(release):
                    alert.messageText = "Hark \(release.version) is available"
                    alert.informativeText = "You have \(harkVersion). Download the new version, quit Hark, and move the new Hark to Applications. Your settings and the model stay."
                    alert.addButton(withTitle: "Download")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(release.diskImage ?? release.page)
                    }
                    return
                }
            } catch {
                alert.messageText = "Could not check for updates"
                alert.informativeText = "GitHub did not answer. Try again later."
            }
            NSApp.activate()
            alert.runModal()
        }
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

    // MARK: - First run

    /// Shows the setup window while something is missing. The first time
    /// everything is in place, Hark also starts at login.
    private func firstRun() {
        setupModel.refreshPermissions()
        if !setupModel.isComplete || CommandLine.arguments.contains("--setup") {
            setup.show()
        }
        if !settings.has(.loginItemChosen) && setupModel.isComplete {
            setLoginItem(true)
        }
    }

    func showSetup() {
        setupModel.refreshPermissions()
        setup.show()
    }

    var startsAtLogin: Bool { LoginItem.status == "enabled" }

    func setLoginItem(_ on: Bool) {
        _ = CLI.loginItem(on ? "on" : "off")
        settings.set(true, for: .loginItemChosen)
        writeStatus()
    }

    private func downloadModel() {
        guard download == nil else { return }
        let destination = ModelLocation.appSupport
        let model = ModelDownloader.whisperModel
        let downloader = ModelDownloader(url: model.url, size: model.size, sha256: model.sha256, destination: destination)
        modelState = .downloading
        setupModel.model = .downloading(nil)
        menu.update()
        download = Task {
            do {
                let setupModel = setupModel
                try await downloader.download { progress in
                    Task { @MainActor in
                        if case .downloading = setupModel.model { setupModel.model = .downloading(progress) }
                    }
                }
                setupModel.model = .present
                loadModel(at: destination)
            } catch {
                log.error("download: \(String(describing: error))")
                modelState = .failed
                setupModel.model = .failed((error as? DownloadError)?.description ?? error.localizedDescription)
                setup.show()
            }
            download = nil
            menu.update()
            writeStatus()
            if setupModel.isComplete && !settings.has(.loginItemChosen) { setLoginItem(true) }
        }
    }

    private func loadModel(at url: URL) {
        let transcriber = WhisperTranscriber(modelPath: url.path)
        slot.fill(transcriber)
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
