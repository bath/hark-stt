import Foundation

/// `Hark doctor --json`: the same contract as the `hark` CLI of the
/// Hammerspoon version. Every failed check has a `fix` an agent can act on and
/// says if a person must act (`needs_human`); `next_step` is the first failed
/// required check.
public enum Doctor {
    /// What the doctor looks at. The app gathers it; tests make it up.
    public struct Facts: Sendable {
        /// Hark.app on disk.
        public var appPath: String
        /// The running app's own report, when it is running.
        public var status: AppStatus?
        /// A model of the right size is on disk.
        public var modelPresent: Bool

        public init(appPath: String, status: AppStatus?, modelPresent: Bool) {
            self.appPath = appPath
            self.status = status
            self.modelPresent = modelPresent
        }
    }

    public struct Check: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var ok: Bool
        public var required: Bool
        public var needsHuman: Bool?
        public var fix: String?
        public var command: String?

        enum CodingKeys: String, CodingKey {
            case id, title, ok, required, fix, command
            case needsHuman = "needs_human"
        }
    }

    public struct Report: Codable, Sendable {
        public var hark: String
        public var ok: Bool
        public var readyToDictate: Bool
        public var hotkeys: [String]
        public var checks: [Check]
        public var nextStep: Check?
        public var status: AppStatus?

        enum CodingKeys: String, CodingKey {
            case hark, ok, hotkeys, checks, status
            case readyToDictate = "ready_to_dictate"
            case nextStep = "next_step"
        }

        public func json() -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return String(decoding: try! encoder.encode(self), as: UTF8.self)
        }

        public func text() -> String {
            var lines = checks.map { check -> String in
                var line = "  \(check.ok ? "✓" : check.required ? "✗" : "–") \(check.title)"
                if !check.ok, let fix = check.fix { line += "\n      \(fix)" }
                if !check.ok, let command = check.command { line += "\n      run: \(command)" }
                return line
            }
            lines.append("")
            lines.append(ok ? "Ready. Press F5 or ⌥Space in any text field." : "Not ready yet. Fix the ✗ items above.")
            return lines.joined(separator: "\n")
        }
    }

    public static func report(_ facts: Facts, version: String = harkVersion) -> Report {
        let checks = checks(facts)
        let ready = checks.allSatisfy { $0.ok || !$0.required }
        let failed = checks.filter { !$0.ok }
        return Report(
            hark: version,
            ok: ready,
            readyToDictate: ready,
            hotkeys: ["F5 (as F18)", "⌥Space"],
            checks: checks,
            nextStep: failed.first { $0.required } ?? failed.first,
            status: facts.status
        )
    }

    static func checks(_ facts: Facts) -> [Check] {
        let app = quoted(facts.appPath)
        let cli = quoted(facts.appPath + "/Contents/MacOS/Hark")
        let status = facts.status
        let running = status != nil
        let unknown = "Unknown until Hark runs. Fix app_running first."

        func check(_ id: String, _ title: String, _ ok: Bool, fix: String, human: Bool = false,
                   command: String? = nil, required: Bool = true) -> Check {
            ok ? Check(id: id, title: title, ok: true, required: required)
               : Check(id: id, title: title, ok: false, required: required, needsHuman: human, fix: fix, command: command)
        }

        var model = (fix: "Open Hark. It downloads the model (574 MB) by itself.", command: "open \(app)")
        if let progress = status?.modelProgress {
            model = ("Hark is downloading the model (\(Int(progress * 100)) %). Wait, then check again.",
                     "\(cli) doctor --json --wait 60")
        }

        var microphone = (fix: unknown, human: false, command: String?.none)
        if status?.microphone == "not_determined" {
            microphone = ("Ask the user to click Allow when macOS asks if Hark may use the microphone. "
                          + "The command opens Hark's setup window, which asks.", true, "open \(app) --args --setup")
        } else if running {
            microphone = ("Ask the user to turn on Hark in System Settings → Privacy & Security → Microphone.",
                          true, "\(cli) open-settings microphone")
        }

        var login = (fix: unknown, human: false, command: String?.none)
        if status?.loginItem == "requires_approval" {
            login = ("Ask the user to turn on Hark in System Settings → General → Login Items.",
                     true, "\(cli) open-settings login-items")
        } else if running {
            login = ("Run the command to start Hark at login.", false, "\(cli) login-item on")
        }

        return [
            check("app_in_applications", "Hark.app is in the Applications folder",
                  facts.appPath.hasPrefix("/Applications/"),
                  fix: "Optional. Move Hark.app to /Applications, so it starts at login and updates from there.",
                  command: "mv \(app) /Applications/ && open /Applications/Hark.app", required: false),
            check("app_running", "Hark is running", running, fix: "Open Hark.", command: "open \(app)"),
            check("model", "Whisper model (574 MB)", facts.modelPresent, fix: model.fix, command: model.command),
            check("microphone", "Hark has Microphone permission", status?.microphone == "authorized",
                  fix: microphone.fix, human: microphone.human, command: microphone.command),
            check("accessibility", "Hark has Accessibility permission (to paste)", status?.accessibility == true,
                  fix: running
                    ? "Ask the user to turn on Hark in System Settings → Privacy & Security → Accessibility. "
                      + "Hark sees the switch by itself; nothing needs a restart."
                    : unknown,
                  human: running, command: running ? "\(cli) open-settings accessibility" : nil),
            check("login_item", "Hark starts at login", status?.loginItem == "enabled",
                  fix: login.fix, human: login.human, command: login.command, required: false),
            check("f5_key", "F5 starts dictation (key mapping)", status?.keyMapping == true,
                  fix: running ? "Optional; ⌥Space always works. Run the command to map the dictation key (F5) to Hark." : unknown,
                  command: running ? "\(cli) f5-key on" : nil, required: false),
            check("ready", "Hark is ready to dictate", status?.model == "loaded",
                  fix: running
                    ? "The model is not loaded yet (\(status?.model ?? "unknown")). Fix the checks above, "
                      + "wait a few seconds, and check again."
                    : unknown,
                  command: running ? "\(cli) doctor --json --wait 15" : nil),
        ]
    }

    static func quoted(_ path: String) -> String {
        path.contains(where: { " '\"$&;()".contains($0) }) ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }
}
