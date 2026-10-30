import AppKit
import HarkCore

/// The 🎙 item in the menu bar.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let controller: AppController
    private var flashMessage: String?
    private var flashTimer: Timer?

    init(controller: AppController) {
        self.controller = controller
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        update()
    }

    func update() {
        var icon: String
        switch controller.phase {
        case .recording: icon = "🔴"
        case .transcribing: icon = "⏳"
        default: icon = controller.modelState == .loaded ? "🎙" : "⏳"
        }
        if let flashMessage { icon += " " + flashMessage }
        item.button?.title = icon
    }

    /// Shows a short message next to the icon, when the Notch Island is off.
    func flash(_ message: String) {
        flashMessage = message
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flashMessage = nil
                self?.update()
            }
        }
        update()
    }

    var statusText: String {
        switch controller.phase {
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        default: break
        }
        switch controller.modelState {
        case .missing: return "No Whisper model"
        case .loading: return "Loading the model"
        case .failed: return "The model did not load"
        case .loaded: return "Ready"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("Status: \(statusText)"))
        menu.addItem(action("Toggle Dictation", #selector(toggle)))
        menu.addItem(.separator())
        menu.addItem(action("Notch Island", #selector(toggleIsland), checked: controller.settings.notchIsland))
        menu.addItem(.separator())
        menu.addItem(disabled("Hark \(harkVersion)"))
        menu.addItem(.separator())
        menu.addItem(action("Quit Hark", #selector(quit), key: "q"))
    }

    // MARK: - Items

    func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func action(_ title: String, _ selector: Selector, key: String = "", checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.state = checked ? .on : .off
        return item
    }

    @objc private func toggle() { controller.press() }
    @objc private func toggleIsland() { controller.setNotchIsland(!controller.settings.notchIsland) }
    @objc private func quit() { NSApp.terminate(nil) }
}
