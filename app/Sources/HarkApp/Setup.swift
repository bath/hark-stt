import AppKit
import AVFoundation
import HarkCore
import HarkMac
import Observation
import SwiftUI

/// The first run: the model download, the microphone and Accessibility. It
/// continues by itself as each step is done.
@MainActor @Observable
final class SetupModel {
    enum ModelStep: Equatable {
        case present
        case downloading(DownloadStep?)
        case failed(String)
    }

    /// How far a download is. Only Whisper's download knows its bytes.
    struct DownloadStep: Equatable {
        var fraction: Double
        var bytes: ModelDownloader.Progress?

        init(fraction: Double) {
            self.fraction = fraction
        }

        init(_ progress: ModelDownloader.Progress) {
            fraction = progress.fraction
            bytes = progress
        }
    }

    var speechModel = SpeechModel.whisper
    var model = ModelStep.present
    var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    var accessibility = AXIsProcessTrusted()

    var isComplete: Bool {
        model == .present && microphone == .authorized && accessibility
    }

    func refreshPermissions() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
    }
}

/// The window around SetupView.
@MainActor
final class SetupWindow {
    let model: SetupModel
    private var window: NSWindow?
    private var poll: Timer?
    private var askedForAccessibility = false

    init(model: SetupModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupView(
                model: model,
                openAccessibility: { [weak self] in self?.openAccessibility() },
                retryDownload: { [weak self] in self?.onRetry?() },
                close: { [weak self] in self?.close() }
            )))
            window.title = "Set Up Hark"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Theme.surfaceNS
            window.isReleasedWhenClosed = false
            window.center()
            // The title bar's close button does not call close(), so stop the poll here too.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.poll?.invalidate()
                    self?.poll = nil
                }
            }
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        askForMicrophone()
        startPolling()
    }

    var onRetry: (() -> Void)?
    /// Each second while the window is open.
    var onTick: (() -> Void)?
    /// When the setup is complete and the window closes: the welcome card comes next.
    var onFinish: (() -> Void)?
    private var finishing = false

    func close() {
        poll?.invalidate()
        poll = nil
        window?.close()
        if model.isComplete { onFinish?() }
    }

    /// Closes a complete setup after a moment to see the last check.
    func finishSoon() {
        guard model.isComplete, !finishing, window?.isVisible == true else { return }
        finishing = true
        Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finishing = false
                if self.model.isComplete && self.window?.isVisible == true { self.close() }
            }
        }
    }

    /// The standard system dialog: one click.
    private func askForMicrophone() {
        guard model.microphone == .notDetermined else {
            askForAccessibilityOnce()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshPermissions()
                self?.askForAccessibilityOnce()
            }
        }
    }

    /// macOS's own prompt, which adds Hark to the Accessibility list and
    /// offers to open System Settings.
    private func askForAccessibilityOnce() {
        guard !model.accessibility, !askedForAccessibility, model.microphone != .notDetermined else { return }
        askedForAccessibility = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func openAccessibility() {
        _ = CLI.openSettings("accessibility")
    }

    /// Accessibility has no callback, so check every second until it is on.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.refreshPermissions()
                self?.onTick?()
            }
        }
    }
}

struct SetupView: View {
    let model: SetupModel
    let openAccessibility: () -> Void
    let retryDownload: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up Hark").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
            Text("Three steps. Hark continues by itself as each one is done.")
                .foregroundStyle(Theme.mute)

            step(done: model.model == .present, title: "\(model.speechModel.title) model") {
                switch model.model {
                case .present:
                    Text("On this Mac.")
                case let .downloading(progress):
                    VStack(alignment: .leading, spacing: 4) {
                        // A plain bar in the theme's colors.
                        Capsule().fill(Theme.rule).frame(height: 6).overlay(alignment: .leading) {
                            GeometryReader { bar in
                                Capsule().fill(Theme.accent).frame(width: bar.size.width * (progress?.fraction ?? 0))
                            }
                        }
                        Text(downloadText(progress)).font(.callout).monospacedDigit()
                    }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The download stopped: \(message). It goes on from where it stopped.")
                        Button("Try Again", action: retryDownload).buttonStyle(PillButtonStyle())
                    }
                }
            }

            step(done: model.microphone == .authorized, title: "Microphone") {
                switch model.microphone {
                case .authorized: Text("Hark can hear you while you dictate, and only then.")
                case .notDetermined: Text("Click Allow in the dialog.")
                default: Text("Turn on Hark in System Settings → Privacy & Security → Microphone.")
                }
            }

            step(done: model.accessibility, title: "Accessibility") {
                if model.accessibility {
                    Text("Hark can paste the text where your cursor is.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hark pastes the text where your cursor is. macOS lets an app do that only with Accessibility. Turn on Hark in the list.")
                        Button("Open Accessibility Settings", action: openAccessibility).buttonStyle(PillButtonStyle())
                    }
                }
            }

            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                if model.isComplete {
                    Text("Ready. Press F5 or ⌥Space in any text field.")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                } else {
                    Text("Everything stays on your Mac.").font(.system(size: 13)).foregroundStyle(Theme.mute)
                }
                Spacer()
                Button(model.isComplete ? "Done" : "Close", action: close)
                    .buttonStyle(PillButtonStyle(primary: model.isComplete))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .padding(.top, 34)
        .frame(width: 460)
        .background(Theme.surface)
    }

    private func step(done: Bool, title: String, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.ok : Theme.rule)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                detail().font(.system(size: 13)).foregroundStyle(Theme.mute)
            }
        }
    }

    private func downloadText(_ step: SetupModel.DownloadStep?) -> String {
        guard let step else { return "Starting the download…" }
        guard let progress = step.bytes else {
            return "\(Int(step.fraction * 100)) % of \(model.speechModel.megabytes) MB"
        }
        let mb = { (bytes: Int64) in bytes / 1_000_000 }
        var text = "\(mb(progress.received)) of \(mb(progress.total)) MB"
        if let left = progress.secondsLeft {
            text += left < 60 ? ", less than a minute left" : ", about \(Int((left / 60).rounded(.up))) min left"
        }
        return text
    }
}

extension SetupView {
    /// Draws the setup window (complete, and with steps open) and the menu
    /// bar icons into PNG files, with the island states of `Hark --render-island DIR`.
    @MainActor
    static func render(to directory: URL) throws {
        let complete = SetupModel()
        complete.model = .present
        complete.microphone = .authorized
        complete.accessibility = true
        let open = SetupModel()
        open.model = .downloading(.init(fraction: 0.42))
        open.microphone = .authorized
        open.accessibility = false
        for (name, model) in [("setup-complete", complete), ("setup-open", open)] {
            let renderer = ImageRenderer(content: SetupView(model: model, openAccessibility: {}, retryDownload: {}, close: {}))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: directory.appending(path: "\(name).png"))
        }
        for (name, state) in [("menubar-ready", MenuBarIcon.State.ready), ("menubar-recording", .recording), ("menubar-busy", .busy)] {
            let icon = MenuBarIcon.image(state)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(white: 0.85, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 144, height: 128).fill()
            icon.draw(in: NSRect(x: 0, y: 0, width: 144, height: 128))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        }
    }
}
