import AppKit
import HarkCore
import HarkMac
import ServiceManagement

/// Commands for agents and the terminal, run as
/// `/Applications/Hark.app/Contents/MacOS/Hark <command>`.
enum CLI {
    static let usage = """
    Hark \(harkVersion): private, on-device dictation.

      Hark doctor [--json] [--wait SECONDS]   check the setup; exit 0 when ready to dictate
      Hark open-settings PANE                 open the System Settings pane a fix needs
                                              (accessibility, microphone, login-items, dictation)
      Hark login-item on|off                  start Hark at login, or not
      Hark version

    `Hark doctor --json` is made for AI agents: every failed check says whether a
    person must act, what to tell them, and the command that opens the right place.
    """

    static let panes = [
        "accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "microphone": "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "login-items": "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        "dictation": "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
    ]

    /// Runs a command and returns its exit code, or nil when the arguments
    /// are not a command and the app should start.
    static func run(_ arguments: [String]) -> Int32? {
        guard let command = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "doctor": return doctor(rest)
        case "open-settings": return openSettings(rest.first ?? "")
        case "login-item": return loginItem(rest.first ?? "")
        case "version":
            print(harkVersion)
            return 0
        case "help", "-h", "--help":
            print(usage)
            return 0
        default:
            return nil
        }
    }

    static func facts() -> Doctor.Facts {
        let model = ModelLocation.existing().flatMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) == ModelDownloader.whisperModel.size
                ? url : nil
        }
        return Doctor.Facts(appPath: Bundle.main.bundlePath, status: AppStatus.live(), modelPresent: model != nil)
    }

    static func doctor(_ arguments: [String]) -> Int32 {
        var wait = 0.0
        if let index = arguments.firstIndex(of: "--wait"), index + 1 < arguments.count {
            wait = Double(arguments[index + 1]) ?? 0
        }
        let deadline = Date().addingTimeInterval(wait)
        var report = Doctor.report(facts())
        while !report.ok && Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            report = Doctor.report(facts())
        }
        print(arguments.contains("--json") ? report.json() : report.text())
        return report.ok ? 0 : 1
    }

    static func openSettings(_ pane: String) -> Int32 {
        guard let url = panes[pane].flatMap(URL.init(string:)) else {
            FileHandle.standardError.write(Data("usage: Hark open-settings \(panes.keys.sorted().joined(separator: "|"))\n".utf8))
            return 2
        }
        if pane == "accessibility" {
            // Adds Hark to the list, so the user only has to turn the switch on.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
        }
        return NSWorkspace.shared.open(url) ? 0 : 1
    }

    static func loginItem(_ choice: String) -> Int32 {
        do {
            switch choice {
            case "on": try SMAppService.mainApp.register()
            case "off": try SMAppService.mainApp.unregister()
            default:
                FileHandle.standardError.write(Data("usage: Hark login-item on|off\n".utf8))
                return 2
            }
        } catch {
            FileHandle.standardError.write(Data("Hark: \(error.localizedDescription)\n".utf8))
            return 1
        }
        print(LoginItem.status)
        return 0
    }
}

enum LoginItem {
    /// enabled, requires_approval, not_registered or not_found.
    static var status: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requires_approval"
        case .notRegistered: "not_registered"
        case .notFound: "not_found"
        @unknown default: "unknown"
        }
    }
}
