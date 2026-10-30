import Foundation
import Testing
@testable import HarkCore

/// Every test works in a fake home folder and records commands instead of
/// running them, so no test reaches the real Hammerspoon or launchd.
final class Commands: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    var list: [String] { lock.withLock { all } }
    func add(_ line: String) { lock.withLock { all.append(line) } }
}

struct FakeHome {
    let url = FileManager.default.temporaryDirectory.appending(path: "hark-home-\(UUID().uuidString)")
    let commands = Commands()
    let config = """
    require("hs.ipc")

      require("hark")
    boxLayout = require("box-layout")
    -- my own notes about require("hark") stay
    """

    var migration: Migration {
        let commands = commands
        return Migration(home: url, uid: 501) { executable, arguments in
            commands.add(([executable] + arguments).joined(separator: " "))
        }
    }

    func file(_ path: String) -> URL { url.appending(path: path) }

    func make() throws -> FakeHome {
        let files = [
            ".hammerspoon/init.lua": config,
            ".hammerspoon/hark/init.lua": "local VERSION = \"1.2.1\"",
            ".hammerspoon/hark/sounds/packs.json": "{}",
            ".hammerspoon/box-layout.lua": "return {}",
            "Library/LaunchAgents/com.hark-stt.server.plist": "<plist/>",
            "Library/LaunchAgents/com.example.other.plist": "<plist/>",
            ".config/karabiner/assets/complex_modifications/hark.json": "{}",
            ".config/karabiner/assets/complex_modifications/mine.json": "{}",
            ".cache/whisper/ggml-large-v3-turbo-q5_0.bin": "model",
        ]
        for (path, text) in files {
            try FileManager.default.createDirectory(at: file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file(path), atomically: true, encoding: .utf8)
        }
        return self
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: file(path).path) }
    func read(_ path: String) throws -> String { try String(contentsOf: file(path), encoding: .utf8) }
}

@Suite struct MigrationTests {
    @Test func importsTheHammerspoonSettings() {
        let settings = HarkSettings(freshDefaults())
        Migration.importSettings(from: [
            "hark.soundPack": "chirp", "hark.soundVolume": 0.8, "hark.notchIsland": false,
            "hark.onboardingVersion": 1, "other.key": "x",
        ], into: settings)
        #expect(settings.soundPack == "chirp")
        #expect(settings.soundVolume == 0.8)
        #expect(settings.notchIsland == false)
        #expect(settings.onboardingVersion == 1)
    }

    @Test func importKeepsWhatTheAppAlreadyHas() {
        let settings = HarkSettings(freshDefaults())
        settings.soundPack = "pop"
        Migration.importSettings(from: ["hark.soundPack": "chirp"], into: settings)
        #expect(settings.soundPack == "pop")
    }

    @Test func pauseTurnsOffOnlyTheHarkLine() throws {
        let home = try FakeHome().make()
        #expect(home.migration.isLoaded)
        #expect(try home.migration.pause())
        let config = try home.read(".hammerspoon/init.lua")
        #expect(!home.migration.isLoaded)
        #expect(home.migration.isPaused)
        #expect(config.contains(#"require("hs.ipc")"#))
        #expect(config.contains(#"boxLayout = require("box-layout")"#))
        #expect(config.contains(#"-- my own notes about require("hark") stay"#))
        #expect(home.commands.list.count == 1) // the Hammerspoon reload
        // Nothing is removed yet.
        #expect(home.exists(".hammerspoon/hark/init.lua"))
        #expect(home.exists("Library/LaunchAgents/com.hark-stt.server.plist"))
    }

    @Test func resumeTurnsTheOldHarkBackOn() throws {
        let home = try FakeHome().make()
        try home.migration.pause()
        try home.migration.resume()
        #expect(home.migration.isLoaded)
        #expect(!home.migration.isPaused)
        #expect(try home.read(".hammerspoon/init.lua").contains(#"require("hark")"#))
    }

    @Test func finishRemovesOnlyHarksParts() throws {
        let home = try FakeHome().make()
        try home.migration.pause()
        try home.migration.finish()
        #expect(!home.exists(".hammerspoon/hark"))
        #expect(!home.exists("Library/LaunchAgents/com.hark-stt.server.plist"))
        #expect(!home.exists(".config/karabiner/assets/complex_modifications/hark.json"))
        #expect(home.commands.list.contains("/bin/launchctl bootout gui/501/com.hark-stt.server"))
        // Everything else stays.
        for kept in [".hammerspoon/box-layout.lua", "Library/LaunchAgents/com.example.other.plist",
                     ".config/karabiner/assets/complex_modifications/mine.json", ".cache/whisper/ggml-large-v3-turbo-q5_0.bin"] {
            #expect(home.exists(kept), "\(kept) must stay")
        }
        let config = try home.read(".hammerspoon/init.lua")
        #expect(!config.contains("paused"))
        #expect(config == """
        require("hs.ipc")

        boxLayout = require("box-layout")
        -- my own notes about require("hark") stay
        """)
        #expect(!home.migration.hasLegacyInstall)
    }

    @Test func aHomeWithNoOldHarkHasNothingToDo() throws {
        let home = FakeHome()
        #expect(!home.migration.hasLegacyInstall)
        #expect(try !home.migration.pause())
        #expect(home.commands.list.isEmpty)
    }
}
