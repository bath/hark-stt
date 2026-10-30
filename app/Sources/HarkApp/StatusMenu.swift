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
        let sound = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        sound.submenu = soundMenu()
        menu.addItem(sound)
        let preview = action("Preview Animation and Sounds", #selector(previewDictation))
        preview.isEnabled = controller.isReady
        menu.addItem(preview)
        menu.addItem(action("Show Welcome Screen", #selector(showWelcome)))
        menu.addItem(.separator())
        menu.addItem(disabled("Hark \(harkVersion)"))
        let updates = action(controller.checkingForUpdates ? "Checking for Updates…" : "Check for Updates…", #selector(checkForUpdates))
        updates.isEnabled = !controller.checkingForUpdates
        menu.addItem(updates)
        menu.addItem(.separator())
        menu.addItem(action("Quit Hark", #selector(quit), key: "q"))
    }

    private func soundMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = controller.settings
        let library = controller.sounds.library
        let current = library.current(settings)
        menu.addItem(action("Off", #selector(soundsOff), checked: current == nil))
        menu.addItem(.separator())
        if library.packs.isEmpty { menu.addItem(disabled("No sounds in the app")) }
        for pack in library.packs {
            let item = action(pack.name, #selector(choosePack(_:)), checked: pack.id == current?.id)
            item.representedObject = pack.id
            item.toolTip = pack.description
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for level in HarkSettings.volumeSteps {
            let item = action("Volume \(Int((level * 100).rounded()))%", #selector(chooseVolume(_:)),
                              checked: abs(settings.soundVolume - level) < 0.01)
            item.representedObject = level
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(action("Preview Current Sounds", #selector(previewSounds)))
        return menu
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
    @objc private func previewDictation() { controller.preview() }
    @objc private func showWelcome() { controller.showWelcome() }
    @objc private func checkForUpdates() { controller.checkForUpdates() }
    @objc private func soundsOff() { controller.settings.soundPack = HarkSettings.soundsOff }
    @objc private func previewSounds() { controller.sounds.preview() }

    @objc private func choosePack(_ item: NSMenuItem) {
        controller.settings.soundPack = item.representedObject as? String
        controller.sounds.preview()
    }

    @objc private func chooseVolume(_ item: NSMenuItem) {
        controller.settings.soundVolume = item.representedObject as? Double ?? 0.6
        controller.sounds.play(.done)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
