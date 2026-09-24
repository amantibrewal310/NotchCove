import AppKit
import Quartz

// MARK: - Quick Look

@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var urls: [URL] = []

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle(urls: [URL]) {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        NSApp.activate()
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // Responder-chain hooks, forwarded from NotchPanel and AppDelegate.
    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Space or Escape closes, just like Finder.
        guard event.type == .keyDown, event.keyCode == 49 || event.keyCode == 53 else { return false }
        MainActor.assumeIsolated { panel.orderOut(nil) }
        return true
    }
}

// MARK: - Context menu

final class ShareDelegate: NSObject, NSSharingServicePickerDelegate {
    // Called with nil when the picker is dismissed without a choice.
    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated { ItemActions.shareFinished() }
    }
}

/// NSMenuItem that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func run() { handler() }
}

@MainActor
enum ItemActions {
    private static var sharePicker: NSSharingServicePicker?
    private static let shareDelegate = ShareDelegate()

    /// True while the share picker is on screen, so the shelf stays open under it.
    static var isSharing: Bool { sharePicker != nil }

    static func quickLook(_ items: [StagedItem]) {
        QuickLookController.shared.toggle(urls: items.map(\.url))
    }

    static func open(_ items: [StagedItem]) {
        items.forEach { NSWorkspace.shared.open($0.url) }
    }

    static func reveal(_ items: [StagedItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    static func copyFiles(_ items: [StagedItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
    }

    static func copyPaths(_ items: [StagedItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items.map(\.originalPath).joined(separator: "\n"), forType: .string)
    }

    static func share(_ items: [StagedItem], anchor: NSView?) {
        guard let anchor, anchor.window != nil else { return }
        let picker = NSSharingServicePicker(items: items.map(\.url))
        picker.delegate = shareDelegate
        sharePicker = picker
        NSApp.activate()
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    fileprivate static func shareFinished() {
        sharePicker = nil
    }

    static func airDrop(_ items: [StagedItem]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return }
        let urls = items.map(\.url)
        if service.canPerform(withItems: urls) {
            NSApp.activate()
            service.perform(withItems: urls)
        }
    }

    static func compress(_ items: [StagedItem]) {
        CoveEngine.shared.compress(urls: items.map(\.url)) { archive in
            if archive != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            } else {
                NSSound.beep()
            }
        }
    }

    static func remove(_ items: [StagedItem]) {
        NotchWindowManager.shared.poofThenRemove(items)
    }

    /// Builds the right-click menu for `items`. `stack` is set when the click
    /// landed on an unopened stack.
    static func menu(for items: [StagedItem], stack: ShelfStack?, anchor: NSView? = nil) -> NSMenu {
        let menu = NSMenu()
        let count = items.count
        let noun = count == 1 ? "" : " \(count) Items"

        let quickLookItem = ClosureMenuItem("Quick Look\(noun)", symbol: "eye", key: " ") { quickLook(items) }
        quickLookItem.keyEquivalentModifierMask = []
        menu.addItem(quickLookItem)
        menu.addItem(ClosureMenuItem("Open\(noun)", symbol: "arrow.up.forward.app") { open(items) })

        if count == 1, let item = items.first {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
            if !apps.isEmpty {
                let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for app in apps.prefix(12) {
                    let name = FileManager.default.displayName(atPath: app.path)
                    let entry = ClosureMenuItem(name) {
                        NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: .init())
                    }
                    let icon = NSWorkspace.shared.icon(forFile: app.path)
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                    sub.addItem(entry)
                }
                openWith.submenu = sub
                menu.addItem(openWith)
            }
        }

        menu.addItem(ClosureMenuItem("Reveal in Finder", symbol: "folder") { reveal(items) })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Share…", symbol: "square.and.arrow.up") {
            share(items, anchor: anchor)
        })
        menu.addItem(ClosureMenuItem("AirDrop", symbol: "airplayaudio") { airDrop(items) })
        menu.addItem(ClosureMenuItem("Compress\(noun)", symbol: "doc.zipper") { compress(items) })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc") { copyFiles(items) })
        menu.addItem(ClosureMenuItem(count == 1 ? "Copy Path" : "Copy Paths", symbol: "link") { copyPaths(items) })

        if let stack, stack.isStack {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Show Items in Stack", symbol: "square.stack.3d.up") {
                NotchWindowManager.shared.openStack(stack.id)
            })
            menu.addItem(ClosureMenuItem("Split Stack", symbol: "square.split.2x1") {
                CoveEngine.shared.ungroup(stackId: stack.id)
            })
        }

        menu.addItem(.separator())
        let remove = ClosureMenuItem("Remove from Cove", symbol: "xmark.circle") { remove(items) }
        remove.keyEquivalent = "\u{8}"
        remove.keyEquivalentModifierMask = []
        menu.addItem(remove)
        return menu
    }
}
