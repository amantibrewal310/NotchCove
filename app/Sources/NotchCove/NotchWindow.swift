import AppKit
import SwiftUI

public final class NotchPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
    }

    public override var canBecomeKey: Bool {
        return false
    }

    public override var canBecomeMain: Bool {
        return false
    }
}

@MainActor
public final class NotchWindowManager: NSObject, ObservableObject {
    public static let shared = NotchWindowManager()

    private var panel: NotchPanel?
    private var trackingArea: NSTrackingArea?
    private var globalClickMonitor: Any?

    @Published public var isExpanded: Bool = false {
        didSet {
            updateWindowFrame()
        }
    }

    private var currentMetrics: NotchMetrics = .current()

    public func setup() {
        self.currentMetrics = NotchMetrics.current()

        let initialRect = NSRect(
            x: currentMetrics.x,
            y: currentMetrics.y,
            width: currentMetrics.width,
            height: currentMetrics.height
        )

        let panel = NotchPanel(contentRect: initialRect)
        self.panel = panel

        let rootView = NotchCoveView(
            metrics: currentMetrics,
            isExpanded: Binding(
                get: { [weak self] in self?.isExpanded ?? false },
                set: { [weak self] val in self?.isExpanded = val }
            )
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = initialRect
        panel.contentView = hostingView

        setupTracking(for: hostingView)
        setupGlobalClickDismiss()

        panel.orderFrontRegardless()

        // Screen change listener (e.g. plugging/unplugging monitor)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        self.currentMetrics = NotchMetrics.current()
        updateWindowFrame()
    }

    private func setupTracking(for view: NSView) {
        if let existing = trackingArea {
            view.removeTrackingArea(existing)
        }

        let area = NSTrackingArea(
            rect: view.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
        self.trackingArea = area
    }

    private func setupGlobalClickDismiss() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isExpanded else { return }
            if let panel = self.panel {
                let mouseLocation = NSEvent.mouseLocation
                if !panel.frame.contains(mouseLocation) {
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                            self.isExpanded = false
                        }
                    }
                }
            }
        }
    }

    public func toggleExpanded() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
            self.isExpanded.toggle()
        }
    }

    private func updateWindowFrame() {
        guard let panel = panel else { return }

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if isExpanded {
            let itemCount = CoveEngine.shared.items.count
            targetWidth = max(440, CGFloat(itemCount * 90 + 160))
            targetHeight = 140
        } else {
            targetWidth = currentMetrics.width
            targetHeight = currentMetrics.height
        }

        let targetX = currentMetrics.centerPoint.x - (targetWidth / 2.0)
        let targetY = currentMetrics.screenFrame.maxY - targetHeight

        let targetFrame = NSRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }
}
