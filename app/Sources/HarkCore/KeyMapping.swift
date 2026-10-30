import Foundation

/// F5 without Karabiner: a `hidutil` key mapping from the dictation key to
/// F18, which Hark listens for. It needs no driver, no permission and no
/// password. macOS forgets the mapping at logout, so the app applies it at
/// launch (Hark starts at login), when a keyboard is connected, and removes
/// it when Hark quits, so F5 never goes dead.
///
/// The user's own UserKeyMapping entries are kept: Hark adds and removes only
/// its own entries, and does not add one for a key the user already maps.
public struct KeyRemap: Sendable, Hashable {
    public var source: UInt64
    public var destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }
}

public enum KeyMapping {
    /// HID usages: page in the top 32 bits, usage in the low 32 bits.
    public static let f18: UInt64 = 0x7_0000_006D
    /// The dictation (microphone) key: consumer page 0x0C, Voice Command 0xCF.
    public static let dictationKey: UInt64 = 0xC_0000_00CF
    /// F5 on the keyboard page, as the Karabiner rule mapped it.
    public static let f5: UInt64 = 0x7_0000_003E

    public static let hark = [
        KeyRemap(source: dictationKey, destination: f18),
        KeyRemap(source: f5, destination: f18),
    ]

    /// Reads `hidutil property --get UserKeyMapping`: "(null)", or a property
    /// list of dictionaries with decimal numbers.
    public static func parse(_ output: String) -> [KeyRemap] {
        var remaps: [KeyRemap] = []
        var source: UInt64?
        var destination: UInt64?
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ";"))) }
            if parts.count == 2, let value = UInt64(parts[1]) {
                if parts[0] == "HIDKeyboardModifierMappingSrc" { source = value }
                if parts[0] == "HIDKeyboardModifierMappingDst" { destination = value }
            }
            if line.contains("}"), let s = source, let d = destination {
                remaps.append(KeyRemap(source: s, destination: d))
                source = nil
                destination = nil
            }
        }
        return remaps
    }

    /// The user's entries plus Hark's, except where the user maps the same key.
    public static func adding(to current: [KeyRemap]) -> [KeyRemap] {
        let taken = Set(current.map(\.source))
        return current + hark.filter { !taken.contains($0.source) && !current.contains($0) }
    }

    /// The user's entries without Hark's.
    public static func removing(from current: [KeyRemap]) -> [KeyRemap] {
        current.filter { !hark.contains($0) }
    }

    /// True when the dictation key goes to F18.
    public static func isApplied(_ current: [KeyRemap]) -> Bool {
        current.contains(hark[0])
    }

    /// The argument for `hidutil property --set`.
    public static func json(_ remaps: [KeyRemap]) -> String {
        let entries = remaps.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }
}

/// Applies and removes Hark's mapping through `hidutil`. `run` runs hidutil
/// with the given arguments and returns its output; tests pass a fake.
public struct KeyMapper: Sendable {
    public typealias Run = @Sendable (_ arguments: [String]) throws -> String

    private let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    public func current() throws -> [KeyRemap] {
        KeyMapping.parse(try run(["property", "--get", "UserKeyMapping"]))
    }

    /// - Parameter force: set the mapping even when it looks applied. A newly
    ///   connected keyboard may not have it yet.
    public func apply(force: Bool = false) throws {
        let current = try current()
        let wanted = KeyMapping.adding(to: current)
        if force || wanted != current { _ = try run(["property", "--set", KeyMapping.json(wanted)]) }
    }

    public func remove() throws {
        let current = try current()
        let wanted = KeyMapping.removing(from: current)
        if wanted != current { _ = try run(["property", "--set", KeyMapping.json(wanted)]) }
    }

    public func isApplied() -> Bool {
        (try? KeyMapping.isApplied(current())) ?? false
    }
}
