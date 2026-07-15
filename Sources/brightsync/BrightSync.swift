import ArgumentParser
import CoreGraphics
import Foundation

@main
struct BrightSync: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brightsync",
        abstract: "Mirror the built-in display brightness to external displays over DDC/CI.",
        discussion: """
            Listens for built-in display brightness changes (keyboard, ambient \
            light sensor, Control Center) and immediately writes the mapped \
            luminance to every connected DDC-capable external display. \
            Apple Silicon only.

            Settings may also come from \
            ~/.config/brightsync/config.json (keys: min, max, gamma, \
            intervalMs); flags override the file.

            Examples:
              brightsync                     run in the foreground
              brightsync --list              show displays and current values
              brightsync --once              sync once and exit
              brightsync --min 10 --gamma 1.4
            """,
        version: "0.1.1"
    )

    @Flag(help: "List displays and current values, then exit.")
    var list = false

    @Flag(help: "Sync once and exit.")
    var once = false

    @Flag(help: "Log every brightness event and DDC write.")
    var verbose = false

    @Option(help: "External luminance (0-100) mapped to internal brightness 0.")
    var min: Double?

    @Option(help: "External luminance (0-100) mapped to internal brightness 1.")
    var max: Double?

    @Option(help: "Curve exponent applied to internal brightness before mapping.")
    var gamma: Double?

    @Option(name: .customLong("interval-ms"), help: "Minimum milliseconds between DDC writes.")
    var intervalMs: Int?

    @Option(name: .customLong("set-internal"), help: "Set built-in brightness (0.0-1.0) and exit. Mainly for testing the sync loop.")
    var setInternal: Double?

    @Option(name: .customLong("set-external"), help: "Write luminance percent (0-100) to all external displays and exit. The next brightness change re-syncs over it.")
    var setExternal: Double?

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

        let config = try Config.load(min: min, max: max, gamma: gamma, intervalMs: intervalMs)
        let engine = SyncEngine(config: config, verbose: verbose)
        SyncEngine.shared = engine
        engine.start()
        if once { return }

        engine.registerForNotifications()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
        log("brightsync \(Self.configuration.version) running (min \(config.min), max \(config.max), gamma \(config.gamma), interval \(config.intervalMs)ms)")

        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
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
