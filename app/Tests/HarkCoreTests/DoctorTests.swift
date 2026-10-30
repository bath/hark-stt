import Foundation
import Testing
@testable import HarkCore

@Suite struct DoctorTests {
    let app = "/Applications/Hark.app"

    func status(microphone: String = "authorized", accessibility: Bool = true, model: String = "loaded",
                progress: Double? = nil, login: String = "enabled", f5: Bool = true) -> AppStatus {
        AppStatus(version: "2.0.0", pid: 1, phase: "idle", model: model, modelProgress: progress,
                  accessibility: accessibility, microphone: microphone, hotkeysTaken: [], keyMapping: f5,
                  loginItem: login, updated: Date())
    }

    func report(_ status: AppStatus?, model: Bool = true, app: String? = nil) -> Doctor.Report {
        Doctor.report(.init(appPath: app ?? self.app, status: status, modelPresent: model))
    }

    /// The rules every report must follow, whatever the state.
    func checkContract(_ report: Doctor.Report) throws {
        let failed = report.checks.filter { !$0.ok }
        #expect(report.ok == report.checks.allSatisfy { $0.ok || !$0.required })
        #expect(report.readyToDictate == report.ok)
        #expect(report.nextStep == (failed.first { $0.required } ?? failed.first))
        for check in failed {
            #expect(check.fix?.isEmpty == false, "\(check.id) needs a fix")
            #expect(check.needsHuman != nil, "\(check.id) must say if a person must act")
        }
        for check in report.checks where check.ok {
            #expect(check.fix == nil && check.needsHuman == nil && check.command == nil)
        }
        // The JSON has the same field names as the hark CLI.
        let json = try JSONSerialization.jsonObject(with: Data(report.json().utf8)) as! [String: Any]
        for key in ["hark", "ok", "ready_to_dictate", "checks", "hotkeys"] { #expect(json[key] != nil, "missing \(key)") }
        for check in json["checks"] as! [[String: Any]] {
            for key in ["id", "title", "ok", "required"] { #expect(check[key] != nil) }
            if check["ok"] as? Bool == false { #expect(check["needs_human"] is Bool && check["fix"] is String) }
        }
    }

    @Test func allGoodIsReady() throws {
        let report = report(status())
        try checkContract(report)
        #expect(report.ok)
        #expect(report.nextStep == nil)
    }

    @Test func notRunningAsksToOpenTheApp() throws {
        let report = report(nil, model: false)
        try checkContract(report)
        #expect(!report.ok)
        #expect(report.nextStep?.id == "app_running")
        #expect(report.nextStep?.needsHuman == false)
        #expect(report.nextStep?.command == "open /Applications/Hark.app")
        // Permissions are unknown, and no person is asked to act on them yet.
        let microphone = report.checks.first { $0.id == "microphone" }!
        #expect(microphone.needsHuman == false)
    }

    @Test func aDownloadInProgressSaysToWait() throws {
        let report = report(status(model: "downloading", progress: 0.42), model: false)
        try checkContract(report)
        #expect(report.nextStep?.id == "model")
        #expect(report.nextStep?.fix?.contains("42 %") == true)
        #expect(report.nextStep?.needsHuman == false)
    }

    @Test func permissionsNeedAPerson() throws {
        var report = report(status(microphone: "not_determined", accessibility: false))
        try checkContract(report)
        #expect(report.nextStep?.id == "microphone")
        #expect(report.nextStep?.needsHuman == true)
        #expect(report.nextStep?.command?.contains("--setup") == true)

        report = self.report(status(microphone: "denied", accessibility: false))
        #expect(report.nextStep?.command?.hasSuffix("open-settings microphone") == true)

        report = self.report(status(accessibility: false))
        try checkContract(report)
        #expect(report.nextStep?.id == "accessibility")
        #expect(report.nextStep?.needsHuman == true)
        #expect(report.nextStep?.command == "/Applications/Hark.app/Contents/MacOS/Hark open-settings accessibility")
    }

    @Test func optionalChecksDoNotBlockReady() throws {
        let report = report(status(login: "not_registered"), app: "/Users/me/Downloads/Hark.app")
        try checkContract(report)
        #expect(report.ok)
        #expect(report.nextStep?.id == "app_in_applications")
        let login = report.checks.first { $0.id == "login_item" }!
        #expect(login.needsHuman == false)
        #expect(login.command?.hasSuffix("login-item on") == true)
    }

    @Test func f5WithoutTheMappingIsOptional() throws {
        let report = report(status(f5: false))
        try checkContract(report)
        #expect(report.ok)
        #expect(report.nextStep?.id == "f5_key")
        #expect(report.nextStep?.needsHuman == false)
        #expect(report.nextStep?.command?.hasSuffix("f5-key on") == true)
    }

    @Test func aLoginItemThatNeedsApprovalNeedsAPerson() throws {
        let report = report(status(login: "requires_approval"))
        let login = report.checks.first { $0.id == "login_item" }!
        #expect(login.needsHuman == true)
        #expect(login.command?.hasSuffix("open-settings login-items") == true)
    }

    @Test func aLoadingModelIsNotReadyYet() throws {
        let report = report(status(model: "loading"))
        try checkContract(report)
        #expect(report.nextStep?.id == "ready")
        #expect(report.nextStep?.command?.contains("--wait 15") == true)
    }

    @Test func pathsWithSpacesAreQuoted() {
        #expect(Doctor.quoted("/Users/me/My Apps/Hark.app") == "'/Users/me/My Apps/Hark.app'")
        #expect(Doctor.quoted("/Applications/Hark.app") == "/Applications/Hark.app")
    }
}
