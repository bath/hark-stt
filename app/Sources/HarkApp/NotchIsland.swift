import AppKit
import HarkCore
import QuartzCore

/// The Notch Island: while the user dictates, the notch grows sideways into
/// a black pill. A red dot and a timer on the left, voice bars on the right;
/// then "Transcribing" with a spinner; then a green check and "Pasted" (or
/// what went wrong) before it closes into the notch again. A screen with no
/// notch gets the same pill from the top center. It opens on the screen with
/// the pointer. The motion is IslandModel; this class only draws it.
@MainActor
final class NotchIsland {
    private var model = IslandModel(geometry: .notch(width: 0, height: 0))
    private var panel: NSPanel?
    private var view: IslandView?
    private var screen: NSScreen?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    func show(_ phase: DictationPhase) {
        let mode = IslandModel.Mode(phase)
        let message: String? = if case let .error(text) = phase { text } else { nil }
        // Every dictation opens on the pointer's screen; later states stay there.
        if mode == .recording || panel == nil || !isOpen { open() }
        model.set(mode, message: message, now: CACurrentMediaTime())
    }

    func level(_ rms: Float) {
        model.setLevel(rms: Double(rms), now: CACurrentMediaTime())
    }

    func hide() {
        displayLink?.invalidate()
        displayLink = nil
        panel?.orderOut(nil)
        model.set(.idle, now: CACurrentMediaTime())
    }

    private var isOpen: Bool { displayLink != nil }

    private func open() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let (geometry, centerX) = Self.geometry(of: screen)
        if screen != self.screen || panel == nil {
            self.screen = screen
            model.move(to: geometry)
            place(on: screen, geometry: geometry, centerX: centerX)
        }
        panel?.orderFrontRegardless()
        if displayLink == nil, let view {
            lastTick = nil
            let link = view.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// The notch from the screen's safe area, or a pill below the menu bar.
    static func geometry(of screen: NSScreen) -> (IslandModel.Geometry, centerX: Double) {
        let frame = screen.frame
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        if left > 0 && right > 0 {
            let width = frame.width - left - right
            return (.notch(width: width, height: screen.safeAreaInsets.top), left + width / 2)
        }
        let menuBar = frame.maxY - screen.visibleFrame.maxY
        return (.noNotch(menuBarHeight: menuBar), frame.width / 2)
    }

    private func place(on screen: NSScreen, geometry: IslandModel.Geometry, centerX: Double) {
        let size = NSSize(width: geometry.canvasWidth, height: geometry.height + 20)
        let origin = NSPoint(x: screen.frame.minX + centerX - size.width / 2, y: screen.frame.maxY - size.height)
        let frame = NSRect(origin: origin, size: size)
        if let panel {
            panel.setFrame(frame, display: false)
            return
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let view = IslandView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = view
        self.panel = panel
        self.view = view
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        model.step(now: now, dt: now - (lastTick ?? now))
        lastTick = now
        view?.draw(model, now: now)
        if model.isClosed {
            displayLink?.invalidate()
            displayLink = nil
            panel?.orderOut(nil)
        }
    }

    private func screensChanged() {
        // The screen may be gone or have moved. The next dictation measures again.
        let wasOpen = isOpen
        panel?.orderOut(nil)
        panel = nil
        view = nil
        screen = nil
        displayLink?.invalidate()
        displayLink = nil
        if wasOpen && model.mode != .idle { open() }
    }
}

extension NotchIsland {
    /// Draws each state, settled, into PNG files in `directory`, for checking
    /// the drawing against the website without a screen recording.
    /// `Hark --render-island DIR`
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let geometry = IslandModel.Geometry.notch(width: 185, height: 32)
        let states: [(String, IslandModel.Mode, String?)] = [
            ("recording", .recording, nil), ("transcribing", .transcribing, nil),
            ("done", .done, nil), ("error", .error, "No speech"),
        ]
        for (name, mode, message) in states {
            var model = IslandModel(geometry: geometry)
            model.set(mode, message: message, now: 0)
            var t = 0.0
            for _ in 0..<60 {
                t += 1.0 / 60
                if mode == .recording { model.setLevel(rms: 0.08, now: t) }
                model.step(now: t, dt: 1.0 / 60)
            }
            let view = IslandView(frame: NSRect(x: 0, y: 0, width: geometry.canvasWidth, height: geometry.height + 20))
            view.appearance = NSAppearance(named: .darkAqua)
            view.draw(model, now: t)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor(white: 0.85, alpha: 1).setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        }
    }
}

/// Draws one frame of the island. Coordinates are flipped, so y grows down
/// from the top of the screen, as in hark.lua.
private final class IslandView: NSView {
    private var model: IslandModel?
    private var now = 0.0

    override var isFlipped: Bool { true }

    static let red = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
    static let green = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    func draw(_ model: IslandModel, now: Double) {
        self.model = model
        self.now = now
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()
        guard let model else { return }
        let w = max(0, model.width.x), h = max(0, model.height.x)
        guard w > 1 && h > 1 else { return }
        let x0 = bounds.width / 2 - w / 2, x1 = bounds.width / 2 + w / 2, cy = h / 2
        let left = x0 + 20, right = x1 - 14

        // The shape starts above the screen edge, so only its bottom corners show.
        let r = min(14, h / 2)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: x0, y: -r, width: w, height: h + r), xRadius: r, yRadius: r).fill()

        let rec = model.alpha(.recording)
        if rec > 0.01 {
            Self.red.withAlphaComponent(rec * (0.55 + 0.45 * IslandModel.blink(now: now))).setFill()
            NSBezierPath(ovalIn: NSRect(x: left - 6, y: cy - 4, width: 8, height: 8)).fill()
            let seconds = Int(model.elapsed)
            text(String(format: "%d:%02d", seconds / 60, seconds % 60), at: left + 8, cy: cy, alpha: rec, alignRight: false)
            Self.red.withAlphaComponent(rec).setFill()
            for (i, band) in model.bands.enumerated() {
                let bh = 3 + band * (h - 16)
                let bar = NSRect(x: right - 6 - Double(i) * 5, y: cy - bh / 2, width: 2.6, height: bh)
                NSBezierPath(roundedRect: bar, xRadius: 1.3, yRadius: 1.3).fill()
            }
        }

        let busy = model.alpha(.transcribing)
        if busy > 0.01 {
            let start = (now * 340).truncatingRemainder(dividingBy: 360)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: left, y: cy), radius: 6, startAngle: start, endAngle: start + 250)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            NSColor.white.withAlphaComponent(busy).setStroke()
            arc.stroke()
            text("Transcribing", at: right, cy: cy, alpha: busy * 0.92)
        }

        let done = model.alpha(.done)
        if done > 0.01 {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: left - 5, y: cy + 0.5))
            check.line(to: NSPoint(x: left - 1.5, y: cy + 4))
            check.line(to: NSPoint(x: left + 5.5, y: cy - 3.5))
            check.lineWidth = 2.2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Self.green.withAlphaComponent(done).setStroke()
            check.stroke()
            text("Pasted", at: right, cy: cy, alpha: done * 0.92)
        }

        let failed = model.alpha(.error)
        if failed > 0.01 {
            let cross = NSBezierPath()
            for d in [1.0, -1.0] {
                cross.move(to: NSPoint(x: left - 4, y: cy - 4 * d))
                cross.line(to: NSPoint(x: left + 4, y: cy + 4 * d))
            }
            cross.lineWidth = 2
            cross.lineCapStyle = .round
            Self.red.withAlphaComponent(failed).setStroke()
            cross.stroke()
            text(model.message, at: right, cy: cy, alpha: failed * 0.92)
        }
    }

    /// Text centered on `cy`, starting at `x`, or ending at `x` when right-aligned.
    private func text(_ string: String, at x: Double, cy: Double, alpha: Double, alignRight: Bool = true) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let size = (string as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: alignRight ? x - size.width : x, y: cy - size.height / 2)
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }
}
