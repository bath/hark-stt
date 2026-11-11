import Foundation
import Testing
@testable import HarkCore

@Suite struct UpdatesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func versionsCompareNumberByNumber() {
        #expect(Updates.isNewer("1.10.0", than: "1.9.2"))
        #expect(Updates.isNewer("2.0.0", than: "1.2.1"))
        #expect(Updates.isNewer("2.0.1", than: "2.0"))
        #expect(!Updates.isNewer("2.0.0", than: "2.0.0"))
        #expect(!Updates.isNewer("2.0", than: "2.0.0"))
        #expect(!Updates.isNewer("1.2.1", than: "2.0.0"))
    }

    @Test func theCheckIsDueOnceADay() {
        let settings = HarkSettings(freshDefaults())
        #expect(Updates.checkIsDue(settings, now: now))
        settings.updateCheckedAt = now
        #expect(!Updates.checkIsDue(settings, now: now.addingTimeInterval(23 * 3600)))
        #expect(Updates.checkIsDue(settings, now: now.addingTimeInterval(24 * 3600)))
        settings.updateChecks = false
        #expect(!Updates.checkIsDue(settings, now: now.addingTimeInterval(48 * 3600)))
    }

    @Test func onlyANewerVersionIsAvailable() {
        let settings = HarkSettings(freshDefaults())
        #expect(Updates.available(settings, current: "2.0.4") == nil)
        settings.updateAvailable = "2.1.0"
        #expect(Updates.available(settings, current: "2.0.4") == "2.1.0")
        // After the update, the stored version is this version.
        #expect(Updates.available(settings, current: "2.1.0") == nil)
    }

    @Test func theNoticeIsDueOnceADayWhileAnUpdateIsAvailable() {
        let settings = HarkSettings(freshDefaults())
        #expect(!Updates.noticeIsDue(settings, current: "2.0.4", now: now))
        settings.updateAvailable = "2.1.0"
        #expect(Updates.noticeIsDue(settings, current: "2.0.4", now: now))
        settings.updateNoticeAt = now
        #expect(!Updates.noticeIsDue(settings, current: "2.0.4", now: now.addingTimeInterval(3600)))
        #expect(Updates.noticeIsDue(settings, current: "2.0.4", now: now.addingTimeInterval(25 * 3600)))
        #expect(!Updates.noticeIsDue(settings, current: "2.1.0", now: now.addingTimeInterval(25 * 3600)))
        settings.updateChecks = false
        #expect(!Updates.noticeIsDue(settings, current: "2.0.4", now: now.addingTimeInterval(25 * 3600)))
    }
}
