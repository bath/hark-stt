import Foundation
import Testing
@testable import HarkCore

@Suite struct UpdatesTests {
    @Test func versionsCompareNumberByNumber() {
        #expect(Updates.isNewer("1.10.0", than: "1.9.2"))
        #expect(Updates.isNewer("2.0.0", than: "1.2.1"))
        #expect(Updates.isNewer("2.0.1", than: "2.0"))
        #expect(!Updates.isNewer("2.0.0", than: "2.0.0"))
        #expect(!Updates.isNewer("2.0", than: "2.0.0"))
        #expect(!Updates.isNewer("1.2.1", than: "2.0.0"))
    }

    @Test func readsTheReleaseAndItsDiskImage() throws {
        let json = """
        {"tag_name": "v2.1.0", "html_url": "https://github.com/bath/hark-stt/releases/tag/v2.1.0",
         "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                    {"name": "Hark-2.1.0.dmg", "browser_download_url": "https://example.com/Hark-2.1.0.dmg"}]}
        """
        let release = try Updates.parse(Data(json.utf8))
        #expect(release.version == "2.1.0")
        #expect(release.diskImage?.lastPathComponent == "Hark-2.1.0.dmg")
        #expect(Updates.answer(release, current: "2.0.0") == .available(release))
        #expect(Updates.answer(release, current: "2.1.0") == .upToDate)
    }

    @Test func aReleaseWithNoDiskImageLinksToItsPage() throws {
        let json = #"{"tag_name": "1.2.1", "html_url": "https://github.com/bath/hark-stt/releases/tag/1.2.1", "assets": []}"#
        let release = try Updates.parse(Data(json.utf8))
        #expect(release.version == "1.2.1")
        #expect(release.diskImage == nil)
    }
}
