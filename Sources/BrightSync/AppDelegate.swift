import AppKit
import ServiceManagement

/// App lifecycle for the menu bar app: owns the status item, starts the sync
/// engine and its watchers, applies settings changes live, and opens the
/// Settings window on reopen - the escape hatch when the menu bar icon is
/// hidden.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// First-launch guard for the one-time launch-at-login registration.
    static let didRegisterLoginItemKey = "didRegisterLoginItem"

    /// Keys that feed the engine or the shell, observed for live application.
    private static let observedKeys = [
        Config.minKey, Config.maxKey, Config.gammaKey, Config.intervalMsKey,
        Config.clamshellKeysKey, Config.showMenuBarIconKey,
    ]

    private let engine: SyncEngine
    private let initialConfig: Config
    private let verbose: Bool
    private let statusItem = StatusItemController()
    private var reloadWork: DispatchWorkItem?

    init(engine: SyncEngine, config: Config, verbose: Bool) {
        self.engine = engine
        self.initialConfig = config
        self.verbose = verbose
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        registerLoginItemOnFirstLaunch()

        engine.start()
        engine.registerForNotifications()
        TopologyWatcher.start()
        if initialConfig.clamshellKeys {
            ClamshellKeyTap.start(verbose: verbose)
        }
        statusItem.refresh()

        for key in Self.observedKeys {
            Config.defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
        }

        let config = initialConfig
        log(String(format: "brightsync %@ running (min %g, max %g, gamma %g, interval %dms, clamshell keys %@)",
                   BrightSync.configuration.version, config.min, config.max, config.gamma,
                   config.intervalMs, config.clamshellKeys ? "on" : "off"))
    }

    /// Reopening the app (Finder double-click, `open -a BrightSync`) presents
    /// Settings - the universal "where did it go" gesture, and the escape
    /// hatch when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsView.showWindow()
        return false
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // Slider drags fire per tick; coalesce so each pause applies once.
        DispatchQueue.main.async { [self] in
            reloadWork?.cancel()
            let work = DispatchWorkItem { self.applySettings() }
            reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
    }

    private func applySettings() {
        statusItem.refresh()
        let config: Config
        do {
            config = try Config.fromDefaults()
        } catch {
            log("ignoring settings change: \(error)")
            return
        }
        engine.update(config: config)
        if config.clamshellKeys {
            ClamshellKeyTap.start(verbose: verbose)
        } else {
            ClamshellKeyTap.stop()
        }
    }

    /// BrightSync is useless unless it runs, so the first launch of the
    /// installed app opts into launch at login (macOS shows its standard
    /// notification); the Settings toggle rules afterwards. Dev builds run
    /// unbundled and must not register themselves as login items.
    private func registerLoginItemOnFirstLaunch() {
        guard Bundle.main.bundleIdentifier == brightsyncID,
            !Config.defaults.bool(forKey: Self.didRegisterLoginItemKey)
        else { return }
        Config.defaults.set(true, forKey: Self.didRegisterLoginItemKey)
        do {
            try SMAppService.mainApp.register()
            log("launch at login enabled (first launch)")
        } catch {
            log("launch at login registration failed: \(error)")
        }
    }

    /// An accessory app shows no menu bar, but key-equivalent routing still
    /// consults the main menu when a utility window is key; this makes Cmd+W
    /// and Cmd+Q work in the Settings and About windows.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit BrightSync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }
}
