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

        // Level .statusBar + 8: above menu bar, within macOS CoreDrag layer
        self.level = .statusBar + 8
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
        return true
    }

    public override var canBecomeMain: Bool {
        return true
    }
}

// Global & Local Event Monitor to detect clicks and file-drag gestures across macOS
public final class GlobalEventMonitor {
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []

    public init() {}

    public func addMonitor(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            globalMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) {
            localMonitors.append(l)
        }
    }

    public func stop() {
        for g in globalMonitors { NSEvent.removeMonitor(g) }
        globalMonitors.removeAll()
        for l in localMonitors { NSEvent.removeMonitor(l) }
        localMonitors.removeAll()
    }

    deinit {
        stop()
    }
}

// Custom Hosting View providing native AppKit Drag & Drop and click handling
public final class CoveHostingView<Content: View>: NSHostingView<Content> {
    public weak var windowManager: NotchWindowManager?

    public required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // Direct AppKit click handler on the hosting view
    public override func mouseDown(with event: NSEvent) {
        let mouseLoc = NSEvent.mouseLocation
        guard let wm = windowManager else {
            super.mouseDown(with: event)
            return
        }

        if !wm.isExpanded {
            let pillRect = wm.currentScreenActiveRect().insetBy(dx: -15, dy: -15)
            if pillRect.contains(mouseLoc) {
                wm.expand()
                return
            }
        } else {
            let shelfRect = wm.currentScreenActiveRect().insetBy(dx: -10, dy: -10)
            if !shelfRect.contains(mouseLoc) {
                wm.collapse()
                return
            }
        }

        super.mouseDown(with: event)
    }

    // Pass through clicks that are outside the active pill/shelf
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let wm = windowManager else { return super.hitTest(point) }

        let mouseLoc = NSEvent.mouseLocation
        let activeScreenRect = wm.currentScreenActiveRect().insetBy(dx: -10, dy: -10)

        if activeScreenRect.contains(mouseLoc) {
            return super.hitTest(point)
        } else {
            return nil
        }
    }

    // AppKit Dragging Destination
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DispatchQueue.main.async {
            self.windowManager?.expand()
        }
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = extractURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            return false
        }

        DispatchQueue.main.async {
            for url in urls {
                CoveEngine.shared.stage(url: url)
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.windowManager?.expand()
        }
        return true
    }
}

// Robust URL extraction supporting modern NSURL, legacy NSFilenames, and raw paths
func extractURLs(from pasteboard: NSPasteboard) -> [URL] {
    var result: [URL] = []

    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
        result.append(contentsOf: urls)
    }

    if result.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
        for path in paths {
            result.append(URL(fileURLWithPath: path))
        }
    }

    if result.isEmpty, let stringList = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
        for s in stringList {
            if s.hasPrefix("file://"), let url = URL(string: s) {
                result.append(url)
            } else if s.hasPrefix("/") {
                result.append(URL(fileURLWithPath: s))
            }
        }
    }

    return result
}

@MainActor
public final class NotchWindowManager: NSObject, ObservableObject {
    public static let shared = NotchWindowManager()

    private var panel: NotchPanel?
    private var hostingView: CoveHostingView<NotchCoveView>?
    private let eventMonitor = GlobalEventMonitor()

    // Fixed canvas anchored to top center
    private let canvasWidth: CGFloat = 640
    private let canvasHeight: CGFloat = 200

    @Published public var isExpanded: Bool = false

    private var currentMetrics: NotchMetrics = .current()

    public func setup() {
        self.currentMetrics = NotchMetrics.current()

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

        // Setup global mouse monitoring for click & drag detection
        setupEventMonitors()

        // Handle multi-display changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func setupEventMonitors() {
        // Monitor Left Mouse Down across the entire OS
        eventMonitor.addMonitor(mask: .leftMouseDown) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            DispatchQueue.main.async {
                if self.isExpanded {
                    let activeRect = self.currentScreenActiveRect().insetBy(dx: -10, dy: -10)
                    if !activeRect.contains(loc) {
                        self.collapse()
                    }
                } else {
                    let pillRect = self.currentScreenActiveRect().insetBy(dx: -15, dy: -15)
                    if pillRect.contains(loc) {
                        self.expand()
                    }
                }
            }
        }

        // Monitor Left Mouse Drag across the entire OS (detects files being dragged towards notch)
        eventMonitor.addMonitor(mask: .leftMouseDragged) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            DispatchQueue.main.async {
                let screen = self.currentMetrics.screenFrame
                let triggerRect = NSRect(
                    x: (screen.width - 500) / 2.0 + screen.origin.x,
                    y: screen.maxY - 140,
                    width: 500,
                    height: 140
                )
                if triggerRect.contains(loc) && !self.isExpanded {
                    self.expand()
                }
            }
        }
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

    // Active rect in global screen coordinates (for NSEvent.mouseLocation comparison)
    public func currentScreenActiveRect() -> NSRect {
        let screen = currentMetrics.screenFrame
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

        let x = (screen.width - targetWidth) / 2.0 + screen.origin.x
        let y = screen.maxY - targetHeight

        return NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
    }

    public func expand() {
        guard !isExpanded else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            self.isExpanded = true
        }
        panel?.makeKey()
    }

    public func collapse() {
        guard isExpanded else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            self.isExpanded = false
        }
        panel?.resignKey()
    }

    public func toggleExpanded() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }
}
