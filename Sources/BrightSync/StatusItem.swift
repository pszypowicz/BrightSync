import AppKit

/// The menu bar icon and its menu. `refresh()` is idempotent and keyed on
/// the showMenuBarIcon setting, so the AppDelegate can call it on any
/// settings change to create or remove the item live.
final class StatusItemController: NSObject {
    private var item: NSStatusItem?

    func refresh() {
        let show = Config.defaults.bool(forKey: Config.showMenuBarIconKey)
        if show, item == nil {
            item = makeItem()
        } else if !show, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sun.max",
            accessibilityDescription: "BrightSync"
        )

        let menu = NSMenu()
        menu.autoenablesItems = false

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About BrightSync", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit BrightSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        return item
    }

    @objc private func showSettings() {
        SettingsView.showWindow()
    }

    @objc private func showAbout() {
        AboutView.showWindow()
    }
}
