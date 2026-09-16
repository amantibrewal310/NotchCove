import AppKit

public struct NotchMetrics {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let hasPhysicalNotch: Bool
    public let screenFrame: CGRect

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
                screenFrame: .zero
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
                screenFrame: frame
            )
        } else {
            // External screen or non-notched MacBook: floating pill at top
            let pillWidth: CGFloat = 190
            let pillHeight: CGFloat = 32
            let pillX = (frame.width - pillWidth) / 2.0 + frame.origin.x
            let pillY = frame.maxY - pillHeight

            return NotchMetrics(
                x: pillX,
                y: pillY,
                width: pillWidth,
                height: pillHeight,
                hasPhysicalNotch: false,
                screenFrame: frame
            )
        }
    }
}
