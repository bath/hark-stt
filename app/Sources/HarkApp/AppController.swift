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
    /// Changes when the user chooses another model. Work for the old model stops.
    private var modelRun = 0
    private var keyboards: KeyboardWatcher?
    private var keyMappingApplied = false
    private var engine: DictationEngine!
    private(set) var microphone: CoreAudioMicrophone!
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
        microphone = CoreAudioMicrophone(deviceName: settings.microphone)
        engine = DictationEngine(microphone: microphone, transcriber: slot, paster: PasteboardPaster())
        menu = StatusMenu(controller: self)
        hotkeys = Hotkeys { [weak self] in self?.press() }
        registerHotkeys()
        listen()
        setup.onRetry = { [weak self] in self?.startModel() }
        setup.onTick = { [weak self] in self?.setupTicked() }
        setup.onFinish = { [weak self] in self?.setupFinished() }
        startModel()
        firstRun()
        applyKeyMapping()
        keyboards = KeyboardWatcher { [weak self] in
            // Give the new keyboard a moment to settle, then map its key too.
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated { self?.applyKeyMapping(force: true) }
            }
        }
        writeStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // `Hark f5-key` in another process can change the mapping.
                self?.keyMappingApplied = KeyMapper.system.isApplied()
                self?.setupProgressed()
                self?.writeStatus()
            }
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
            speechModel: settings.speechModel.rawValue,
            model: "\(modelState)",
            modelProgress: downloadFraction,
            accessibility: AXIsProcessTrusted(),
            microphone: microphone,
            hotkeysTaken: hotkeysTaken,
            keyMapping: keyMappingApplied,
            loginItem: LoginItem.status,
            updated: Date()
        )
        do { try status.write() } catch { log.error("status: \(String(describing: error))") }
    }

    /// `open Hark.app` while it runs, or a double-click in Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSetup()
        return true
    }

    func chooseMicrophone(_ name: String?) {
        settings.microphone = name
        let microphone = microphone!
        Task { await microphone.choose(name) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        hotkeys.unregister()
        statusTimer?.invalidate()
        // F18 does nothing without Hark, so give F5 back to macOS.
        removeKeyMapping()
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

    /// The dictation key. The first press ever shows the welcome card instead,
    /// or the setup window while the setup is not complete: the welcome card
    /// follows the setup, so that "Start dictating" can paste.
    func press() {
        if welcome.isShown {
            welcome.close(startRecording: true)
        } else if phase != .recording && welcome.isPending {
            setupModel.refreshPermissions()
            if setupModel.isComplete { welcome.show() } else { showSetup() }
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

    // MARK: - F5

    func setF5Key(_ on: Bool) {
        settings.f5Key = on
        if on {
            applyKeyMapping()
        } else {
            removeKeyMapping()
            keyMappingApplied = false
            writeStatus()
        }
    }

    private func applyKeyMapping(force: Bool = false) {
        guard settings.f5Key else { return }
        do {
            // Keep what an earlier run added too: it is still Hark's to remove.
            settings.f5Entries = Array(Set(settings.f5Entries + (try KeyMapper.system.apply(force: force))))
        } catch {
            log.error("hidutil: \(String(describing: error))")
        }
        keyMappingApplied = KeyMapper.system.isApplied()
        writeStatus()
    }

    private func removeKeyMapping() {
        do {
            try KeyMapper.system.remove(settings.f5Entries)
            settings.f5Entries = []
        } catch {
            log.error("hidutil: \(String(describing: error))")
        }
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

    private func registerHotkeys() {
        hotkeysTaken = hotkeys.register()
        if !hotkeysTaken.isEmpty { log.error("Hotkeys taken by another app: \(self.hotkeysTaken.joined(separator: ", "))") }
    }

    /// Called every few seconds and when the model loads: turns on what waits
    /// for a complete setup.
    private func setupProgressed() {
        setupModel.refreshPermissions()
        let ready = setupModel.isComplete && modelState == .loaded
        if ready && !settings.has(.loginItemChosen) { setLoginItem(true) }
    }

    // MARK: - First run

    /// Shows the setup window while something is missing. The first time
    /// everything is in place, Hark also starts at login.
    private func firstRun() {
        setupModel.refreshPermissions()
        if !setupModel.isComplete || CommandLine.arguments.contains("--setup") {
            setup.show()
        }
    }

    func showSetup() {
        setupModel.refreshPermissions()
        setup.show()
    }

    /// Each second while the setup window is open.
    private func setupTicked() {
        AccessibilityProbe.check(restart: AccessibilityProbe.restart)
        if setupModel.isComplete && welcome.isPending { setup.finishSoon() }
    }

    /// The setup window closed on a complete setup. Give the focus back to the
    /// app the user came from, so the welcome card's "Start dictating" pastes there.
    private func setupFinished() {
        guard welcome.isPending else { return }
        NSApp.deactivate()
        welcome.show()
    }

    var startsAtLogin: Bool { LoginItem.status == "enabled" }

    func setLoginItem(_ on: Bool) {
        _ = CLI.loginItem(on ? "on" : "off")
        settings.set(true, for: .loginItemChosen)
        writeStatus()
    }

    // MARK: - Model

    /// 0…1 while the model downloads.
    var downloadFraction: Double? {
        if case let .downloading(progress) = setupModel.model { return progress?.fraction ?? 0 }
        return nil
    }

    /// Changes the speech model now: frees the old one, then downloads (the
    /// first time) and loads the new one.
    func chooseSpeechModel(_ model: SpeechModel) {
        guard model != settings.speechModel, phase != .recording, phase != .transcribing else { return }
        settings.speechModel = model
        modelRun += 1
        let run = modelRun
        download?.cancel()
        download = nil
        let old = slot.empty()
        modelState = .missing
        setupModel.speechModel = model
        setupModel.model = .present
        menu.update()
        writeStatus()
        Task {
            await old?.unload()
            if run == modelRun { startModel() }
        }
    }

    /// Loads the chosen model, and downloads it first when it is not on disk.
    private func startModel() {
        setupModel.speechModel = settings.speechModel
        switch settings.speechModel {
        case .whisper:
            if let model = ModelLocation.existing() { loadModel(at: model) } else { downloadModel() }
        case .parakeet:
            loadParakeet()
        }
    }

    /// FluidAudio downloads Parakeet itself, so the download and the load are one step.
    private func loadParakeet() {
        guard download == nil else { return }
        let run = modelRun
        let transcriber = ParakeetTranscriber()
        let setupModel = setupModel
        let onDisk = ParakeetTranscriber.isDownloaded
        modelState = onDisk ? .loading : .downloading
        setupModel.model = onDisk ? .present : .downloading(nil)
        menu.update()
        download = Task {
            do {
                try await transcriber.load { fraction in
                    Task { @MainActor in
                        if case .downloading = setupModel.model { setupModel.model = .downloading(.init(fraction: fraction)) }
                    }
                }
                guard run == modelRun else {
                    await transcriber.unload()
                    return
                }
                slot.fill(transcriber)
                setupModel.model = .present
                modelState = .loaded
                setupProgressed()
            } catch {
                guard run == modelRun else { return }
                log.error("parakeet: \(String(describing: error))")
                modelState = .failed
                setupModel.model = .failed(error.localizedDescription)
                setup.show()
            }
            download = nil
            menu.update()
            writeStatus()
        }
    }

    private func downloadModel() {
        guard download == nil else { return }
        let run = modelRun
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
                        if case .downloading = setupModel.model { setupModel.model = .downloading(.init(progress)) }
                    }
                }
                guard run == modelRun else { return }
                setupModel.model = .present
                loadModel(at: destination)
            } catch {
                guard run == modelRun else { return }
                log.error("download: \(String(describing: error))")
                modelState = .failed
                setupModel.model = .failed((error as? DownloadError)?.description ?? error.localizedDescription)
                setup.show()
            }
            download = nil
            menu.update()
            writeStatus()
        }
    }

    private func loadModel(at url: URL) {
        let run = modelRun
        let transcriber = WhisperTranscriber(modelPath: url.path)
        slot.fill(transcriber)
        modelState = .loading
        menu.update()
        Task {
            do {
                try await transcriber.load()
                // The user chose another model meanwhile, and that choice freed this one.
                guard run == modelRun else { return }
                modelState = .loaded
                setupProgressed()
            } catch {
                guard run == modelRun else { return }
                log.error("\(String(describing: error))")
                modelState = .failed
            }
            menu.update()
            writeStatus()
        }
    }
}
