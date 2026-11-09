import AppKit

/// macOS can go on answering "no" to `AXIsProcessTrusted()` in a running
/// process after the user turns Hark on in Accessibility, while a new process
/// of the same app gets "yes" (seen on macOS 26.6). Hark then cannot paste
/// until it starts again. The probe asks a new process, and `restart()` starts
/// Hark again when only this process is behind.
@MainActor
enum AccessibilityProbe {
    nonisolated static let command = "accessibility-probe"
    /// Given to the new process, so that it restarts at most once.
    nonisolated static let restartedFlag = "--restarted-for-accessibility"

    private static var running = false

    /// Calls `restart` when this process says no and a new one says yes.
    static func check(restart: @escaping @MainActor () -> Void) {
        guard !running, !AXIsProcessTrusted(),
              !CommandLine.arguments.contains(restartedFlag),
              let executable = Bundle.main.executableURL
        else { return }
        let child = Process()
        child.executableURL = executable
        child.arguments = [command]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { process in
            let granted = process.terminationStatus == 0
            Task { @MainActor in
                running = false
                if granted && !AXIsProcessTrusted() { restart() }
            }
        }
        do {
            try child.run()
            running = true
        } catch {
            log.error("accessibility probe: \(String(describing: error))")
        }
    }

    /// Quits Hark and opens it again on the setup window, once this process has
    /// exited, so the two never hold the hotkeys at the same time.
    static func restart() {
        log.notice("Accessibility is on, but not for this process. Restarting.")
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = [
            "-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open -n \"$0\" --args --setup \(restartedFlag)",
            Bundle.main.bundlePath,
        ]
        do {
            try shell.run()
            NSApp.terminate(nil)
        } catch {
            log.error("restart: \(String(describing: error))")
        }
    }
}
