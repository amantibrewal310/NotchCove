import AppKit
import SwiftUI
import Combine

func clog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)"
    print(line)
    fflush(stdout)
    if let data = (line + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: "/tmp/notchcove.log") {
            if let fh = FileHandle(forWritingAtPath: "/tmp/notchcove.log") {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: "/tmp/notchcove.log", contents: data)
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - NotchPanel
// ─────────────────────────────────────────────
public final class NotchPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

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

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
}

// ─────────────────────────────────────────────
// MARK: - CoveHostingView
// ─────────────────────────────────────────────
public final class CoveHostingView: NSHostingView<NotchCoveView> {
    public weak var windowManager: NotchWindowManager?

    public required init(rootView: NotchCoveView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let wm = windowManager else { return super.hitTest(point) }
        let mouseLoc = NSEvent.mouseLocation
        let activeScreenRect = wm.currentScreenActiveRect().insetBy(dx: -15, dy: -15)
        if activeScreenRect.contains(mouseLoc) {
            return super.hitTest(point)
        }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        guard let wm = windowManager else { super.mouseDown(with: event); return }
        let mouseLoc = NSEvent.mouseLocation

        if !wm.isExpanded {
            let pillRect = wm.currentScreenActiveRect().insetBy(dx: -15, dy: -15)
            if pillRect.contains(mouseLoc) {
                clog("[HostingView] mouseDown on pill -> expand()")
                wm.expand()
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Drag & Drop
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        clog("[HostingView] draggingEntered")
        DispatchQueue.main.async { self.windowManager?.expand() }
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        clog("[HostingView] draggingExited")
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = extractURLs(from: sender.draggingPasteboard)
        clog("[HostingView] performDragOperation: \(urls.count) URLs")
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async {
            for url in urls { CoveEngine.shared.stage(url: url) }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            self.windowManager?.refreshView()
        }
        return true
    }
}

// ─────────────────────────────────────────────
// MARK: - URL Extraction
// ─────────────────────────────────────────────
func extractURLs(from pasteboard: NSPasteboard) -> [URL] {
    var result: [URL] = []
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
        result.append(contentsOf: urls)
    }
    if result.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
        result.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
    }
    if result.isEmpty, let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
        for s in strings {
            if s.hasPrefix("file://"), let url = URL(string: s) { result.append(url) }
            else if s.hasPrefix("/") { result.append(URL(fileURLWithPath: s)) }
        }
    }
    return result
}

// ─────────────────────────────────────────────
// MARK: - NotchWindowManager
// ─────────────────────────────────────────────
@MainActor
public final class NotchWindowManager: NSObject, ObservableObject {
    public static let shared = NotchWindowManager()

    private var panel: NotchPanel?
    private var hostingView: CoveHostingView?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var globalDragMonitor: Any?
    private var hasSetup = false

    private let canvasWidth: CGFloat = 640
    private let canvasHeight: CGFloat = 200

    @Published public var isExpanded: Bool = false

    public var currentMetrics: NotchMetrics = .current()

    // ── Setup ──────────────────────────────
    public func setup() {
        guard !hasSetup else {
            clog("[Setup] Already set up, skipping duplicate call")
            return
        }
        hasSetup = true

        currentMetrics = NotchMetrics.current()

        let canvasX = (currentMetrics.screenFrame.width - canvasWidth) / 2.0 + currentMetrics.screenFrame.origin.x
        let canvasY = currentMetrics.screenFrame.maxY - canvasHeight
        let windowRect = NSRect(x: canvasX, y: canvasY, width: canvasWidth, height: canvasHeight)

        let panel = NotchPanel(contentRect: windowRect)
        self.panel = panel

        let rootView = NotchCoveView(
            metrics: currentMetrics,
            isExpanded: false
        )

        let hostingView = CoveHostingView(rootView: rootView)
        hostingView.windowManager = self
        hostingView.frame = NSRect(origin: .zero, size: windowRect.size)
        hostingView.autoresizingMask = [.width, .height]
        self.hostingView = hostingView

        panel.contentView = hostingView
        panel.orderFrontRegardless()

        setupEventMonitors()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        clog("[Setup] Complete. Window: \(windowRect), Pill: (\(currentMetrics.x), \(currentMetrics.y), \(currentMetrics.width), \(currentMetrics.height)), topInset: \(currentMetrics.topInset)")
    }

    // ── Force push state to SwiftUI ───────
    public func refreshView() {
        let view = NotchCoveView(
            metrics: currentMetrics,
            isExpanded: isExpanded
        )
        hostingView?.rootView = view
        clog("[WM] refreshView -> isExpanded=\(isExpanded)")
    }

    // ── Event Monitors ────────────────────
    private func setupEventMonitors() {
        let trusted = AXIsProcessTrusted()
        clog("[Setup] AXIsProcessTrusted: \(trusted)")
        if !trusted {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }

        // Global: clicks in OTHER apps
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            DispatchQueue.main.async {
                if self.isExpanded {
                    let activeRect = self.currentScreenActiveRect().insetBy(dx: -10, dy: -10)
                    if !activeRect.contains(loc) {
                        clog("[GlobalMonitor] Click outside -> collapse")
                        self.collapse()
                    }
                }
            }
        }

        // Local: clicks in OUR window
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            let loc = NSEvent.mouseLocation
            clog("[LocalMonitor] click at \(loc), isExpanded=\(self.isExpanded)")
            return event
        }

        // Global drag: detect file drags approaching top-center
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            guard let self = self else { return }
            let loc = NSEvent.mouseLocation
            let screen = self.currentMetrics.screenFrame
            let triggerRect = NSRect(
                x: (screen.width - 500) / 2.0 + screen.origin.x,
                y: screen.maxY - 140,
                width: 500,
                height: 140
            )
            if triggerRect.contains(loc) && !self.isExpanded {
                clog("[GlobalDragMonitor] Drag near top -> expand")
                DispatchQueue.main.async { self.expand() }
            }
        }
    }

    @objc private func screenParametersChanged() {
        currentMetrics = NotchMetrics.current()
        guard let panel = panel else { return }
        let canvasX = (currentMetrics.screenFrame.width - canvasWidth) / 2.0 + currentMetrics.screenFrame.origin.x
        let canvasY = currentMetrics.screenFrame.maxY - canvasHeight
        panel.setFrame(NSRect(x: canvasX, y: canvasY, width: canvasWidth, height: canvasHeight), display: true)
        refreshView()
    }

    // ── Active Rect (screen coordinates) ──
    public func currentScreenActiveRect() -> NSRect {
        let screen = currentMetrics.screenFrame
        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if isExpanded {
            let itemCount = CoveEngine.shared.items.count
            targetWidth = max(460, CGFloat(itemCount * 90 + 160))
            targetHeight = 145 + currentMetrics.topInset
        } else {
            targetWidth = currentMetrics.width
            targetHeight = currentMetrics.height
        }

        let x = (screen.width - targetWidth) / 2.0 + screen.origin.x
        // For non-notch: pill is below menu bar, so y = visibleFrame.maxY - pillHeight
        let y: CGFloat
        if isExpanded {
            y = screen.maxY - targetHeight
        } else {
            y = currentMetrics.y
        }

        return NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
    }

    // ── Expand / Collapse ─────────────────
    public func expand() {
        guard !isExpanded else { return }
        isExpanded = true
        refreshView()
        panel?.makeKey()
        clog("[WM] expand() done")
    }

    public func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        refreshView()
        clog("[WM] collapse() done")
    }

    public func toggleExpanded() {
        if isExpanded { collapse() } else { expand() }
    }
}
