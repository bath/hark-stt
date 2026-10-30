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
    private var keyboards: KeyboardWatcher?
    // The commands run on their own: the Hammerspoon restart sleeps, and must
    // not hold up launch or quit.
    private let migration = Migration { executable, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try? process.run()
    }
    /// The old Hammerspoon Hark is paused until the first dictation here pastes.
    private var migrating = false
    private var keyMappingApplied = false
    private var engine: DictationEngine!
    private(set) var microphone: CoreAudioMicrophone!
    /// The Hammerspoon Hark is still loaded: it keeps the keys until this app can dictate.
    private var waitingToTakeOver = false
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
        moveFromHammerspoon()
        microphone = CoreAudioMicrophone(deviceName: settings.microphone)
        engine = DictationEngine(microphone: microphone, transcriber: slot, paster: PasteboardPaster())
        menu = StatusMenu(controller: self)
        hotkeys = Hotkeys { [weak self] in self?.press() }
        if !waitingToTakeOver { registerHotkeys() }
        listen()
        setup.onRetry = { [weak self] in self?.downloadModel() }
        if let model = ModelLocation.existing() {
            loadModel(at: model)
        } else {
            downloadModel()
        }
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
        // Quit before the move finished: give the user their old Hark back.
        if migrating { try? migration.resume() }
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
            case .done:
                sounds.play(.done)
                if migrating { finishMove() }
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
        if ready && waitingToTakeOver { takeOver() }
    }

    // MARK: - Move from Hammerspoon

    /// Copies the old settings at once. The old Hark keeps dictating until
    /// this app can (model loaded, Microphone and Accessibility on); then
    /// `takeOver` pauses it.
    private func moveFromHammerspoon() {
        guard migration.hasLegacyInstall else { return }
        let old = UserDefaults(suiteName: "org.hammerspoon.Hammerspoon")?.dictionaryRepresentation() ?? [:]
        Migration.importSettings(from: old, into: settings)
        if migration.isLoaded {
            waitingToTakeOver = true
        } else if migration.isPaused {
            migrating = true // an earlier run paused it and did not finish
        }
    }

    private func takeOver() {
        waitingToTakeOver = false
        do {
            try migration.pause()
            migrating = migration.isPaused
        } catch {
            log.error("move: \(String(describing: error))")
        }
        registerHotkeys()
    }

    private func finishMove() {
        migrating = false
        do {
            try migration.finish()
        } catch {
            log.error("move: \(String(describing: error))")
            return
        }
        // After the paste has landed, so the alert does not take the focus mid-dictation.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = "Hark moved to the app"
                alert.informativeText = "Your sounds, settings and model came along, and the Hammerspoon version is removed. "
                    + Migration.leftovers
                NSApp.activate()
                alert.runModal()
            }
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
                setupProgressed()
            } catch {
                log.error("\(String(describing: error))")
                modelState = .failed
            }
            menu.update()
            writeStatus()
        }
    }
}
