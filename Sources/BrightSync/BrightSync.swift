import AppKit
import ArgumentParser
import CoreGraphics
import Foundation

@main
struct BrightSync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brightsync",
        abstract: "Mirror the built-in display brightness to external displays over DDC/CI.",
        discussion: """
            Runs as a menu bar app: listens for built-in display brightness \
            changes (keyboard, ambient light sensor, Control Center) and \
            immediately writes the mapped luminance to every connected \
            DDC-capable external display. With the lid closed the brightness \
            keys are handled directly and a brightness overlay is shown, so \
            they keep working in clamshell mode (requires Accessibility). \
            Apple Silicon only.

            Settings live in the Settings window, or equivalently the \
            cz.szypowi.brightsync defaults domain (keys: min, max, gamma, \
            intervalMs, clamshellKeys, showMenuBarIcon); changes apply \
            immediately. Opening the app while it is already running shows \
            Settings - the escape hatch when the menu bar icon is hidden.

            Examples:
              brightsync                     run the app in the foreground
              brightsync --list              show displays and current values
              brightsync --once              sync once and exit
              brightsync --set-external 40   one-off manual luminance write
            """,
        version: "0.4.0"
    )

    @Flag(help: "List displays and current values, then exit.")
    var list = false

    @Flag(help: "Sync once and exit.")
    var once = false

    @Flag(help: "Log every brightness event and DDC write.")
    var verbose = false

    @Option(name: .customLong("set-internal"), help: "Set built-in brightness (0.0-1.0) and exit. Mainly for testing the sync loop.")
    var setInternal: Double?

    @Option(name: .customLong("set-external"), help: "Write luminance percent (0-100) to all external displays and exit. The next brightness change re-syncs over it.")
    var setExternal: Double?

    /// NSApplication.delegate is unretained, so the shell keeps its delegate
    /// alive here.
    nonisolated(unsafe) private static var delegate: AppDelegate?

    func run() throws {
        if let value = setInternal {
            try runSetInternal(value)
            return
        }
        if let value = setExternal {
            try runSetExternal(value)
            return
        }
        if list {
            runList()
            return
        }

        Config.registerDefaults()
        let config: Config
        do {
            config = try Config.fromDefaults()
        } catch {
            log("error: \(error)")
            throw ExitCode.failure
        }
        let engine = SyncEngine(config: config, verbose: verbose)
        SyncEngine.shared = engine
        if once {
            engine.start()
            return
        }

        let app = NSApplication.shared
        Self.delegate = AppDelegate(engine: engine, config: config, verbose: verbose)
        app.delegate = Self.delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private func runList() {
        if let builtin = DisplayServices.builtinDisplay() {
            let brightness = DisplayServices.brightness(of: builtin)
                .map { String(format: "%.1f%%", $0 * 100) } ?? "unknown"
            print("built-in display \(builtin): brightness \(brightness)")
        } else {
            print("built-in display: none online")
        }

        let services = DDC.externalServices()
        if services.isEmpty {
            print("external DDC displays: none found")
            return
        }
        for (index, service) in services.enumerated() {
            if let luminance = DDC.readLuminance(service) {
                print("external display #\(index + 1): luminance \(luminance.current)/\(luminance.max)")
            } else {
                print("external display #\(index + 1): no DDC response")
            }
        }
    }

    private func runSetExternal(_ percent: Double) throws {
        guard (0...100).contains(percent) else {
            throw ValidationError("--set-external expects a value between 0 and 100")
        }
        let services = DDC.externalServices()
        guard !services.isEmpty else {
            throw ValidationError("no external DDC displays found")
        }
        for (index, service) in services.enumerated() {
            let maxLuminance = DDC.readLuminance(service)?.max ?? 100
            let value = Int((percent / 100 * Double(maxLuminance)).rounded())
            if DDC.writeLuminance(service, value: value) {
                print("external display #\(index + 1): luminance -> \(value)/\(maxLuminance)")
            } else {
                print("external display #\(index + 1): DDC write failed")
            }
        }
    }

    private func runSetInternal(_ value: Double) throws {
        guard (0...1).contains(value) else {
            throw ValidationError("--set-internal expects a value between 0.0 and 1.0")
        }
        guard let builtin = DisplayServices.builtinDisplay() else {
            throw ValidationError("no built-in display online")
        }
        guard let setBrightness = DisplayServices.setBrightness else {
            throw ValidationError("DisplayServices brightness API unavailable")
        }
        let status = setBrightness(builtin, Float(value))
        guard status == 0 else {
            throw ValidationError("setting brightness failed (status \(status))")
        }
    }
}
