import AppKit
import SwiftUI

/// The NotchCove mark, shared by the menu bar, the notch and the shelf header.
enum Brand {
    /// Template image on the logo's 20-unit grid (y down), drawn at 18 pt.
    static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 20)
            transform.translateX(by: 1, yBy: 1)
            transform.concat()
            NSColor.black.setFill()

            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: 4.5, y: 1))
            notch.line(to: NSPoint(x: 13.5, y: 1))
            notch.line(to: NSPoint(x: 13.5, y: 2.8))
            notch.curve(to: NSPoint(x: 11.4, y: 4.8), controlPoint1: NSPoint(x: 13.5, y: 4), controlPoint2: NSPoint(x: 12.6, y: 4.8))
            notch.line(to: NSPoint(x: 6.6, y: 4.8))
            notch.curve(to: NSPoint(x: 4.5, y: 2.8), controlPoint1: NSPoint(x: 5.4, y: 4.8), controlPoint2: NSPoint(x: 4.5, y: 4))
            notch.close()
            notch.fill()

            for (x, y, width, height, radius) in [(6.0, 6.0, 6.0, 2.4, 1.1), (4.4, 9.4, 9.2, 2.8, 1.3), (2.6, 13.2, 12.8, 3.6, 1.6)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NotchCove"
        return image
    }()
}

/// The shelf's colour themes. The shelf body stays black in all of them.
enum ThemeChoice: String, Setting {
    case graphite, lantern, signal

    static let defaultsKey = "Theme"
    static let defaultValue = ThemeChoice.lantern

    var title: String { rawValue.capitalized }

    var theme: ShelfTheme {
        switch self {
        case .graphite: .graphite
        case .lantern: .lantern
        case .signal: .signal
        }
    }
}

struct ShelfTheme: Equatable {
    var accent: Color
    var textPrimary: Color
    var textSecondary: Color
    /// Text on an accent fill (count badges).
    var onAccent: Color

    var cardFill: Color
    var cardHoverFill: Color
    var selectionFill: Color
    var selectionRing: Color?
    var selectedTitle: Color
    var selectedSubtitle: Color
    var removeButtonFill: Color

    var dropFill: Color
    var dropStroke: Color
    var dropLineWidth: CGFloat
    var dropDashed: Bool

    var headerTitle: String
    var headerTitleFont: Font
    var headerTitleTracking: CGFloat
    var headerCountColor: Color

    /// System blue, a ring around the selection, dashed drop zone.
    static let graphite: ShelfTheme = {
        let accent = Color(hex: 0x0A84FF)
        return ShelfTheme(
            accent: accent,
            textPrimary: Color(hex: 0xF5F5F7),
            textSecondary: Color(hex: 0x98989D),
            onAccent: .white,
            cardFill: .white.opacity(0.06),
            cardHoverFill: .white.opacity(0.12),
            selectionFill: accent.opacity(0.25),
            selectionRing: accent,
            selectedTitle: Color(hex: 0xF5F5F7),
            selectedSubtitle: Color(hex: 0x98989D),
            removeButtonFill: Color(hex: 0x3A3A3C),
            dropFill: accent.opacity(0.08),
            dropStroke: accent.opacity(0.7),
            dropLineWidth: 1.5,
            dropDashed: true,
            headerTitle: "Cove",
            headerTitleFont: .system(size: 13, weight: .semibold),
            headerTitleTracking: 0,
            headerCountColor: Color(hex: 0x98989D)
        )
    }()

    /// Warm amber: a soft glow for selection and a calm hairline drop zone.
    static let lantern: ShelfTheme = {
        let accent = Color(hex: 0xFF9F0A)
        return ShelfTheme(
            accent: accent,
            textPrimary: Color(hex: 0xF5EFE6),
            textSecondary: Color(hex: 0xA39A8E),
            onAccent: Color(hex: 0x1A1206),
            cardFill: Color(hex: 0x1C1813),
            cardHoverFill: Color(hex: 0x2B251D),
            selectionFill: accent.opacity(0.16),
            selectionRing: nil,
            selectedTitle: Color(hex: 0xFFB340),
            selectedSubtitle: Color(hex: 0xA39A8E),
            removeButtonFill: Color(hex: 0x4A4136),
            dropFill: accent.opacity(0.08),
            dropStroke: accent.opacity(0.6),
            dropLineWidth: 1.5,
            dropDashed: false,
            headerTitle: "Cove",
            headerTitleFont: .system(size: 13, weight: .semibold),
            headerTitleTracking: 0,
            headerCountColor: Color(hex: 0xA39A8E)
        )
    }()

    /// Vivid pink: flat cards, a solid selection and a bold drop zone.
    static let signal: ShelfTheme = {
        let accent = Color(hex: 0xFF375F)
        return ShelfTheme(
            accent: accent,
            textPrimary: .white,
            textSecondary: Color(hex: 0x8E8E93),
            onAccent: .white,
            cardFill: .clear,
            cardHoverFill: .white.opacity(0.09),
            selectionFill: accent,
            selectionRing: nil,
            selectedTitle: .white,
            selectedSubtitle: .white.opacity(0.85),
            removeButtonFill: Color(hex: 0x48484A),
            dropFill: accent.opacity(0.12),
            dropStroke: accent,
            dropLineWidth: 2,
            dropDashed: false,
            headerTitle: "COVE",
            headerTitleFont: .system(size: 11, weight: .bold),
            headerTitleTracking: 1.76,
            headerCountColor: accent
        )
    }()
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
