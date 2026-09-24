import AppKit
import Combine
import Quartz
import SwiftUI

func clog(_ msg: String) {
    #if DEBUG
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(ts)] \(msg)")
    fflush(stdout)
    #endif
}

// MARK: - NotchPanel

public final class NotchPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar + 8
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// Card that received the current mouse-down; gets the drags and mouse-up.
    private weak var trackedCard: CardInteractionView.CardNSView?

    /// Clicks on cards go straight to the card view. Routed through SwiftUI's
    /// hosting view, mouse-downs on embedded AppKit views were sometimes held
    /// back indefinitely, so clicks, double-clicks and drags on cards got lost.
    public override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let card = card(at: event) {
                trackedCard = card
                card.mouseDown(with: event)
                return
            }
        case .leftMouseDragged:
            if let card = trackedCard { card.mouseDragged(with: event); return }
        case .leftMouseUp:
            if let card = trackedCard {
                trackedCard = nil
                card.mouseUp(with: event)
                return
            }
        case .scrollWheel:
            MainActor.assumeIsolated { NotchWindowManager.shared.noteScrolling() }
        case .rightMouseDown:
            if let card = card(at: event) {
                if let menu = card.menu(for: event) {
                    NSMenu.popUpContextMenu(menu, with: event, for: card)
                }
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    private func card(at event: NSEvent) -> CardInteractionView.CardNSView? {
        card(atWindowPoint: event.locationInWindow)
    }

    private func card(atWindowPoint point: NSPoint) -> CardInteractionView.CardNSView? {
        guard let content = contentView else { return nil }
        var view = content.hitTest(content.convert(point, from: nil))
        while let current = view {
            if let card = current as? CardInteractionView.CardNSView { return card }
            view = current.superview
        }
        return nil
    }

    public override func keyDown(with event: NSEvent) {
        if !MainActor.assumeIsolated({ NotchWindowManager.shared.handleKey(event) }) {
            super.keyDown(with: event)
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        MainActor.assumeIsolated { NotchWindowManager.shared.handleKey(event) }
            || super.performKeyEquivalent(with: event)
    }

    // Quick Look responder-chain hooks.
    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.begin(panel) }
    }
    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.end(panel) }
    }
}

// MARK: - Hosting view (drop destination)

public final class CoveHostingView: NSHostingView<NotchRootView> {
    private var manager: NotchWindowManager { MainActor.assumeIsolated { .shared } }

    public required init(rootView: NotchRootView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(DropIngest.draggedTypes)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Hover is detected with a tracking area on this small window rather than a
    // system-wide mouse monitor, so pointer movement elsewhere costs nothing.
    private var hoverArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    // Always call super: SwiftUI's own pointer tracking relies on these, and
    // starving it stops clicks from reaching the cards.
    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { manager.pointerMoved(to: NSEvent.mouseLocation) }
    }
    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        manager.pointerMoved(to: NSEvent.mouseLocation)
    }
    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { manager.pointerMoved(to: NSEvent.mouseLocation) }
    }

    /// Clicks on the transparent shadow margin fall through to nothing rather
    /// than landing on invisible controls.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        let screenPoint = window.convertPoint(toScreen: convert(point, to: nil))
        return manager.interactiveRect.contains(screenPoint) ? super.hitTest(point) : nil
    }

    public override func mouseDown(with event: NSEvent) {
        if !manager.isExpanded {
            manager.expand(.click)
            return
        }
        super.mouseDown(with: event)
    }

    private func screenPoint(_ info: NSDraggingInfo) -> NSPoint {
        window?.convertPoint(toScreen: info.draggingLocation) ?? NSEvent.mouseLocation
    }

    /// Whether the current drag session carries anything we can take, read
    /// once per session instead of on every draggingUpdated.
    private var acceptCache: (session: Int, accepts: Bool)?

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        // Ignore our own items being dragged back in.
        if info.draggingSource is DragOutCoordinator { return [] }
        if acceptCache?.session != info.draggingSequenceNumber {
            acceptCache = (info.draggingSequenceNumber, DropIngest.canAccept(info.draggingPasteboard))
        }
        guard acceptCache?.accepts == true else { return [] }
        return manager.dropHovered(at: screenPoint(info)) ? .copy : []
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        manager.dropExited()
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !(sender.draggingSource is DragOutCoordinator)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let manager = self.manager
        DropIngest.ingest(sender.draggingPasteboard) { count in
            manager.didReceiveDrop(count: count)
        }
        return true
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        manager.externalDragFinished()
    }
}

// MARK: - NotchWindowManager

/// Owns the notch panel and decides when the shelf opens and closes.
///
/// Why it opens:
/// - `.hover`: pointer rests on the notch. Closes when the pointer leaves.
/// - `.drag`: files dragged toward the notch. Closes when the drag leaves or ends.
/// - `.click` / `.hotKey`: stays open until you click outside, press Esc, or toggle.
@MainActor
public final class NotchWindowManager: NSObject, ObservableObject {
    public static let shared = NotchWindowManager()

    public enum OpenReason { case hover, drag, click, hotKey, peek }

    @Published public private(set) var isExpanded = false
    @Published public private(set) var metrics: NotchMetrics = .current()
    /// Files are being dragged from another app and the shelf is showing its drop zone.
    @Published public private(set) var isReceivingDrag = false
    /// The dragged files are over the shelf and would be accepted.
    @Published public private(set) var isDropTargeted = false
    @Published public private(set) var dropPulse = 0
    @Published public var selection: Set<String> = []
    /// Per-card hover state, so a hover change redraws one card, not the whole shelf.
    public final class HoverState: ObservableObject {
        @Published public var isHovered = false
    }
    private var hoverStates: [String: HoverState] = [:]
    private var hoveredCardId: String?
    private var isScrolling = false
    private var scrollEndWork: DispatchWorkItem?

    /// Called for every scroll-wheel event on the shelf. Hover effects pause
    /// while scrolling and come back for the card under the pointer afterwards.
    func noteScrolling() {
        if !isScrolling {
            isScrolling = true
            setHovered(hoveredCardId, false)
        }
        scrollEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isScrolling = false
            if let card = CardInteractionView.CardNSView.visibleCard(atScreenPoint: NSEvent.mouseLocation)?.card {
                self.setHovered(card.id, true)
            }
        }
        scrollEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    public func hoverState(for id: String) -> HoverState {
        if let state = hoverStates[id] { return state }
        let state = HoverState()
        hoverStates[id] = state
        return state
    }

    func setHovered(_ id: String?, _ hovered: Bool) {
        // Cards sliding under a still pointer would flip hover many times a second.
        if hovered, isScrolling { return }
        let previous = hoveredCardId
        if hovered {
            guard previous != id else { return }
            hoveredCardId = id
        } else {
            guard previous == id, id != nil else { return }
            hoveredCardId = nil
        }
        // Record first, publish on the next turn: publishing re-lays out SwiftUI,
        // which updates tracking areas and can fire enter/exit straight back here.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for key in [previous, id].compactMap({ $0 }) {
                let shouldHover = self.hoveredCardId == key
                let state = self.hoverState(for: key)
                if state.isHovered != shouldHover { state.isHovered = shouldHover }
            }
        }
    }

    @Published public private(set) var openStackId: String?
    @Published public private(set) var openReason: OpenReason = .hover
    @Published private(set) var theme: ShelfTheme = ThemeChoice.current.theme

    func setTheme(_ choice: ThemeChoice) {
        ThemeChoice.current = choice
        theme = choice.theme
    }

    public var isSticky: Bool { openReason == .click || openReason == .hotKey }

    /// Show the item count beside the closed notch.
    static let showCountKey = "ShowCountBesideNotch"
    @Published private(set) var showsCountBesideNotch =
        UserDefaults.standard.object(forKey: showCountKey) as? Bool ?? true

    func setShowsCountBesideNotch(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: Self.showCountKey)
        showsCountBesideNotch = show
        if !isExpanded { applyFrame(animatedShrink: false) }
    }

    /// Cards being removed, by id: false while the poof is drawn small, true once it bursts.
    @Published private(set) var poofs: [String: Bool] = [:]

    /// Removes `items` from the shelf, playing a poof over their cards first
    /// when the shelf is open (the removal lands once the poof has played).
    func poofThenRemove(_ items: [StagedItem], clearAll: Bool = false) {
        let itemIds = Set(items.map(\.id))
        let cardIds = isExpanded
            ? displayedCards.filter { $0.items.contains { itemIds.contains($0.id) } }.map(\.id)
            : []
        let finish = { [weak self] in
            if clearAll { CoveEngine.shared.clearAll() } else { CoveEngine.shared.remove(ids: Array(itemIds)) }
            self?.itemsRemoved()
        }
        guard !cardIds.isEmpty else { return finish() }

        for id in cardIds { poofs[id] = false }
        DispatchQueue.main.async { [weak self] in
            withAnimation(.easeOut(duration: 0.4)) {
                for id in cardIds where self?.poofs[id] != nil { self?.poofs[id] = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            for id in cardIds { self?.poofs[id] = nil }
            finish()
        }
    }

    /// Items the closed notch shows a count for: none when the count is off, or
    /// in full screen, where the plain notch blends into the black top strip.
    var collapsedCount: Int { showsCountBesideNotch && !fullScreenActive ? engine.items.count : 0 }

    /// A full-screen app is showing on the notch's display.
    @Published private(set) var fullScreenActive = false
    private var fullScreenChecks: [DispatchWorkItem] = []

    private var panel: NotchPanel?
    private var hostingView: CoveHostingView?
    private var monitors: [Any] = []
    /// System-wide pointer monitor, installed only while the shelf is open.
    private var moveMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var hoverOpenWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var resizeWork: DispatchWorkItem?
    private var dragChangeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    private var externalDragInProgress = false
    private var menuIsTracking = false
    /// After closing with the pointer still on the notch, don't reopen until it leaves.
    private var hoverSuppressedUntilExit = false

    private let engine = CoveEngine.shared
    static let openAnimation = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let closeAnimation = Animation.spring(response: 0.3, dampingFraction: 0.9)

    // MARK: Setup

    public func setup() {
        guard panel == nil else { return }
        metrics = .current()

        let panel = NotchPanel(contentRect: collapsedFrame)
        let hosting = CoveHostingView(rootView: NotchRootView())
        hosting.frame = NSRect(origin: .zero, size: collapsedFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting

        installMonitors()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .sink { [weak self] _ in self?.menuIsTracking = true }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)
            .sink { [weak self] _ in
                self?.menuIsTracking = false
                self?.evaluatePointer(NSEvent.mouseLocation)
            }
            .store(in: &cancellables)

        // The collapsed badge widens when items appear, so resize with the shelf.
        engine.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                let ids = Set(items.map(\.id)), groups = Set(items.map(\.groupId))
                self.selection = self.selection.filter { ids.contains($0) || groups.contains($0) }
                self.hoverStates = self.hoverStates.filter { ids.contains($0.key) || groups.contains($0.key) }
                if let open = self.openStackId, items.filter({ $0.groupId == open }).count < 2 {
                    self.openStackId = nil
                }
                if !self.isExpanded { self.applyFrame(animatedShrink: false) }
            }
            .store(in: &cancellables)

        // Space switches and app switches are when full screen starts or ends.
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .sink { [weak self] _ in self?.scheduleFullScreenCheck() }
                .store(in: &cancellables)
        }
        updateFullScreen()

        clog("[Setup] notch=\(metrics.hasPhysicalNotch) size=\(metrics.notchWidth)x\(metrics.notchHeight)")
    }

    /// Applies a new ShelfSize immediately.
    public func setShelfSize(_ size: ShelfSize) {
        ShelfSize.current = size
        screenParametersChanged()
    }

    @objc private func screenParametersChanged() {
        metrics = .current()
        applyFrame(animatedShrink: false)
        scheduleFullScreenCheck()
    }

    // MARK: Full screen

    private func scheduleFullScreenCheck() {
        // The window list settles only after the Space switch animation.
        fullScreenChecks.forEach { $0.cancel() }
        fullScreenChecks = [0.05, 0.5, 1.2].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.updateFullScreen() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func updateFullScreen() {
        guard let screen = NotchMetrics.hostScreen else { return }
        let active = FullScreenDetector.isActive(on: screen)
        guard active != fullScreenActive else { return }
        fullScreenActive = active
        clog("[FullScreen] \(active)")
        if !isExpanded { applyFrame(animatedShrink: false) }
    }

    // MARK: Geometry

    private var collapsedFrame: NSRect { metrics.collapsedRect(itemCount: collapsedCount) }

    private var expandedFrame: NSRect {
        let shelf = metrics.shelfRect, m = NotchMetrics.shadowMargin
        return NSRect(x: shelf.minX - m, y: shelf.minY - m, width: shelf.width + 2 * m, height: shelf.height + m)
    }

    /// Screen area that responds to the pointer right now.
    public var interactiveRect: NSRect {
        (isExpanded ? metrics.shelfRect : collapsedFrame).insetBy(dx: 0, dy: -2)
    }

    /// Drags inside this band get checked for files; the magnet zone sits inside it.
    private var dragWatchRect: NSRect {
        metrics.dragMagnetRect.insetBy(dx: -120, dy: -120)
    }

    /// Area the pointer may wander in before an open shelf closes.
    private var keepOpenRect: NSRect {
        metrics.shelfRect.insetBy(dx: -14, dy: -14)
    }

    private func applyFrame(animatedShrink: Bool) {
        guard let panel else { return }
        resizeWork?.cancel()
        if isExpanded {
            panel.setFrame(expandedFrame, display: true)
        } else if animatedShrink {
            // Let SwiftUI finish the closing animation before shrinking the window.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isExpanded else { return }
                self.panel?.setFrame(self.collapsedFrame, display: true)
            }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else {
            panel.setFrame(collapsedFrame, display: true)
        }
    }

    // MARK: Open / close

    public func expand(_ reason: OpenReason) {
        cancelPending()
        if isExpanded {
            // Upgrade to a sticky open, never downgrade.
            if reason == .click || reason == .hotKey {
                openReason = reason
                takeKeyFocus()
            }
            return
        }
        engine.pruneMissing()
        openReason = reason
        // Grow the (transparent) window first, then animate the shelf inside it.
        resizeWork?.cancel()
        panel?.setFrame(expandedFrame, display: true)
        if reason == .click || reason == .hotKey { takeKeyFocus() }
        withAnimation(Self.openAnimation) { isExpanded = true }
        setMoveMonitorActive(true)
    }

    public func collapse() {
        cancelPending()
        guard isExpanded else { return }
        if QuickLookController.shared.isVisible { QLPreviewPanel.shared().orderOut(nil) }
        withAnimation(Self.closeAnimation) {
            isExpanded = false
            isReceivingDrag = false
            isDropTargeted = false
            openStackId = nil
        }
        selection = []
        setHovered(hoveredCardId, false)
        setMoveMonitorActive(false)
        hoverSuppressedUntilExit = collapsedFrame.insetBy(dx: -4, dy: -2).contains(NSEvent.mouseLocation)
        relinquishKeyFocus()
        applyFrame(animatedShrink: true)
    }

    public func toggleFromHotKey() {
        isExpanded && isSticky ? collapse() : expand(.hotKey)
    }

    /// App that was frontmost before we took keyboard focus, to hand it back on close.
    private var previousApp: NSRunningApplication?

    /// Opened on purpose (hotkey, click): become the active app so keys like
    /// ⌘V, Space and Esc reach the shelf instead of the app in front (e.g. a
    /// full-screen editor). Hover and drags never do this, so they never steal focus.
    func takeKeyFocus() {
        if !NSApp.isActive {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
            NSApp.activate()
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func relinquishKeyFocus() {
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        } else if let panel, panel.isKeyWindow {
            // A non-activating panel can hold keyboard focus; give it up.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        previousApp = nil
    }

    private func cancelPending() {
        hoverOpenWork?.cancel(); hoverOpenWork = nil
        collapseWork?.cancel(); collapseWork = nil
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        guard collapseWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            self.collapse()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleHoverOpen() {
        guard hoverOpenWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverOpenWork = nil
            if self.collapsedFrame.insetBy(dx: -4, dy: -2).contains(NSEvent.mouseLocation),
               NSEvent.pressedMouseButtons == 0 {
                self.expand(.hover)
            }
        }
        hoverOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Something (a menu, Quick Look, a drag out) is using the shelf, so it must stay put.
    private var isBusy: Bool {
        menuIsTracking || ItemActions.isSharing || QuickLookController.shared.isVisible
            || DragOutCoordinator.shared.isDragging
    }

    // MARK: Pointer tracking

    private func installMonitors() {
        // Mouse monitors don't need Accessibility permission. Only clicks are
        // monitored system-wide: pointer movement uses a tracking area (plus
        // moveMonitor while open), and drags are sampled by dragPollTimer, so
        // high-frequency event streams never reach this process.
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobal(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .mouseMoved {
                    self.evaluatePointer(NSEvent.mouseLocation)
                } else if event.type == .leftMouseDown, event.window === self.panel, self.isExpanded {
                    // Clicking into the shelf keeps it open until you click elsewhere.
                    if !self.isSticky { self.openReason = .click }
                    // Take focus back before the click lands (e.g. after using
                    // another app): SwiftUI buttons ignore clicks in a window that
                    // isn't key.
                    if !self.isSticky || self.panel?.isKeyWindow == false { self.takeKeyFocus() }
                }
            }
            return event
        }
        monitors = [global, local].compactMap { $0 }
    }

    /// While the button is held, sample the pointer ~30×/s to spot a file drag
    /// heading for the notch. Stops as soon as the button is released.
    private var dragPollTimer: Timer?

    private func startDragPolling() {
        guard dragPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDrag() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        dragPollTimer = timer
    }

    private func pollDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            dragPollTimer?.invalidate()
            dragPollTimer = nil
            if externalDragInProgress { externalDragFinished() }
            return
        }
        handleExternalDrag(at: NSEvent.mouseLocation)
    }

    private func setMoveMonitorActive(_ active: Bool) {
        if active, moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated { self?.handleGlobal(event) }
            }
        } else if !active, let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
    }

    /// Pointer moved over the notch window (tracking area) or, while open, anywhere.
    func pointerMoved(to loc: NSPoint) {
        // No button is down, so any drag has finished.
        if externalDragInProgress, NSEvent.pressedMouseButtons == 0 { externalDragFinished() }
        evaluatePointer(loc)
    }

    private func handleGlobal(_ event: NSEvent) {
        let loc = NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            pointerMoved(to: loc)
        case .leftMouseDown, .rightMouseDown:
            if externalDragInProgress { externalDragFinished() }
            dragChangeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
            if isExpanded, !keepOpenRect.contains(loc), !isBusy { collapse() }
            if event.type == .leftMouseDown { startDragPolling() }
        default:
            break
        }
    }

    private func evaluatePointer(_ loc: NSPoint) {
        guard !isBusy, !externalDragInProgress else { return }
        if !isExpanded {
            if collapsedFrame.insetBy(dx: -4, dy: -2).contains(loc) {
                // A held button means a text selection or window drag passing by, not a hover.
                if !hoverSuppressedUntilExit, NSEvent.pressedMouseButtons == 0 { scheduleHoverOpen() }
            } else {
                hoverSuppressedUntilExit = false
                hoverOpenWork?.cancel(); hoverOpenWork = nil
            }
        } else if openReason == .peek {
            // A peek closes on its own timer; reaching for it turns it into a hover open.
            if keepOpenRect.contains(loc) {
                openReason = .hover
                collapseWork?.cancel(); collapseWork = nil
            }
        } else if !isSticky {
            if keepOpenRect.contains(loc) {
                collapseWork?.cancel(); collapseWork = nil
            } else {
                scheduleCollapse(after: 0.3)
            }
        }
    }

    /// Another app is dragging something: open the shelf as it nears the notch.
    private func handleExternalDrag(at loc: NSPoint) {
        guard !DragOutCoordinator.shared.isDragging else { return }
        let openOnDragStart = DragOpenMode.current == .dragStart
        // In "near the notch" mode most drags happen far away; don't touch the
        // pasteboard server for them. (This only runs while the button is held.)
        guard externalDragInProgress || isExpanded || openOnDragStart || dragWatchRect.contains(loc) else { return }
        let pasteboard = NSPasteboard(name: .drag)
        if !externalDragInProgress {
            // Only a real drag session changes the drag pasteboard; window moves and
            // text selection don't, so they never trigger the shelf.
            guard pasteboard.changeCount != dragChangeCountAtMouseDown, DropIngest.canAccept(pasteboard) else { return }
            externalDragInProgress = true
        }

        let near = openOnDragStart || metrics.dragMagnetRect.contains(loc) || (isExpanded && keepOpenRect.contains(loc))
        if near {
            collapseWork?.cancel(); collapseWork = nil
            if !isExpanded { expand(.drag) }
            if !isReceivingDrag { withAnimation(Self.openAnimation) { isReceivingDrag = true } }
        } else if isExpanded, !isSticky {
            scheduleCollapse(after: 0.35)
        } else if isReceivingDrag {
            withAnimation(Self.closeAnimation) { isReceivingDrag = false }
        }
    }

    // MARK: Drop destination callbacks

    /// Returns whether a drop at `point` would land on the shelf.
    func dropHovered(at point: NSPoint) -> Bool {
        externalDragInProgress = true
        collapseWork?.cancel(); collapseWork = nil
        if !isExpanded { expand(.drag) }
        if !isReceivingDrag { withAnimation(Self.openAnimation) { isReceivingDrag = true } }
        let targeted = metrics.shelfRect.contains(point)
        if targeted != isDropTargeted {
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
            if targeted { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        return targeted
    }

    func dropExited() {
        if isDropTargeted { withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = false } }
        // Opened at drag start: stay up for the whole drag; closes when it ends.
        if DragOpenMode.current == .dragStart, externalDragInProgress { return }
        if isExpanded, !isSticky, !keepOpenRect.contains(NSEvent.mouseLocation) {
            scheduleCollapse(after: 0.35)
        }
    }

    func didReceiveDrop(count: Int) {
        withAnimation(Self.openAnimation) {
            isDropTargeted = false
            isReceivingDrag = false
            openStackId = nil
            if count > 0 { dropPulse += 1 }
        }
        externalDragInProgress = false
        if count > 0 {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            // Stay open to show what landed; close once the pointer moves away.
            openReason = .hover
        } else {
            NSSound.beep()
        }
    }

    func externalDragFinished() {
        guard externalDragInProgress || isReceivingDrag else { return }
        externalDragInProgress = false
        withAnimation(Self.closeAnimation) {
            isReceivingDrag = false
            isDropTargeted = false
        }
        if isExpanded, openReason == .drag, !keepOpenRect.contains(NSEvent.mouseLocation) {
            scheduleCollapse(after: 0.2)
        }
    }

    // MARK: Drag-out callbacks

    func dragOutBegan() {
        cancelPending()
    }

    func dragOutMoved(to point: NSPoint) {
        // Get out of the way once the drag leaves, so you can drop onto whatever is underneath.
        if isExpanded, !keepOpenRect.contains(point) {
            scheduleCollapse(after: 0.25)
        } else {
            collapseWork?.cancel(); collapseWork = nil
        }
    }

    func dragOutEnded(at point: NSPoint) {
        if engine.items.isEmpty || !keepOpenRect.contains(point) {
            collapse()
        }
    }

    /// Something new landed on the shelf by itself (a screenshot): show it
    /// briefly without taking focus. Hovering the shelf keeps it open.
    func peek() {
        dropPulse += 1
        guard !isExpanded, !isBusy, !externalDragInProgress else { return }
        expand(.peek)
        scheduleCollapse(after: 2.5)
    }

    func itemsRemoved() {
        if engine.items.isEmpty, !isSticky { collapse() }
    }

    // MARK: Stacks & selection

    /// What the shelf shows: stacks, or the files of the open stack.
    public var displayedCards: [ShelfStack] {
        if let cached = cardsCache, cached.revision == engine.revision, cached.openStackId == openStackId {
            return cached.cards
        }
        let stacks = engine.stacks
        var cards = stacks
        if let openStackId, let stack = stacks.first(where: { $0.id == openStackId }) {
            cards = stack.items.map { ShelfStack(id: $0.id, items: [$0]) }
        }
        cardsCache = (engine.revision, openStackId, cards)
        return cards
    }
    private var cardsCache: (revision: Int, openStackId: String?, cards: [ShelfStack])?

    public var selectedItems: [StagedItem] {
        displayedCards.filter { selection.contains($0.id) }.flatMap(\.items)
    }

    public func openStack(_ id: String) {
        withAnimation(Self.openAnimation) {
            openStackId = id
            selection = []
        }
    }

    public func closeStack() {
        withAnimation(Self.openAnimation) {
            openStackId = nil
            selection = []
        }
    }

    func extendSelection(to id: String) {
        let ids = displayedCards.map(\.id)
        guard let target = ids.firstIndex(of: id) else { return }
        let anchor = ids.firstIndex { selection.contains($0) } ?? target
        selection = Set(ids[min(anchor, target)...max(anchor, target)])
    }

    // MARK: Keyboard

    /// Handles shelf shortcuts while the panel is key. Returns true when consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isExpanded, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased()
        let cards = displayedCards

        switch (event.keyCode, flags) {
        case (53, []): // Esc
            if openStackId != nil { closeStack() } else { collapse() }
        case (49, []): // Space
            let items = selectedItems.isEmpty ? cards.first?.items ?? [] : selectedItems
            ItemActions.quickLook(items)
        case (36, []), (125, [.command]): // Return, ⌘↓
            if selection.count == 1, let card = cards.first(where: { selection.contains($0.id) }), card.isStack {
                openStack(card.id)
            } else {
                ItemActions.open(selectedItems)
            }
        case (51, []), (117, []), (51, [.command]): // Delete, Forward delete, ⌘⌫
            guard !selection.isEmpty else { return false }
            ItemActions.remove(selectedItems)
        case (123, []), (124, []): // ← →
            moveSelection(by: event.keyCode == 123 ? -1 : 1, in: cards)
        case (126, [.command]): // ⌘↑
            if openStackId != nil { closeStack() }
        default:
            switch (chars, flags) {
            case ("a", [.command]): selection = Set(cards.map(\.id))
            case ("c", [.command]): ItemActions.copyFiles(selectedItems)
            case ("v", [.command]):
                DropIngest.ingest(.general) { [weak self] count in self?.didReceiveDrop(count: count) }
            case ("o", [.command]): ItemActions.open(selectedItems)
            case ("r", [.command]): ItemActions.reveal(selectedItems)
            case ("w", [.command]): collapse()
            default: return false
            }
        }
        return true
    }

    private func moveSelection(by delta: Int, in cards: [ShelfStack]) {
        guard !cards.isEmpty else { return }
        let current = cards.lastIndex { selection.contains($0.id) }
        let next = current.map { min(max($0 + delta, 0), cards.count - 1) } ?? (delta > 0 ? 0 : cards.count - 1)
        selection = [cards[next].id]
    }
}
