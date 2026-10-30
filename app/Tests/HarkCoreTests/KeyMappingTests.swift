import Foundation
import Testing
@testable import HarkCore

/// A fake `hidutil` that keeps a mapping in memory. No test touches the real one.
final class FakeHIDUtil: @unchecked Sendable {
    private let lock = NSLock()
    var mapping: [KeyRemap]
    private(set) var sets = 0

    init(_ mapping: [KeyRemap] = []) { self.mapping = mapping }

    var mapper: KeyMapper {
        KeyMapper { [self] arguments in
            try lock.withLock {
                switch arguments {
                case ["property", "--get", "UserKeyMapping"]:
                    return Self.render(mapping)
                case let set where set.count == 3 && set[1] == "--set":
                    let json = try JSONSerialization.jsonObject(with: Data(set[2].utf8)) as! [String: [[String: UInt64]]]
                    mapping = json["UserKeyMapping"]!.map {
                        KeyRemap(source: $0["HIDKeyboardModifierMappingSrc"]!, destination: $0["HIDKeyboardModifierMappingDst"]!)
                    }
                    sets += 1
                    return ""
                default:
                    throw CocoaError(.featureUnsupported)
                }
            }
        }
    }

    /// The format of the real `hidutil property --get UserKeyMapping`.
    static func render(_ mapping: [KeyRemap]) -> String {
        if mapping.isEmpty { return "(null)\n" }
        let entries = mapping.map {
            "        {\n        HIDKeyboardModifierMappingDst = \($0.destination);\n        HIDKeyboardModifierMappingSrc = \($0.source);\n    }"
        }
        return "(\n" + entries.joined(separator: ",\n") + "\n)\n"
    }
}

@Suite struct KeyMappingTests {
    let capsToEscape = KeyRemap(source: 0x7_0000_0039, destination: 0x7_0000_0029)

    @Test func readsHidutilOutput() {
        let output = """
        (
                {
                HIDKeyboardModifierMappingDst = 30064771183;
                HIDKeyboardModifierMappingSrc = 30064771182;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 51539607759;
            }
        )
        """
        #expect(KeyMapping.parse(output) == [
            KeyRemap(source: 30_064_771_182, destination: 30_064_771_183),
            KeyRemap(source: 0xC_0000_00CF, destination: 0x7_0000_006D),
        ])
        #expect(KeyMapping.parse("(null)\n").isEmpty)
        #expect(KeyMapping.parse("(\n)\n").isEmpty)
    }

    @Test func theDictationKeyGoesToF18() {
        #expect(KeyMapping.hark.contains(KeyRemap(source: 0xC_0000_00CF, destination: 0x7_0000_006D)))
    }

    @Test func applyKeepsTheUsersOwnEntries() throws {
        let hid = FakeHIDUtil([capsToEscape])
        #expect(try hid.mapper.apply() == KeyMapping.hark)
        #expect(hid.mapping == [capsToEscape] + KeyMapping.hark)
        #expect(hid.mapper.isApplied())
        // Applying again changes nothing, unless a new keyboard needs it.
        try hid.mapper.apply()
        #expect(hid.sets == 1)
        #expect(try hid.mapper.apply(force: true).isEmpty)
        #expect(hid.sets == 2)
        #expect(hid.mapping == [capsToEscape] + KeyMapping.hark)
    }

    @Test func removeTakesOnlyHarksEntries() throws {
        let hid = FakeHIDUtil([capsToEscape])
        let added = try hid.mapper.apply()
        try hid.mapper.remove(added)
        #expect(hid.mapping == [capsToEscape])
        #expect(!hid.mapper.isApplied())
    }

    @Test func anEntryTheUserAlreadyHadIsNotRemoved() throws {
        let hid = FakeHIDUtil(KeyMapping.hark)
        let added = try hid.mapper.apply()
        #expect(added.isEmpty)
        try hid.mapper.remove(added)
        #expect(hid.mapping == KeyMapping.hark)
    }

    @Test func aKeyTheUserAlreadyMapsIsLeftAlone() throws {
        let users = KeyRemap(source: KeyMapping.dictationKey, destination: 0x7_0000_0068) // dictation → F13
        let hid = FakeHIDUtil([users])
        let added = try hid.mapper.apply()
        #expect(added.isEmpty)
        #expect(hid.mapping == [users])
        try hid.mapper.remove(added)
        #expect(hid.mapping == [users])
    }

    @Test func theJSONIsWhatHidutilReads() throws {
        let json = KeyMapping.json([capsToEscape])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: [[String: UInt64]]]
        #expect(object["UserKeyMapping"]?.first?["HIDKeyboardModifierMappingSrc"] == capsToEscape.source)
        #expect(KeyMapping.json([]) == "{\"UserKeyMapping\":[]}")
    }
}
