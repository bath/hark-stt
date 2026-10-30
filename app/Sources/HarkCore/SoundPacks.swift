import Foundation

/// The four moments that play a sound.
public enum SoundTransition: String, CaseIterable, Sendable {
    case start, stop, done, error
}

public struct SoundPack: Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let files: [SoundTransition: URL]
}

/// The packs that sounds/generate.py renders, read from its packs.json.
public struct SoundLibrary: Sendable {
    public let packs: [SoundPack]
    public let defaultPack: String

    public static let empty = SoundLibrary(packs: [], defaultPack: "pop")

    public init(packs: [SoundPack], defaultPack: String) {
        self.packs = packs
        self.defaultPack = defaultPack
    }

    /// Reads `packs.json` in `directory`. Relative file paths are in that
    /// directory; absolute ones are macOS system sounds.
    public init(directory: URL) throws {
        struct Index: Decodable {
            struct Pack: Decodable {
                let id: String
                let name: String
                let description: String
                let files: [String: String]
            }
            let `default`: String
            let packs: [Pack]
        }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: directory.appending(path: "packs.json")))
        defaultPack = index.default
        packs = index.packs.map { pack in
            var files: [SoundTransition: URL] = [:]
            for (name, path) in pack.files {
                guard let transition = SoundTransition(rawValue: name) else { continue }
                files[transition] = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appending(path: path)
            }
            return SoundPack(id: pack.id, name: pack.name, description: pack.description, files: files)
        }
    }

    public func pack(_ id: String) -> SoundPack? {
        packs.first { $0.id == id }
    }

    /// The pack the settings choose, or nil when sounds are off.
    public func current(_ settings: HarkSettings) -> SoundPack? {
        let id = settings.soundPack ?? defaultPack
        if id == HarkSettings.soundsOff { return nil }
        return pack(id) ?? pack(defaultPack)
    }
}
