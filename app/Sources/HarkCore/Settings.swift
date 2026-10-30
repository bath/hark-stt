import Foundation

/// The user's choices. The keys are the ones the Hammerspoon version kept
/// under `hark.` in hs.settings, so the move to the app can copy them.
public struct HarkSettings: @unchecked Sendable {
    public enum Key: String, CaseIterable, Sendable {
        case soundPack, soundVolume, notchIsland, onboardingVersion
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
