import AppKit
import Carbon.HIToolbox
import HarkCore
import WebKit

/// The welcome card, shown once on the first press of the dictation key.
/// The key or "Start dictating" closes it and starts recording; Esc or
/// "Close" only closes it. The panel never becomes key, so the text field
/// the user was in keeps the focus.
@MainActor
final class WelcomeCard: NSObject, WKScriptMessageHandler {
    static let version = 1

    private let settings: HarkSettings
    private let onClose: (_ startRecording: Bool) -> Void
    private var panel: NSPanel?
    private var webView: WKWebView?
    private var escape: Hotkeys?

    init(settings: HarkSettings, onClose: @escaping (_ startRecording: Bool) -> Void) {
        self.settings = settings
        self.onClose = onClose
    }

    var isPending: Bool { settings.onboardingVersion < Self.version }
    var isShown: Bool { panel != nil }

    func show() {
        guard panel == nil,
              let url = Bundle.main.url(forResource: "welcome", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: 440, height: 520)
        let frame = NSRect(
            x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + 40,
            width: size.width, height: size.height
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "hark")
        let webView = FirstClickWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(html, baseURL: nil)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = webView
        panel.orderFrontRegardless()
        self.panel = panel
        self.webView = webView

        let escape = Hotkeys { [weak self] in self?.close(startRecording: false) }
        _ = escape.register([Hotkeys.Key(name: "Esc", code: UInt32(kVK_Escape), modifiers: 0)])
        self.escape = escape
    }

    func close(startRecording: Bool) {
        guard let panel else { return }
        self.panel = nil
        settings.onboardingVersion = Self.version
        escape?.unregister()
        escape = nil
        let webView = webView
        self.webView = nil
        webView?.evaluateJavaScript("closeCard()")
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                webView?.configuration.userContentController.removeScriptMessageHandler(forName: "hark")
            }
        }
        onClose(startRecording)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            switch message.body as? String {
            case "start": close(startRecording: true)
            case "close": close(startRecording: false)
            default: break
            }
        }
    }
}

/// Buttons in a panel that is never key must work on the first click.
private final class FirstClickWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
