import Foundation

/// The move from the Hammerspoon version to Hark.app. The user keeps their
/// settings and the model, and is never without dictation:
///
/// 1. `pause()` at launch: copy the settings, then turn the old Hark off by
///    commenting out its `require("hark")` line and reloading Hammerspoon, so
///    the two do not both answer ⌥Space.
/// 2. `finish()` after the first dictation that pastes: remove the old Hark's
///    own parts. Nothing else in the Hammerspoon config changes, and
///    Hammerspoon, Karabiner-Elements and whisper.cpp stay installed.
/// 3. `resume()` if the app quits before that: turn the old Hark back on.
public struct Migration: Sendable {
    public typealias Run = @Sendable (_ executable: String, _ arguments: [String]) -> Void

    static let line = #"require("hark")"#
    static let pausedLine = #"-- require("hark") -- paused: Hark.app does the dictation now"#
    public static let serverLabel = "com.hark-stt.server"
    /// The Hammerspoon version kept its settings in hs.settings with this prefix.
    public static let settingsPrefix = "hark."

    public let home: URL
    private let uid: uid_t
    private let run: Run

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, uid: uid_t = getuid(), run: @escaping Run) {
        self.home = home
        self.uid = uid
        self.run = run
    }

    var hammerspoonConfig: URL { home.appending(path: ".hammerspoon/init.lua") }
    var moduleFolder: URL { home.appending(path: ".hammerspoon/hark") }
    var serverAgent: URL { home.appending(path: "Library/LaunchAgents/\(Self.serverLabel).plist") }
    var karabinerRule: URL { home.appending(path: ".config/karabiner/assets/complex_modifications/hark.json") }

    /// The old Hark is installed (loaded or paused).
    public var hasLegacyInstall: Bool {
        FileManager.default.fileExists(atPath: moduleFolder.appending(path: "init.lua").path)
    }

    private func configLines() -> [String]? {
        (try? String(contentsOf: hammerspoonConfig, encoding: .utf8)).map { $0.components(separatedBy: "\n") }
    }

    private func writeConfig(_ lines: [String]) throws {
        try lines.joined(separator: "\n").write(to: hammerspoonConfig, atomically: true, encoding: .utf8)
    }

    /// Hammerspoon loads the old Hark.
    public var isLoaded: Bool {
        configLines()?.contains { $0.trimmingCharacters(in: .whitespaces) == Self.line } ?? false
    }

    public var isPaused: Bool {
        configLines()?.contains(Self.pausedLine) ?? false
    }

    /// Copies the old settings the app does not have yet.
    public static func importSettings(from hammerspoon: [String: Any], into settings: HarkSettings) {
        for key in HarkSettings.Key.allCases where !settings.has(key) {
            if let value = hammerspoon[settingsPrefix + key.rawValue] { settings.set(value, for: key) }
        }
    }

    /// Turns the old Hark off for now. Returns true when it was on.
    @discardableResult
    public func pause() throws -> Bool {
        guard var lines = configLines(), isLoaded else { return false }
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) == Self.line ? Self.pausedLine : $0 }
        try writeConfig(lines)
        reloadHammerspoon()
        return true
    }

    /// Turns the old Hark back on.
    public func resume() throws {
        guard var lines = configLines(), isPaused else { return }
        lines = lines.map { $0 == Self.pausedLine ? Self.line : $0 }
        try writeConfig(lines)
        reloadHammerspoon()
    }

    /// Removes the old Hark's parts, and only those.
    public func finish() throws {
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.serverLabel)"])
        let fileManager = FileManager.default
        for url in [serverAgent, karabinerRule, moduleFolder] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if var lines = configLines() {
            let before = lines.count
            lines.removeAll { $0 == Self.pausedLine || $0.trimmingCharacters(in: .whitespaces) == Self.line }
            if lines.count != before { try writeConfig(lines) }
        }
    }

    /// What the user can remove by hand, if nothing else uses it.
    public static let leftovers = """
    Hark now runs as an app. Hammerspoon, Karabiner-Elements and whisper.cpp are still installed. \
    If nothing else on your Mac uses them, you can remove them:

    brew uninstall --cask hammerspoon karabiner-elements
    brew uninstall whisper.cpp hark
    """

    private func reloadHammerspoon() {
        // A reload through Hammerspoon's own URL would need its IPC; a restart works always.
        run("/bin/sh", ["-c", "if pgrep -x Hammerspoon >/dev/null; then killall Hammerspoon; sleep 1; open -g -a Hammerspoon; fi"])
    }
}
