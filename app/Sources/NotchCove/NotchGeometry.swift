import AppKit

public struct NotchMetrics {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let hasPhysicalNotch: Bool
    public let screenFrame: CGRect
    /// Distance from top of canvas window to top of the pill (used for SwiftUI layout)
    public let topInset: CGFloat

    public var centerPoint: CGPoint {
        CGPoint(x: x + width / 2.0, y: y + height / 2.0)
    }

    public static func current(for screen: NSScreen? = NSScreen.main) -> NotchMetrics {
        guard let screen = screen ?? NSScreen.main else {
            return NotchMetrics(
                x: 0,
                y: 0,
                width: 200,
                height: 34,
                hasPhysicalNotch: false,
                screenFrame: .zero,
                topInset: 0
            )
        }

        let frame = screen.frame
        let safeArea = screen.safeAreaInsets

        if safeArea.top > 0 {
            // Physical Notch detected!
            var notchX: CGFloat = 0
            var notchWidth: CGFloat = 200

            if let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea,
               leftArea.width > 0 && rightArea.width > 0 {
                notchX = leftArea.origin.x + leftArea.size.width
                notchWidth = rightArea.origin.x - notchX
            } else {
                notchWidth = 210
                notchX = (frame.width - notchWidth) / 2.0 + frame.origin.x
            }

            let notchHeight = safeArea.top
            let notchY = frame.maxY - notchHeight

            return NotchMetrics(
                x: notchX,
                y: notchY,
                width: notchWidth,
                height: notchHeight,
                hasPhysicalNotch: true,
                screenFrame: frame,
                topInset: 0
            )
        } else {
            // External screen or non-notched MacBook: floating pill BELOW the menu bar
            let pillWidth: CGFloat = 190
            let pillHeight: CGFloat = 32

            // Menu bar height = distance from screen top to visible area top
            let visibleFrame = screen.visibleFrame
            let menuBarHeight = frame.maxY - visibleFrame.maxY  // typically ~30pt

            // Position pill just below the menu bar
            let pillX = (frame.width - pillWidth) / 2.0 + frame.origin.x
            let pillY = visibleFrame.maxY - pillHeight  // bottom of pill at (menuBarBottom - pillHeight)

            // topInset = how far down from the canvas window's top edge to the pill's top edge
            // Canvas window top is at frame.maxY, pill top is at visibleFrame.maxY
            // So topInset = frame.maxY - visibleFrame.maxY = menuBarHeight
            let topInset = menuBarHeight

            return NotchMetrics(
                x: pillX,
                y: pillY,
                width: pillWidth,
                height: pillHeight,
                hasPhysicalNotch: false,
                screenFrame: frame,
                topInset: topInset
            )
        }
    }
}
