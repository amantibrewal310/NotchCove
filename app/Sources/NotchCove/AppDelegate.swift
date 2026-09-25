import AppKit
import Carbon.HIToolbox
import Quartz
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    /// The settings menu, shown by the menu bar icon and from the shelf.
    private let menu = NSMenu()
    private static let hidesIconKey = "HidesMenuBarIcon"
    /// Menu items with a checkmark, refreshed each time the menu opens.
    private var checkedItems: [(item: NSMenuItem, state: () -> NSControl.StateValue)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotchWindowManager.shared.setup()
        setupStatusItem()
        AutoClearScheduler.shared.start()
        ScreenshotWatcher.shared.start()

        hotKey = HotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) {
            NotchWindowManager.shared.toggleFromHotKey()
        }
        if hotKey == nil { clog("[HotKey] ⌃⌥C is taken by another app") }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Brand.glyph

        menu.delegate = self
        let manager = NotchWindowManager.shared

        let toggle = ClosureMenuItem("Show Shelf", key: "c") { manager.toggleFromHotKey() }
        toggle.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggle)
        menu.addItem(ClosureMenuItem("Open Cove Inbox Folder") { NSWorkspace.shared.open(CoveEngine.shared.inboxDirectory) })
        menu.addItem(.separator())

        addChoices("Theme", to: menu) { manager.setTheme($0) }
        addChoices("Shelf Size", to: menu) { manager.setShelfSize($0) }
        addChoices("Open Shelf While Dragging", to: menu) { DragOpenMode.current = $0 }
        addChoices("Auto-Clear Items", to: menu, separatorBefore: AutoClear.never) { AutoClearScheduler.shared.setPolicy($0) }
        addChoices("Screenshots", to: menu, separatorBefore: ScreenshotMode.keepFile) { ScreenshotWatcher.shared.setMode($0) }

        addToggle("Show Item Count Beside Notch", to: menu, isOn: { manager.showsCountBesideNotch }) {
            manager.setShowsCountBesideNotch(!manager.showsCountBesideNotch)
        }
        addToggle("Always Show Virtual Notch", to: menu, isOn: { manager.alwaysShowsVirtualNotch }) {
            manager.setAlwaysShowsVirtualNotch(!manager.alwaysShowsVirtualNotch)
        }
        addToggle("Keep Items After Dragging Out", to: menu, isOn: { DragOutCoordinator.keepItems }) {
            DragOutCoordinator.keepItems.toggle()
        }
        menu.addItem(ClosureMenuItem("Clear Shelf") { CoveEngine.shared.clearAll() })
        menu.addItem(.separator())

        addToggle("Hide Menu Bar Icon", to: menu, isOn: { UserDefaults.standard.bool(forKey: Self.hidesIconKey) }) { [weak self] in
            self?.setHidesStatusItem(!UserDefaults.standard.bool(forKey: Self.hidesIconKey))
        }
        let login = ClosureMenuItem("Launch at Login") { Self.toggleLaunchAtLogin() }
        menu.addItem(login)
        checkedItems.append((login, {
            switch SMAppService.mainApp.status {
            case .enabled: .on
            case .requiresApproval: .mixed
            default: .off
            }
        }))
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Quit NotchCove", key: "q") { NSApp.terminate(nil) })

        item.menu = menu
        item.isVisible = !UserDefaults.standard.bool(forKey: Self.hidesIconKey)
        statusItem = item
    }

    private func setHidesStatusItem(_ hide: Bool) {
        UserDefaults.standard.set(hide, forKey: Self.hidesIconKey)
        statusItem?.isVisible = !hide
    }

    /// Shows the settings menu below a view, or at the pointer, for when the
    /// menu bar icon is hidden.
    func showSettingsMenu(below view: NSView? = nil) {
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// Opening NotchCove again while it runs brings back a hidden menu bar icon,
    /// so the settings can't get lost.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setHidesStatusItem(false)
        return false
    }

    private func addChoices<T: Setting>(
        _ title: String, to menu: NSMenu, separatorBefore: T? = nil, select: @escaping (T) -> Void
    ) {
        let submenu = NSMenu()
        for choice in T.allCases {
            if choice == separatorBefore { submenu.addItem(.separator()) }
            let entry = ClosureMenuItem(choice.title) { select(choice) }
            submenu.addItem(entry)
            checkedItems.append((entry, { T.current == choice ? .on : .off }))
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addToggle(_ title: String, to menu: NSMenu, isOn: @escaping () -> Bool, toggle: @escaping () -> Void) {
        let item = ClosureMenuItem(title, handler: toggle)
        menu.addItem(item)
        checkedItems.append((item, { isOn() ? .on : .off }))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for (item, state) in checkedItems { item.state = state() }
        // Picks up a changed screenshot folder even if no prefs notification arrived.
        ScreenshotWatcher.shared.apply()
    }

    private static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            clog("[Login] \(error)")
        }
        // macOS may want the user to allow it in System Settings › Login Items.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    // Quick Look looks up the responder chain, which ends at the app delegate.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.end(panel) }
}
