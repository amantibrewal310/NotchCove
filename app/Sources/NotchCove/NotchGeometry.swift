import AppKit

/// When a file drag opens the shelf (menu bar → Open Shelf While Dragging).
enum DragOpenMode: String, Setting {
    /// Opens without pushing into the screen edge, which triggers Mission Control.
    case dragStart
    case nearNotch

    static let defaultsKey = "DragOpenMode"
    static let defaultValue = DragOpenMode.dragStart

    var title: String {
        switch self {
        case .dragStart: "As Soon as a Drag Starts"
        case .nearNotch: "Only Near the Notch"
        }
    }
}

/// User-selectable shelf size (menu bar → Shelf Size).
enum ShelfSize: String, Setting {
    case compact, regular, large

    static let defaultsKey = "ShelfSize"
    static let defaultValue = ShelfSize.regular

    var title: String { rawValue.capitalized }

    var scale: CGFloat {
        switch self {
        case .compact: 0.8
        case .regular: 1.0
        case .large: 1.2
        }
    }
}

/// Describes the notch (physical, or a virtual one drawn inside the menu bar).
struct NotchMetrics: Equatable {
    let screenFrame: CGRect
    let hasPhysicalNotch: Bool
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    /// From ShelfSize; scales the open shelf and its cards (the notch itself stays put).
    var scale: CGFloat = ShelfSize.current.scale

    var shelfWidth: CGFloat { (640 * scale).rounded() }
    /// Thumbnail (scales) plus two text lines and padding (fixed).
    var cardHeight: CGFloat { (54 * scale).rounded() + 44 }
    /// Header, a 6 pt gap for the hover ×, the cards, 12 pt below.
    var shelfHeight: CGFloat { headerHeight + 6 + cardHeight + 12 }
    /// Thumbnail size of a single-file card.
    var cardThumbnailSize: CGFloat { (50 * scale).rounded() }
    /// The header row sits beside the notch cut-out, so it's at least as tall as the notch.
    var headerHeight: CGFloat { max(notchHeight, 28) }
    /// Transparent margin around the open shelf so its shadow isn't clipped.
    static let shadowMargin: CGFloat = 24

    /// Widens with items so the count badge peeks out beside a physical notch.
    func collapsedWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0, hasPhysicalNotch else { return notchWidth }
        // Per side: ear 6 + inset 8 + badge + gap before the camera 6.
        let digits = CGFloat(String(itemCount).count)
        let badge = max(16, digits * 6.5 + 9)
        let side = (20 + badge).rounded(.up)
        return notchWidth + 2 * side
    }

    /// The screen that hosts the shelf: the primary display (the one with the menu bar).
    static var hostScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    static func current(for screen: NSScreen? = hostScreen) -> NotchMetrics {
        guard let screen else {
            return NotchMetrics(screenFrame: .zero, hasPhysicalNotch: false, notchWidth: 180, notchHeight: 24)
        }
        let frame = screen.frame

        // `defaults write com.notchcove.app ForceVirtualNotch -bool YES` previews
        // the external-display look on a MacBook.
        let forceVirtual = UserDefaults.standard.bool(forKey: "ForceVirtualNotch")
        if screen.safeAreaInsets.top > 0, !forceVirtual {
            var width: CGFloat = 185
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               left.width > 0, right.width > 0 {
                width = frame.width - left.width - right.width
            }
            return NotchMetrics(
                screenFrame: frame,
                hasPhysicalNotch: true,
                notchWidth: width,
                notchHeight: screen.safeAreaInsets.top
            )
        }

        // No notch: draw a virtual one that fits inside the menu bar.
        let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
        return NotchMetrics(
            screenFrame: frame,
            hasPhysicalNotch: false,
            notchWidth: 170,
            notchHeight: max(menuBarHeight > 0 ? menuBarHeight : 24, 22)
        )
    }

    /// Screen rect of a top-centred box of the given size.
    func topCenteredRect(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    func collapsedRect(itemCount: Int) -> NSRect {
        topCenteredRect(width: collapsedWidth(itemCount: itemCount), height: notchHeight)
    }

    var shelfRect: NSRect {
        topCenteredRect(width: shelfWidth, height: shelfHeight)
    }

    /// Area where an incoming drag pulls the shelf open: a generous zone around the notch.
    var dragMagnetRect: NSRect {
        topCenteredRect(width: max(notchWidth + 240, 420), height: notchHeight + 70)
    }
}
