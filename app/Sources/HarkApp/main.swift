import AppKit

// Hark.app: dictation in the menu bar. LSUIElement in Info.plist keeps it out
// of the Dock.
if let index = CommandLine.arguments.firstIndex(of: "--render-island"), index + 1 < CommandLine.arguments.count {
    try MainActor.assumeIsolated {
        try NotchIsland.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
