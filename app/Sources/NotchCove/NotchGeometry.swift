import AppKit

/// When a file drag opens the shelf (menu bar → Open Shelf While Dragging).
public enum DragOpenMode: String, CaseIterable {
    /// Like Dropzone/Yoink: the shelf appears the moment a file drag starts, so
    /// you never have to push into the screen edge (which triggers Mission Control).
    case dragStart
    /// Only when the drag gets close to the notch.
    case nearNotch

    static let defaultsKey = "DragOpenMode"

    public static var current: DragOpenMode {
        get { DragOpenMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .dragStart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public var title: String {
        switch self {
        case .dragStart: "As Soon as a Drag Starts"
        case .nearNotch: "Only Near the Notch"
        }
    }
}

/// User-selectable shelf size (menu bar → Shelf Size).
public enum ShelfSize: String, CaseIterable {
    case compact, regular, large

    static let defaultsKey = "ShelfSize"

    public static var current: ShelfSize {
        get { ShelfSize(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .regular }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public var title: String { rawValue.capitalized }

    public var scale: CGFloat {
        switch self {
        case .compact: 0.8
        case .regular: 1.0
        case .large: 1.2
        }
    }
}

/// Describes the notch (physical, or a virtual one drawn inside the menu bar).
public struct NotchMetrics: Equatable {
    public let screenFrame: CGRect
    public let hasPhysicalNotch: Bool
    public let notchWidth: CGFloat
    public let notchHeight: CGFloat
    /// From ShelfSize; scales the open shelf and its cards (the notch itself stays put).
    public var scale: CGFloat = ShelfSize.current.scale

    /// Size of the open shelf.
    public var shelfWidth: CGFloat { (640 * scale).rounded() }
    /// Card = thumbnail (scales) + two text lines and padding (fixed ~44 pt).
    public var cardHeight: CGFloat { (54 * scale).rounded() + 44 }
    /// Header, a 6 pt gap above the cards (room for the hover ×), the cards,
    /// and 12 pt below — so cards are never clipped at any Shelf Size.
    public var shelfHeight: CGFloat { headerHeight + 6 + cardHeight + 12 }
    /// The header row sits beside the notch cut-out, so it's at least as tall as the notch.
    public var headerHeight: CGFloat { max(notchHeight, 28) }
    /// Transparent margin around the open shelf so its shadow isn't clipped.
    public static let shadowMargin: CGFloat = 24

    /// Collapsed width grows a little when the shelf has items, so the badge
    /// peeks out on either side of the physical notch. A virtual notch has no
    /// camera in the middle, so the badge simply sits inside it.
    public func collapsedWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0, hasPhysicalNotch else { return notchWidth }
        // Each side must fit the count badge ("200" needs more room than "2"):
        // ear (6) + inset (8) + badge + a gap before the camera housing (6).
        let digits = CGFloat(String(itemCount).count)
        let badge = max(16, digits * 6.5 + 9)
        let side = (20 + badge).rounded(.up)
        return notchWidth + 2 * side
    }

    /// The screen that hosts the shelf: the primary display (the one with the menu bar).
    public static var hostScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    public static func current(for screen: NSScreen? = hostScreen) -> NotchMetrics {
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
    public func topCenteredRect(width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    public func collapsedRect(itemCount: Int) -> NSRect {
        topCenteredRect(width: collapsedWidth(itemCount: itemCount), height: notchHeight)
    }

    public var shelfRect: NSRect {
        topCenteredRect(width: shelfWidth, height: shelfHeight)
    }

    /// Area where an incoming drag pulls the shelf open: a generous zone around the notch.
    public var dragMagnetRect: NSRect {
        topCenteredRect(width: max(notchWidth + 240, 420), height: notchHeight + 70)
    }
}
