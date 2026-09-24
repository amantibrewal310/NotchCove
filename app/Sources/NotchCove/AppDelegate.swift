import AppKit
import Carbon.HIToolbox
import Quartz
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var keepItemsMenuItem: NSMenuItem?
    private var sizeMenuItems: [NSMenuItem] = []
    private var autoClearMenuItems: [NSMenuItem] = []
    private var dragModeMenuItems: [NSMenuItem] = []
    private var screenshotMenuItems: [NSMenuItem] = []
    private var themeMenuItems: [NSMenuItem] = []
    private var launchAtLoginMenuItem: NSMenuItem?

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

        let menu = NSMenu()
        menu.delegate = self

        let toggle = NSMenuItem(title: "Show Shelf", action: #selector(toggleShelf), keyEquivalent: "c")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.target = self
        menu.addItem(toggle)

        let inbox = NSMenuItem(title: "Open Cove Inbox Folder", action: #selector(openInbox), keyEquivalent: "")
        inbox.target = self
        menu.addItem(inbox)

        menu.addItem(.separator())

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for choice in ThemeChoice.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(chooseTheme(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            themeMenu.addItem(entry)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        themeMenuItems = themeMenu.items

        let sizeItem = NSMenuItem(title: "Shelf Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in ShelfSize.allCases {
            let entry = NSMenuItem(title: size.title, action: #selector(chooseShelfSize(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = size.rawValue
            sizeMenu.addItem(entry)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        sizeMenuItems = sizeMenu.items

        let dragItem = NSMenuItem(title: "Open Shelf While Dragging", action: nil, keyEquivalent: "")
        let dragMenu = NSMenu()
        for mode in DragOpenMode.allCases {
            let entry = NSMenuItem(title: mode.title, action: #selector(chooseDragMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            dragMenu.addItem(entry)
        }
        dragItem.submenu = dragMenu
        menu.addItem(dragItem)
        dragModeMenuItems = dragMenu.items

        let clearItem = NSMenuItem(title: "Auto-Clear Items", action: nil, keyEquivalent: "")
        let clearMenu = NSMenu()
        for policy in AutoClear.allCases {
            if policy == .never { clearMenu.addItem(.separator()) }
            let entry = NSMenuItem(title: policy.title, action: #selector(chooseAutoClear(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = policy.rawValue
            clearMenu.addItem(entry)
        }
        clearItem.submenu = clearMenu
        menu.addItem(clearItem)
        autoClearMenuItems = clearMenu.items.filter { !$0.isSeparatorItem }

        let shotItem = NSMenuItem(title: "Screenshots", action: nil, keyEquivalent: "")
        let shotMenu = NSMenu()
        for mode in ScreenshotMode.allCases {
            if mode == .keepFile { shotMenu.addItem(.separator()) }
            let entry = NSMenuItem(title: mode.title, action: #selector(chooseScreenshotMode(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            shotMenu.addItem(entry)
        }
        shotItem.submenu = shotMenu
        menu.addItem(shotItem)
        screenshotMenuItems = shotMenu.items.filter { !$0.isSeparatorItem }

        let keep = NSMenuItem(title: "Keep Items After Dragging Out", action: #selector(toggleKeepItems), keyEquivalent: "")
        keep.target = self
        menu.addItem(keep)
        keepItemsMenuItem = keep

        let clear = NSMenuItem(title: "Clear Shelf", action: #selector(clearFiles), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        launchAtLoginMenuItem = login

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NotchCove", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        keepItemsMenuItem?.state = UserDefaults.standard.bool(forKey: DragOutCoordinator.keepItemsKey) ? .on : .off
        for item in dragModeMenuItems {
            item.state = item.representedObject as? String == DragOpenMode.current.rawValue ? .on : .off
        }
        for item in autoClearMenuItems {
            item.state = item.tag == AutoClear.current.rawValue ? .on : .off
        }
        for item in themeMenuItems {
            item.state = item.representedObject as? String == ThemeChoice.current.rawValue ? .on : .off
        }
        for item in screenshotMenuItems {
            item.state = item.representedObject as? String == ScreenshotMode.current.rawValue ? .on : .off
        }
        launchAtLoginMenuItem?.state = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .mixed
        default: .off
        }
        // Cheap way to notice a changed screenshot folder without watching prefs.
        ScreenshotWatcher.shared.apply()
        for item in sizeMenuItems {
            item.state = item.representedObject as? String == ShelfSize.current.rawValue ? .on : .off
        }
    }

    @objc private func toggleShelf() {
        NotchWindowManager.shared.toggleFromHotKey()
    }

    @objc private func chooseDragMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DragOpenMode(rawValue: raw) else { return }
        DragOpenMode.current = mode
    }

    @objc private func chooseAutoClear(_ sender: NSMenuItem) {
        guard let policy = AutoClear(rawValue: sender.tag) else { return }
        AutoClearScheduler.shared.setPolicy(policy)
    }

    @objc private func chooseShelfSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = ShelfSize(rawValue: raw) else { return }
        NotchWindowManager.shared.setShelfSize(size)
    }

    @objc private func chooseTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = ThemeChoice(rawValue: raw) else { return }
        NotchWindowManager.shared.setTheme(choice)
    }

    @objc private func chooseScreenshotMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ScreenshotMode(rawValue: raw) else { return }
        ScreenshotWatcher.shared.setMode(mode)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            clog("[Login] \(error)")
        }
        // macOS may want the user to allow it in System Settings › Login Items.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openInbox() {
        NSWorkspace.shared.open(CoveEngine.shared.inboxDirectory)
    }

    @objc private func toggleKeepItems() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DragOutCoordinator.keepItemsKey), forKey: DragOutCoordinator.keepItemsKey)
    }

    @objc private func clearFiles() {
        CoveEngine.shared.clearAll()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // Quick Look looks up the responder chain, which ends at the app delegate.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.end(panel) }
}
