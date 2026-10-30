import Foundation
import Testing
@testable import HarkCore

func freshDefaults() -> UserDefaults {
    let name = "hark-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct SettingsTests {
    @Test func defaultsMatchTheHammerspoonVersion() {
        let settings = HarkSettings(freshDefaults())
        #expect(settings.soundPack == nil)
        #expect(settings.soundVolume == 0.6)
        #expect(settings.notchIsland == true)
        #expect(settings.onboardingVersion == 0)
    }

    @Test func choicesAreKept() {
        let defaults = freshDefaults()
        let settings = HarkSettings(defaults)
        settings.soundPack = "chirp"
        settings.soundVolume = 0.8
        settings.notchIsland = false
        settings.onboardingVersion = 1
        let again = HarkSettings(defaults)
        #expect(again.soundPack == "chirp")
        #expect(again.soundVolume == 0.8)
        #expect(again.notchIsland == false)
        #expect(again.onboardingVersion == 1)
    }
}

@Suite struct SoundLibraryTests {
    func library() throws -> SoundLibrary {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hark-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = """
        {"default": "pop", "transitions": ["start", "stop", "done", "error"], "packs": [
          {"id": "pop", "name": "Pop", "description": "Pops.", "files": {"start": "pop/start.wav", "stop": "pop/stop.wav", "done": "pop/done.wav", "error": "pop/error.wav"}},
          {"id": "mac-classic", "name": "macOS Classic", "description": "Mac.", "files": {"start": "/System/Library/Sounds/Tink.aiff"}}
        ]}
        """
        try Data(index.utf8).write(to: directory.appending(path: "packs.json"))
        return try SoundLibrary(directory: directory)
    }

    @Test func readsPacksInMenuOrder() throws {
        let library = try library()
        #expect(library.packs.map(\.id) == ["pop", "mac-classic"])
        #expect(library.pack("pop")?.files[.start]?.lastPathComponent == "start.wav")
        #expect(library.pack("mac-classic")?.files[.start]?.path == "/System/Library/Sounds/Tink.aiff")
    }

    @Test func theSettingsChooseThePack() throws {
        let library = try library()
        let settings = HarkSettings(freshDefaults())
        #expect(library.current(settings)?.id == "pop")
        settings.soundPack = "mac-classic"
        #expect(library.current(settings)?.id == "mac-classic")
        settings.soundPack = "gone"
        #expect(library.current(settings)?.id == "pop")
        settings.soundPack = HarkSettings.soundsOff
        #expect(library.current(settings) == nil)
    }
}
