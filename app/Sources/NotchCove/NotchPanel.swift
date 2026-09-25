import AppKit
import Quartz
import SwiftUI

// MARK: - NotchPanel

final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Card that received the current mouse-down; gets the drags and mouse-up.
    private weak var trackedCard: CardInteractionView.CardNSView?

    /// Card clicks go straight to the card view: routed through SwiftUI's hosting
    /// view, mouse-downs on embedded AppKit views were sometimes held back.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let card = view(at: event, as: CardInteractionView.CardNSView.self) {
                trackedCard = card
                card.mouseDown(with: event)
                return
            }
            if let button = view(at: event, as: SettingsButton.ButtonView.self) {
                button.mouseDown(with: event)
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
            if let card = view(at: event, as: CardInteractionView.CardNSView.self) {
                if let menu = card.menu(for: event) {
                    NSMenu.popUpContextMenu(menu, with: event, for: card)
                }
                return
            }
            // Anywhere else on the shelf: the settings, also reachable with the menu bar icon hidden.
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.showSettingsMenu() }
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    private func view<T: NSView>(at event: NSEvent, as type: T.Type) -> T? {
        guard let content = contentView else { return nil }
        // hitTest takes the point in the superview's coordinates.
        var view = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        if !MainActor.assumeIsolated({ NotchWindowManager.shared.handleKey(event) }) {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        MainActor.assumeIsolated { NotchWindowManager.shared.handleKey(event) }
            || super.performKeyEquivalent(with: event)
    }

    // Quick Look responder-chain hooks.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.begin(panel) }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { QuickLookController.shared.end(panel) }
    }
}

// MARK: - Hosting view (drop destination)

final class CoveHostingView: NSHostingView<NotchRootView> {
    private var manager: NotchWindowManager { MainActor.assumeIsolated { .shared } }

    required init(rootView: NotchRootView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(DropIngest.draggedTypes)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A tracking area on this small window, not a system-wide monitor, so
    // pointer movement elsewhere costs nothing.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
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
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { manager.pointerMoved(to: NSEvent.mouseLocation) }
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        manager.pointerMoved(to: NSEvent.mouseLocation)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { manager.pointerMoved(to: NSEvent.mouseLocation) }
    }

    /// Clicks on the transparent shadow margin fall through to nothing rather
    /// than landing on invisible controls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        // `point` is in the superview's coordinates; this view is flipped.
        let screenPoint = window.convertPoint(toScreen: superview?.convert(point, to: nil) ?? point)
        return manager.interactiveRect.contains(screenPoint) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        manager.dropExited()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !(sender.draggingSource is DragOutCoordinator)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let manager = self.manager
        DropIngest.ingest(sender.draggingPasteboard) { count in
            manager.didReceiveDrop(count: count)
        }
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        manager.externalDragFinished()
    }
}

// MARK: - Hot zone

/// Transparent window over the spot that opens the shelf, for when the closed
/// notch is invisible or tucked away and lets clicks through. It takes the
/// pointer's enter, move and exit there, and a click opens the shelf.
final class HotZonePanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Just below the notch panel, on every Space: it draws nothing, so
        // unlike the notch it has nothing to show during a Space switch.
        level = .statusBar + 7
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Set explicitly, so the window takes events over its transparent pixels.
        ignoresMouseEvents = false
        contentView = ZoneView()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class ZoneView: NSView {
        private var area: NSTrackingArea?
        private var manager: NotchWindowManager { MainActor.assumeIsolated { NotchWindowManager.shared } }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            self.area = area
        }

        override func mouseEntered(with event: NSEvent) { manager.pointerMoved(to: NSEvent.mouseLocation) }
        override func mouseMoved(with event: NSEvent) { manager.pointerMoved(to: NSEvent.mouseLocation) }
        override func mouseExited(with event: NSEvent) { manager.pointerMoved(to: NSEvent.mouseLocation) }
        override func mouseDown(with event: NSEvent) { manager.expand(.click) }
        override func rightMouseDown(with event: NSEvent) { manager.expand(.click) }
    }
}
