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

        // Float above everything (including the menu bar on external monitors)
        self.level = NSWindow.Level(Int(CGWindowLevelKey.overlayWindow.rawValue))
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
        self.acceptsMouseMovedEvents = true
        self.hidesOnDeactivate = false
    }

    public override var canBecomeKey: Bool {
        // Allow becoming key so text inputs or keyboard focus can work if needed
        return true
    }

    public override var canBecomeMain: Bool {
        return false
    }
}

// Custom Hosting View that guarantees First Mouse and Native macOS Drag & Drop
public final class CoveHostingView<Content: View>: NSHostingView<Content> {
    public required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .URL])
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL])
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Crucial: Allows single-click responsiveness on non-active overlay windows!
        return true
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DispatchQueue.main.async {
            NotchWindowManager.shared.expandFromDrag()
        }
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else {
            return false
        }

        DispatchQueue.main.async {
            for url in urls {
                CoveEngine.shared.stage(url: url)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            NotchWindowManager.shared.expandFromDrag()
        }
        return true
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

        let hostingView = CoveHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: initialRect.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        setupGlobalClickDismiss()

        panel.orderFrontRegardless()

        // Handle multi-display changes
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

    private func setupGlobalClickDismiss() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
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

    public func expandFromDrag() {
        if !self.isExpanded {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                self.isExpanded = true
            }
        }
    }

    private func updateWindowFrame() {
        guard let panel = panel else { return }

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if isExpanded {
            let itemCount = CoveEngine.shared.items.count
            targetWidth = max(460, CGFloat(itemCount * 90 + 160))
            targetHeight = 145
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
