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

        // Float above everything (including the menu bar)
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
        return false
    }

    public override var canBecomeMain: Bool {
        return false
    }
}

// Custom Hosting View that provides hit-testing pass-through and native drag-and-drop
public final class CoveHostingView<Content: View>: NSHostingView<Content> {
    public weak var windowManager: NotchWindowManager?

    public required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .URL])
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL])
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // Precise hit-testing: only intercept mouse clicks inside the active pill/shelf.
    // Clicks in empty transparent areas pass straight through to whatever app is underneath!
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let wm = windowManager else { return super.hitTest(point) }

        let activeRect = wm.currentActiveRect(in: self.bounds)

        if activeRect.contains(point) {
            return super.hitTest(point)
        } else {
            // Clicked outside while expanded -> smooth collapse
            if wm.isExpanded {
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.75)) {
                        wm.isExpanded = false
                    }
                }
            }
            return nil
        }
    }

    // Native Drag and Drop Handling
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let wm = windowManager else { return [] }

        let activeRect = wm.currentActiveRect(in: self.bounds)
        if activeRect.insetBy(dx: -30, dy: -30).contains(point) {
            DispatchQueue.main.async {
                wm.expandFromDrag()
            }
            return .copy
        }
        return []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let wm = windowManager else { return [] }

        let activeRect = wm.currentActiveRect(in: self.bounds)
        if activeRect.insetBy(dx: -30, dy: -30).contains(point) {
            return .copy
        }
        return []
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
            self.windowManager?.expandFromDrag()
        }
        return true
    }
}

@MainActor
public final class NotchWindowManager: NSObject, ObservableObject {
    public static let shared = NotchWindowManager()

    private var panel: NotchPanel?
    private var hostingView: CoveHostingView<NotchCoveView>?

    // Canvas size for overlay: remains permanently fixed at top center so it never displaces!
    private let canvasWidth: CGFloat = 640
    private let canvasHeight: CGFloat = 200

    @Published public var isExpanded: Bool = false

    private var currentMetrics: NotchMetrics = .current()

    public func setup() {
        self.currentMetrics = NotchMetrics.current()

        // Fixed frame anchored to the very top center of the screen
        let canvasX = (currentMetrics.screenFrame.width - canvasWidth) / 2.0 + currentMetrics.screenFrame.origin.x
        let canvasY = currentMetrics.screenFrame.maxY - canvasHeight

        let windowRect = NSRect(
            x: canvasX,
            y: canvasY,
            width: canvasWidth,
            height: canvasHeight
        )

        let panel = NotchPanel(contentRect: windowRect)
        self.panel = panel

        let rootView = NotchCoveView(
            metrics: currentMetrics,
            isExpanded: Binding(
                get: { [weak self] in self?.isExpanded ?? false },
                set: { [weak self] val in self?.isExpanded = val }
            )
        )

        let hostingView = CoveHostingView(rootView: rootView)
        hostingView.windowManager = self
        hostingView.frame = NSRect(origin: .zero, size: windowRect.size)
        hostingView.autoresizingMask = [.width, .height]
        self.hostingView = hostingView

        panel.contentView = hostingView
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
        guard let panel = panel else { return }

        let canvasX = (currentMetrics.screenFrame.width - canvasWidth) / 2.0 + currentMetrics.screenFrame.origin.x
        let canvasY = currentMetrics.screenFrame.maxY - canvasHeight

        panel.setFrame(
            NSRect(x: canvasX, y: canvasY, width: canvasWidth, height: canvasHeight),
            display: true
        )
    }

    public func currentActiveRect(in viewBounds: NSRect) -> NSRect {
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

        let x = (viewBounds.width - targetWidth) / 2.0
        let y = viewBounds.height - targetHeight

        return NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
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
}
