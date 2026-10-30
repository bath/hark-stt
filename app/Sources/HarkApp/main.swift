import AppKit

// Hark.app: dictation in the menu bar. LSUIElement in Info.plist keeps it out
// of the Dock.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
