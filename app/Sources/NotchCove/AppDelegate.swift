import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a background/accessory menu bar utility
        NSApp.setActivationPolicy(.accessory)

        // Setup the Notch Window Overlay
        NotchWindowManager.shared.setup()

        // Setup the Menu Bar Status Item
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: "NotchCove")

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: "Toggle Notch Shelf",
            action: #selector(toggleShelf),
            keyEquivalent: "c"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let clearItem = NSMenuItem(
            title: "Clear All Staged Files",
            action: #selector(clearFiles),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit NotchCove",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func toggleShelf() {
        NotchWindowManager.shared.toggleExpanded()
    }

    @objc private func clearFiles() {
        CoveEngine.shared.clearAll()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
