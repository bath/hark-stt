import Foundation

/// The user's choices, in the app's UserDefaults. Do not rename a key: the
/// user's choice stored under the old name would be lost.
public struct HarkSettings: @unchecked Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case soundPack, soundVolume, notchIsland, onboardingVersion, f5Key
        /// The UserKeyMapping entries Hark added, as [source, destination] pairs.
        case f5Entries
        /// An input device name, or nil for the built-in mic.
        case microphone
        /// The user (or the first run) has set Start at Login once; do not change it again.
        case loginItemChosen
        /// A `SpeechModel` name.
        case speechModel
        /// Hark asks for a new version once a day.
        case updateChecks
        /// When Hark asked last, the version it found, and when the island told the user last.
        case updateCheckedAt, updateAvailable, updateNoticeAt
    }

    public static let soundsOff = "off"
    public static let volumeSteps: [Double] = [0.25, 0.4, 0.6, 0.8, 1.0]

    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A pack id, or `soundsOff`. Nil means the default pack.
    public var soundPack: String? {
        get { defaults.string(forKey: Key.soundPack.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.soundPack.rawValue) }
    }

    public var soundVolume: Double {
        get { defaults.object(forKey: Key.soundVolume.rawValue) as? Double ?? 0.6 }
        nonmutating set { defaults.set(newValue, forKey: Key.soundVolume.rawValue) }
    }

    public var notchIsland: Bool {
        get { defaults.object(forKey: Key.notchIsland.rawValue) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.notchIsland.rawValue) }
    }

    /// F5 starts dictation through Hark's key mapping.
    public var f5Key: Bool {
        get { defaults.object(forKey: Key.f5Key.rawValue) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.f5Key.rawValue) }
    }

    /// The key mapping entries Hark added and must remove again.
    public var f5Entries: [KeyRemap] {
        get {
            (defaults.array(forKey: Key.f5Entries.rawValue) as? [[NSNumber]] ?? []).compactMap {
                $0.count == 2 ? KeyRemap(source: $0[0].uint64Value, destination: $0[1].uint64Value) : nil
            }
        }
        nonmutating set {
            defaults.set(newValue.map { [NSNumber(value: $0.source), NSNumber(value: $0.destination)] },
                         forKey: Key.f5Entries.rawValue)
        }
    }

    /// The input device name the user chose, or nil for the built-in mic.
    public var microphone: String? {
        get { defaults.string(forKey: Key.microphone.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.microphone.rawValue) }
    }

    /// Whisper until the user chooses another model.
    public var speechModel: SpeechModel {
        get { defaults.string(forKey: Key.speechModel.rawValue).flatMap(SpeechModel.init) ?? .whisper }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.speechModel.rawValue) }
    }

    /// Hark asks for a new version once a day, after a dictation.
    public var updateChecks: Bool {
        get { defaults.object(forKey: Key.updateChecks.rawValue) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.updateChecks.rawValue) }
    }

    public var updateCheckedAt: Date? {
        get { defaults.object(forKey: Key.updateCheckedAt.rawValue) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.updateCheckedAt.rawValue) }
    }

    /// The version the last check found, or nil when it found none.
    public var updateAvailable: String? {
        get { defaults.string(forKey: Key.updateAvailable.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.updateAvailable.rawValue) }
    }

    public var updateNoticeAt: Date? {
        get { defaults.object(forKey: Key.updateNoticeAt.rawValue) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.updateNoticeAt.rawValue) }
    }

    /// The welcome card version the user has seen. 0 means none.
    public var onboardingVersion: Int {
        get { defaults.integer(forKey: Key.onboardingVersion.rawValue) }
        nonmutating set { defaults.set(newValue, forKey: Key.onboardingVersion.rawValue) }
    }

    public func has(_ key: Key) -> Bool {
        defaults.object(forKey: key.rawValue) != nil
    }

    public func set(_ value: Any, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }
}
