import Foundation

/// The rules of the update check. Sparkle, in the app, reads the appcast at
/// hark.works and installs an update in place. These rules say when to ask
/// and when to tell the user.
public enum Updates {
    /// Hark asks at most once in this time, and tells at most once in this time.
    public static let interval: TimeInterval = 24 * 3600
    /// The small line the Notch Island shows below "Pasted".
    public static let notice = "Update available. Open the menu bar icon."

    /// Compares dotted versions number by number: 1.10.0 is newer than 1.9.2.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let numbers = { (version: String) in
            version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let a = numbers(latest), b = numbers(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The automatic check is on, and the last check is a day old or more.
    public static func checkIsDue(_ settings: HarkSettings, now: Date = Date()) -> Bool {
        guard settings.updateChecks else { return false }
        guard let last = settings.updateCheckedAt else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// The version the last check found, when it is newer than this app.
    /// After the update, the stored version is not newer and this is nil.
    public static func available(_ settings: HarkSettings, current: String = harkVersion) -> String? {
        settings.updateAvailable.flatMap { isNewer($0, than: current) ? $0 : nil }
    }

    /// The island must tell the user now: an update is available, the
    /// automatic check is on, and the last notice is a day old or more.
    public static func noticeIsDue(_ settings: HarkSettings, current: String = harkVersion, now: Date = Date()) -> Bool {
        guard settings.updateChecks, available(settings, current: current) != nil else { return false }
        guard let last = settings.updateNoticeAt else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
