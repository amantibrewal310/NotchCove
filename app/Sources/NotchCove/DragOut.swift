import AppKit
import SwiftUI

/// Long-lived drag source, so a drag survives the shelf collapsing underneath it.
@MainActor
final class DragOutCoordinator: NSObject, NSDraggingSource {
    static let shared = DragOutCoordinator()

    private var draggedItems: [StagedItem] = []
    private(set) var isDragging = false

    /// Keep items on the shelf after they're dropped somewhere.
    static var keepItems: Bool {
        get { UserDefaults.standard.bool(forKey: "keepItemsAfterDragOut") }
        set { UserDefaults.standard.set(newValue, forKey: "keepItemsAfterDragOut") }
    }

    func beginDrag(items: [StagedItem], from view: NSView, event: NSEvent) {
        guard !items.isEmpty else { return }
        let start = view.convert(event.locationInWindow, from: nil)
        let iconSize: CGFloat = 56
        // The size cards cache thumbnails at, so the drag images are cache hits.
        let thumbSize = NotchWindowManager.shared.metrics.cardThumbnailSize

        let dragItems: [NSDraggingItem] = items.enumerated().map { index, item in
            let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            // Fan the first few, stack the rest underneath.
            let offset = CGFloat(min(index, 4)) * 5
            let frame = NSRect(
                x: start.x - iconSize / 2 + offset,
                y: start.y - iconSize / 2 - offset,
                width: iconSize,
                height: iconSize
            )
            dragItem.setDraggingFrame(frame, contents: ThumbnailCache.shared.image(for: item.url, size: thumbSize))
            return dragItem
        }

        draggedItems = items
        isDragging = true
        let session = view.beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = items.count > 1 ? .pile : .none
        NotchWindowManager.shared.dragOutBegan()
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        MainActor.assumeIsolated {
            guard context == .outsideApplication else { return [] }
            // User files copy unless ⌘ is held; NotchCove's own inbox files may move.
            if NSEvent.modifierFlags.contains(.command) { return .move }
            let allOwned = draggedItems.allSatisfy(\.owned)
            return allOwned ? [.copy, .move] : .copy
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated {
            NotchWindowManager.shared.dragOutMoved(to: screenPoint)
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        MainActor.assumeIsolated {
            let items = draggedItems
            draggedItems = []
            isDragging = false

            if operation.contains(.move) {
                // The file now lives elsewhere; forget it without deleting anything.
                CoveEngine.shared.remove(ids: items.map(\.id), deleteOwned: false)
            } else if operation != [] && !Self.keepItems {
                CoveEngine.shared.remove(ids: items.map(\.id))
            }
            CoveEngine.shared.pruneMissing()
            NotchWindowManager.shared.dragOutEnded(at: screenPoint)
        }
    }

    nonisolated func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
}

// MARK: - Card interaction layer

/// Transparent AppKit layer over each card that handles clicking, selecting,
/// double-click to open, dragging out, hover, and the context menu.
struct CardInteractionView: NSViewRepresentable {
    let card: ShelfStack

    func makeNSView(context: Context) -> CardNSView {
        let view = CardNSView()
        view.card = card
        return view
    }

    func updateNSView(_ view: CardNSView, context: Context) {
        view.card = card
    }

    final class CardNSView: NSView {
        // AppKit tooltip: SwiftUI's .help() on these cards could swallow clicks
        // entirely (seen with large stacks), and is costlier to track.
        var card: ShelfStack? {
            didSet { if card?.tooltip != oldValue?.tooltip { toolTip = card?.tooltip } }
        }
        private var mouseDownEvent: NSEvent?
        private var dragStarted = false
        private var mouseDownOnRemove = false
        private var trackingArea: NSTrackingArea?

        private var manager: NotchWindowManager { .shared }

        /// Live card views, for geometry lookups outside of mouse events (where
        /// SwiftUI's hit-testing doesn't return embedded AppKit views).
        private static let live = NSHashTable<CardNSView>.weakObjects()

        static func visibleCard(atScreenPoint point: NSPoint) -> CardNSView? {
            live.allObjects.first { view in
                guard let window = view.window, !view.visibleRect.isEmpty else { return false }
                let rect = window.convertToScreen(view.convert(view.visibleRect, to: nil))
                return rect.contains(point)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { Self.live.add(self) } else { Self.live.remove(self) }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            manager.setHovered(card?.id, true)
        }

        override func mouseExited(with event: NSEvent) {
            manager.setHovered(card?.id, false)
        }

        /// The hover × sits in the card's top-right corner. The card receives all
        /// clicks in its area (see NotchPanel.sendEvent), so it handles the × itself.
        private var removeButtonRect: NSRect {
            NSRect(x: bounds.maxX - 22, y: isFlipped ? 0 : bounds.maxY - 22, width: 22, height: 22)
        }

        private func isOnRemoveButton(_ event: NSEvent) -> Bool {
            guard let card, manager.hoverState(for: card.id).isHovered else { return false }
            return removeButtonRect.contains(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            dragStarted = false
            mouseDownOnRemove = isOnRemoveButton(event)
            manager.takeKeyFocus()
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragStarted, !mouseDownOnRemove, let down = mouseDownEvent, let card else { return }
            let a = down.locationInWindow, b = event.locationInWindow
            guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
            dragStarted = true
            // Dragging a selected card drags the whole selection.
            selectIfNeeded(card)
            DragOutCoordinator.shared.beginDrag(items: manager.selectedItems, from: self, event: down)
        }

        override func mouseUp(with event: NSEvent) {
            defer { mouseDownEvent = nil; mouseDownOnRemove = false }
            guard !dragStarted, let card else { return }
            if mouseDownOnRemove {
                if removeButtonRect.contains(convert(event.locationInWindow, from: nil)) {
                    ItemActions.remove(card.items)
                }
                return
            }
            if event.clickCount >= 2 {
                if card.isStack { manager.openStack(card.id) } else { ItemActions.open(card.items) }
                return
            }
            let flags = event.modifierFlags
            if flags.contains(.command) {
                manager.selection.formSymmetricDifference([card.id])
            } else if flags.contains(.shift) {
                manager.extendSelection(to: card.id)
            } else {
                manager.selection = [card.id]
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let card else { return nil }
            selectIfNeeded(card)
            let stack = manager.selection.count == 1 ? card : nil
            return ItemActions.menu(for: manager.selectedItems, stack: stack, anchor: self)
        }

        private func selectIfNeeded(_ card: ShelfStack) {
            if !manager.selection.contains(card.id) { manager.selection = [card.id] }
        }
    }
}

// MARK: - Drag-all handle

/// Header control that drags every item on the shelf at once.
struct DragAllHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}

    final class HandleView: NSView {
        private var mouseDownEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { mouseDownEvent = event }
        override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent else { return }
            mouseDownEvent = nil
            let manager = NotchWindowManager.shared
            let items = manager.displayedCards.flatMap(\.items)
            manager.selection = Set(manager.displayedCards.map(\.id))
            DragOutCoordinator.shared.beginDrag(items: items, from: self, event: down)
        }
    }
}
