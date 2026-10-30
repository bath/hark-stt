import AppKit
import ApplicationServices
import HarkCore

public enum PasteError: Error, CustomStringConvertible {
    case noAccessibility

    public var description: String {
        "Hark needs the Accessibility permission to paste. The text is on the clipboard."
    }
}

/// Puts the text on the clipboard and presses ⌘V. The text stays on the
/// clipboard, so it survives a paste into a window with no text field.
public struct PasteboardPaster: Paster {
    public init() {}

    public func paste(_ text: String) async throws {
        try await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            guard AXIsProcessTrusted() else { throw PasteError.noAccessibility }
            let source = CGEventSource(stateID: .combinedSessionState)
            let v: CGKeyCode = 9 // kVK_ANSI_V
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }
}
