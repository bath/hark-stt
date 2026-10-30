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
        case downloading(ModelDownloader.Progress?)
        case failed(String)
    }

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
            window.styleMask = [.titled, .closable]
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

    func close() {
        poll?.invalidate()
        poll = nil
        window?.close()
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
            MainActor.assumeIsolated { self?.model.refreshPermissions() }
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
            Text("Set up Hark").font(.title2.bold())
            Text("Three steps. Hark continues by itself as each one is done.")
                .foregroundStyle(.secondary)

            step(done: model.model == .present, title: "Whisper model") {
                switch model.model {
                case .present:
                    Text("On this Mac.")
                case let .downloading(progress):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress?.fraction ?? 0)
                        Text(downloadText(progress)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                case let .failed(message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The download stopped: \(message). It goes on from where it stopped.")
                        Button("Try Again", action: retryDownload)
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
                        Button("Open Accessibility Settings", action: openAccessibility)
                    }
                }
            }

            Divider()
            HStack {
                if model.isComplete {
                    Text("Ready. Click into any text field and press F5 or ⌥Space.").bold()
                } else {
                    Text("Everything stays on your Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isComplete ? "Done" : "Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func step(done: Bool, title: String, @ViewBuilder detail: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                detail().font(.callout)
            }
        }
    }

    private func downloadText(_ progress: ModelDownloader.Progress?) -> String {
        guard let progress else { return "Starting the download…" }
        let mb = { (bytes: Int64) in bytes / 1_000_000 }
        var text = "\(mb(progress.received)) of \(mb(progress.total)) MB"
        if let left = progress.secondsLeft {
            text += left < 60 ? ", less than a minute left" : ", about \(Int((left / 60).rounded(.up))) min left"
        }
        return text
    }
}
