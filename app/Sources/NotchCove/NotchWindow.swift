import AppKit
import Carbon.HIToolbox
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

// MARK: - NotchWindowManager

/// Owns the notch panel and decides when the shelf opens and closes.
@MainActor
final class NotchWindowManager: NSObject, ObservableObject {
    static let shared = NotchWindowManager()

    /// Hover and drag opens close when the pointer or drag leaves; click and
    /// hotkey opens are sticky; a peek closes on a timer.
    enum OpenReason {
        case hover, drag, click, hotKey, peek
        var isSticky: Bool { self == .click || self == .hotKey }
    }

    @Published private(set) var isExpanded = false
    @Published private(set) var metrics: NotchMetrics = .current()
    /// Files are being dragged from another app and the shelf is showing its drop zone.
    @Published private(set) var isReceivingDrag = false
    /// The dragged files are over the shelf and would be accepted.
    @Published private(set) var isDropTargeted = false
    @Published private(set) var dropPulse = 0
    @Published var selection: Set<String> = []
    /// Per-card hover state, so a hover change redraws one card, not the whole shelf.
    final class HoverState: ObservableObject {
        @Published var isHovered = false
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

    func hoverState(for id: String) -> HoverState {
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

    @Published private(set) var openStackId: String?
    @Published private(set) var openReason: OpenReason = .hover
    @Published private(set) var theme: ShelfTheme = ThemeChoice.current.theme

    func setTheme(_ choice: ThemeChoice) {
        ThemeChoice.current = choice
        theme = choice.theme
    }

    var isSticky: Bool { openReason.isSticky }

    static let showCountKey = "ShowCountBesideNotch"
    @Published private(set) var showsCountBesideNotch =
        UserDefaults.standard.object(forKey: showCountKey) as? Bool ?? true

    func setShowsCountBesideNotch(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: Self.showCountKey)
        showsCountBesideNotch = show
        if !isExpanded { applyFrame(animatedShrink: false) }
    }

    static let alwaysShowVirtualNotchKey = "AlwaysShowVirtualNotch"
    @Published private(set) var alwaysShowsVirtualNotch =
        UserDefaults.standard.bool(forKey: alwaysShowVirtualNotchKey)

    func setAlwaysShowsVirtualNotch(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: Self.alwaysShowVirtualNotchKey)
        alwaysShowsVirtualNotch = show
        if !isExpanded { applyFrame(animatedShrink: false) }
    }

    /// Without a real notch to hide, a black notch in the menu bar looks out of
    /// place, so by default the closed virtual notch tucks away: nothing when
    /// the shelf is empty, a small tab when items are waiting. The top centre
    /// of the screen still opens the shelf.
    var tucksVirtualNotch: Bool { !metrics.hasPhysicalNotch && !alwaysShowsVirtualNotch }

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
    /// in full screen, where a real notch blends into the black top strip. (The
    /// virtual notch isn't shown there, and keeps its count as it slides back in.)
    var collapsedCount: Int {
        showsCountBesideNotch && !(fullScreenActive && metrics.hasPhysicalNotch) ? engine.items.count : 0
    }

    /// A full-screen app is showing on the notch's display.
    @Published private(set) var fullScreenActive = false

    /// Without a real notch there's no black strip to blend into in full
    /// screen, so the closed virtual notch turns invisible and lets clicks
    /// through to the app. Hovering the spot (via the move monitor), file drags
    /// and the hotkey still open the shelf.
    private var hidesCollapsedNotch: Bool { fullScreenActive && !metrics.hasPhysicalNotch }

    /// The closed notch lets clicks through to the menu bar or app below, and
    /// the move monitor watches for hovers instead of the panel.
    private var collapsedPassesThrough: Bool { hidesCollapsedNotch || tucksVirtualNotch }

    private func updateCollapsedVisibility() {
        guard let panel, !isExpanded else { return }
        let hide = hidesCollapsedNotch
        setOnAllSpaces(metrics.hasPhysicalNotch)
        // Pinned to desktops, the panel isn't on full-screen Spaces at all, and
        // stays opaque so it slides in with the desktop.
        panel.alphaValue = hide && !pinnedToDesktops ? 0 : 1
        panel.ignoresMouseEvents = collapsedPassesThrough
        setMoveMonitorActive(collapsedPassesThrough)
    }

    /// The closed virtual notch lives on desktop Spaces only, so a Space switch
    /// carries it in and out with the desktop (see `Spaces.pin`). The open
    /// shelf and a real notch are on every Space.
    private var pinnedToDesktops = false

    private func setOnAllSpaces(_ all: Bool) {
        guard let panel else { return }
        if all {
            guard !panel.collectionBehavior.contains(.canJoinAllSpaces) else { return }
            panel.collectionBehavior.insert(.canJoinAllSpaces)
            panel.orderFrontRegardless()
            pinnedToDesktops = false
        } else if let screen = NotchMetrics.hostScreen {
            pinnedToDesktops = Spaces.pin(panel, toDesktopsOn: screen)
        }
    }
    private var fullScreenChecks: [DispatchWorkItem] = []

    private var panel: NotchPanel?
    private var monitors: [Any] = []
    /// System-wide pointer monitor, installed only while the shelf is open.
    private var moveMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var hoverOpenWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var resizeWork: DispatchWorkItem?
    private let dragPasteboard = NSPasteboard(name: .drag)
    /// Drag pasteboard contents already seen, so a non-file drag is checked only once.
    private lazy var ignoredDragChangeCount = dragPasteboard.changeCount
    private var externalDragInProgress = false
    private var menuIsTracking = false
    /// After closing with the pointer still on the notch, don't reopen until it leaves.
    private var hoverSuppressedUntilExit = false

    private let engine = CoveEngine.shared
    static let openAnimation = Animation.spring(response: 0.38, dampingFraction: 0.78)
    static let closeAnimation = Animation.spring(response: 0.3, dampingFraction: 0.9)

    // MARK: Setup

    func setup() {
        guard panel == nil else { return }
        metrics = .current()

        let panel = NotchPanel(contentRect: collapsedFrame)
        let hosting = CoveHostingView(rootView: NotchRootView())
        hosting.frame = NSRect(origin: .zero, size: collapsedFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel

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
        // Catches desktops added since the panel was last pinned.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.updateCollapsedVisibility() }
            .store(in: &cancellables)
        updateFullScreen()

        clog("[Setup] notch=\(metrics.hasPhysicalNotch) size=\(metrics.notchWidth)x\(metrics.notchHeight)")
    }

    func setShelfSize(_ size: ShelfSize) {
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
        let active = Spaces.isFullScreen(on: screen)
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
    var interactiveRect: NSRect {
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

    /// Resting the pointer here opens a closed shelf.
    private var hoverOpenRect: NSRect {
        let rect = collapsedFrame.insetBy(dx: -4, dy: -2)
        // Invisible in full screen: only the very top edge, so the app's own
        // toolbar underneath (tabs, address bar) stays usable.
        guard hidesCollapsedNotch else { return rect }
        return NSRect(x: rect.minX, y: metrics.screenFrame.maxY - 3, width: rect.width, height: 5)
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
                self.updateCollapsedVisibility()
            }
            resizeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else {
            panel.setFrame(collapsedFrame, display: true)
            updateCollapsedVisibility()
        }
    }

    // MARK: Open / close

    func expand(_ reason: OpenReason) {
        cancelPending()
        if isExpanded {
            // Upgrade to a sticky open, never downgrade.
            if reason.isSticky {
                openReason = reason
                takeKeyFocus()
            }
            return
        }
        engine.pruneMissing()
        openReason = reason
        // Grow the (transparent) window first, then animate the shelf inside it.
        resizeWork?.cancel()
        setOnAllSpaces(true)
        panel?.alphaValue = 1
        panel?.ignoresMouseEvents = false
        panel?.setFrame(expandedFrame, display: true)
        if reason.isSticky { takeKeyFocus() }
        withAnimation(Self.openAnimation) { isExpanded = true }
        setMoveMonitorActive(true)
    }

    func collapse() {
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
        setMoveMonitorActive(collapsedPassesThrough)
        hoverSuppressedUntilExit = hoverOpenRect.contains(NSEvent.mouseLocation)
        relinquishKeyFocus()
        applyFrame(animatedShrink: true)
    }

    func toggleFromHotKey() {
        isExpanded && isSticky ? collapse() : expand(.hotKey)
    }

    /// App that was frontmost before we took keyboard focus, to hand it back on close.
    private var previousApp: NSRunningApplication?

    /// Opened on purpose (hotkey, click): become the active app so keys like ⌘V,
    /// Space and Esc reach the shelf. Hover and drags never steal focus.
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
        cancelHoverOpen()
        cancelCollapse()
    }

    private func cancelHoverOpen() {
        hoverOpenWork?.cancel()
        hoverOpenWork = nil
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
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
            if self.hoverOpenRect.contains(NSEvent.mouseLocation),
               NSEvent.pressedMouseButtons == 0 {
                self.expand(.hover)
            }
        }
        hoverOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Something (a menu, Quick Look, a drag out) is using the shelf, so it must stay put.
    var isBusy: Bool {
        menuIsTracking || ItemActions.isSharing || QuickLookController.shared.isVisible
            || DragOutCoordinator.shared.isDragging
    }

    // MARK: Pointer tracking

    private func installMonitors() {
        // Only clicks are monitored system-wide (no Accessibility permission needed):
        // moves use a tracking area (plus moveMonitor while open), drags are polled.
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
                    // Take focus back before the click lands: SwiftUI buttons
                    // ignore clicks in a window that isn't key.
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
            ignoredDragChangeCount = dragPasteboard.changeCount
            if isExpanded, !keepOpenRect.contains(loc), !isBusy { collapse() }
            if event.type == .leftMouseDown { startDragPolling() }
        default:
            break
        }
    }

    private func evaluatePointer(_ loc: NSPoint) {
        guard !isBusy, !externalDragInProgress else { return }
        if !isExpanded {
            if hoverOpenRect.contains(loc) {
                // A held button means a text selection or window drag passing by, not a hover.
                if !hoverSuppressedUntilExit, NSEvent.pressedMouseButtons == 0 { scheduleHoverOpen() }
            } else {
                hoverSuppressedUntilExit = false
                cancelHoverOpen()
            }
        } else if openReason == .peek {
            // A peek closes on its own timer; reaching for it turns it into a hover open.
            if keepOpenRect.contains(loc) {
                openReason = .hover
                cancelCollapse()
            }
        } else if !isSticky {
            if keepOpenRect.contains(loc) {
                cancelCollapse()
            } else {
                scheduleCollapse(after: 0.3)
            }
        }
    }

    /// Another app is dragging something: open the shelf as it nears the notch.
    private func handleExternalDrag(at loc: NSPoint) {
        guard !DragOutCoordinator.shared.isDragging else { return }
        let openOnDragStart = DragOpenMode.current == .dragStart
        // In "near the notch" mode most drags happen far away; skip the pasteboard for them.
        guard externalDragInProgress || isExpanded || openOnDragStart || dragWatchRect.contains(loc) else { return }
        if !externalDragInProgress {
            // Only a real drag session changes the drag pasteboard; window moves and text selection don't.
            let changeCount = dragPasteboard.changeCount
            guard changeCount != ignoredDragChangeCount else { return }
            guard DropIngest.canAccept(dragPasteboard) else {
                ignoredDragChangeCount = changeCount
                return
            }
            externalDragInProgress = true
        }

        let near = openOnDragStart || metrics.dragMagnetRect.contains(loc) || (isExpanded && keepOpenRect.contains(loc))
        if near {
            showDropZone()
        } else if isExpanded, !isSticky {
            scheduleCollapse(after: 0.35)
        } else if isReceivingDrag {
            withAnimation(Self.closeAnimation) { isReceivingDrag = false }
        }
    }

    private func showDropZone() {
        cancelCollapse()
        if !isExpanded { expand(.drag) }
        if !isReceivingDrag { withAnimation(Self.openAnimation) { isReceivingDrag = true } }
    }

    // MARK: Drop destination callbacks

    /// Returns whether a drop at `point` would land on the shelf.
    func dropHovered(at point: NSPoint) -> Bool {
        externalDragInProgress = true
        showDropZone()
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
            cancelCollapse()
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
    var displayedCards: [ShelfStack] {
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

    var selectedItems: [StagedItem] {
        displayedCards.filter { selection.contains($0.id) }.flatMap(\.items)
    }

    func openStack(_ id: String?) {
        withAnimation(Self.openAnimation) {
            openStackId = id
            selection = []
        }
    }

    func closeStack() { openStack(nil) }

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

        switch (Int(event.keyCode), flags) {
        case (kVK_Escape, []):
            if openStackId != nil { closeStack() } else { collapse() }
        case (kVK_Space, []):
            let items = selectedItems.isEmpty ? cards.first?.items ?? [] : selectedItems
            ItemActions.quickLook(items)
        case (kVK_Return, []), (kVK_DownArrow, [.command]):
            if selection.count == 1, let card = cards.first(where: { selection.contains($0.id) }), card.isStack {
                openStack(card.id)
            } else {
                ItemActions.open(selectedItems)
            }
        case (kVK_Delete, []), (kVK_ForwardDelete, []), (kVK_Delete, [.command]):
            guard !selection.isEmpty else { return false }
            ItemActions.remove(selectedItems)
        case (kVK_LeftArrow, []), (kVK_RightArrow, []):
            moveSelection(by: Int(event.keyCode) == kVK_LeftArrow ? -1 : 1, in: cards)
        case (kVK_UpArrow, [.command]):
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
