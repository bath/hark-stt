import AppKit
import SwiftUI

/// Graphite Blue: the one look of Hark. The same colors are the `:root`
/// tokens of the website (docs/index.html) and of the welcome card
/// (Resources/welcome.html). Change a color in the three places together.
enum Theme {
    static let paper = color(light: 0xEEF0F3, dark: 0x0F1115)
    static let surface = color(light: 0xFFFFFF, dark: 0x181B21)
    static let ink = color(light: 0x14171C, dark: 0xE8EBF0)
    static let mute = color(light: 0x5F6165, dark: 0xA3A9B3)
    static let rule = color(light: 0xD5D5D6, dark: 0x2A2E36)
    /// The one color for actions.
    static let accent = color(light: 0x2563EB, dark: 0x5B8CFF)
    static let accentInk = color(light: 0xFFFFFF, dark: 0x0A0F1F)
    static let ok = color(light: 0x1D8748, dark: 0x3FCF7D)

    static var surfaceNS: NSColor { nsColor(light: 0xFFFFFF, dark: 0x181B21) }
    /// On the black Notch Island: the island's red, and the accent made light enough to read.
    static let islandRed = NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
    static let islandNote = NSColor(srgbRed: 0.66, green: 0.76, blue: 0.97, alpha: 1)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nsColor(light: light, dark: dark))
    }

    private static func nsColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

/// The pill button: the accent color, or plain gray text for the second choice.
struct PillButtonStyle: ButtonStyle {
    var primary = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, primary ? 18 : 8)
            .frame(height: 32)
            .foregroundStyle(primary ? Theme.accentInk : Theme.mute)
            .background(primary ? Theme.accent : Color.clear, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// The menu bar icon: a small waveform, the mark of the app icon.
enum MenuBarIcon {
    enum State {
        case ready, recording, busy
    }

    /// The bar heights of the waveform, in points, on an 18 by 16 canvas.
    private static let bars: [CGFloat] = [4, 9, 14, 8, 11, 5]

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            let color: NSColor = switch state {
            case .ready: .black
            case .recording: Theme.islandRed
            case .busy: NSColor.black.withAlphaComponent(0.4)
            }
            color.setFill()
            for (index, height) in bars.enumerated() {
                let bar = NSRect(x: 1.5 + CGFloat(index) * 2.8, y: rect.midY - height / 2, width: 1.7, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 0.85, yRadius: 0.85).fill()
            }
            return true
        }
        // A template image follows the menu bar's light or dark color. Red stays red.
        image.isTemplate = state != .recording
        image.accessibilityDescription = "Hark"
        return image
    }
}
