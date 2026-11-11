import AppKit
import HarkCore
import Sparkle

/// Sparkle reads the appcast at hark.works and installs an update in place:
/// it downloads the disk image, checks its signature, replaces Hark.app and
/// starts it again. Sparkle's own schedule is off (SUEnableAutomaticChecks in
/// Info.plist). Hark asks once a day after a dictation, with no window, and
/// the Notch Island tells the user.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private let settings: HarkSettings
    private var controller: SPUStandardUpdaterController?
    /// A check found an update, or found none.
    var onChange: () -> Void = {}

    init(settings: HarkSettings) {
        self.settings = settings
        super.init()
        // Only Hark.app has a feed. `swift run Hark` has none, and Sparkle shows an alert about that.
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// Sparkle's window: what is new, Install Update, and the restart.
    func install() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// Asks with no window, when the daily check is due. The answer goes to
    /// the settings, and the island tells the user after a later dictation.
    func checkIfDue() {
        guard let updater = controller?.updater, !updater.sessionInProgress, Updates.checkIsDue(settings) else { return }
        settings.updateCheckedAt = Date()
        updater.checkForUpdateInformation()
    }

    // Sparkle calls its delegate on the main thread.

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { found(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { found(nil) }
    }

    private func found(_ version: String?) {
        settings.updateAvailable = version
        onChange()
    }
}
