import Foundation
import os

/// Bundle identifier, defaults domain, and unified-log subsystem.
let brightsyncID = "cz.szypowi.brightsync"

/// Sync settings, read from the cz.szypowi.brightsync defaults domain. The
/// Settings window and `defaults write cz.szypowi.brightsync ...` are the
/// same mechanism; the AppDelegate observes the keys and applies changes
/// live. The domain is validated as a whole and a bad value is an error, so
/// a typo never silently reverts to defaults.
struct Config {
    var min: Double = 0
    var max: Double = 100
    var gamma: Double = 1.0
    var intervalMs: Int = 50
    var clamshellKeys: Bool = true

    static let minKey = "min"
    static let maxKey = "max"
    static let gammaKey = "gamma"
    static let intervalMsKey = "intervalMs"
    static let clamshellKeysKey = "clamshellKeys"
    /// Shell-only setting, not part of the sync config.
    static let showMenuBarIconKey = "showMenuBarIcon"

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    /// The cz.szypowi.brightsync domain no matter how the binary runs: the
    /// installed app bundle owns that identifier, so its standard defaults
    /// already land there; an unbundled dev build (swift run) has no bundle
    /// identifier and must address the domain explicitly.
    static let defaults: UserDefaults =
        Bundle.main.bundleIdentifier == brightsyncID
            ? .standard
            : UserDefaults(suiteName: brightsyncID) ?? .standard

    /// Seeds the registration domain so unset keys read as their defaults
    /// (for both fromDefaults and the Settings window's bindings) without
    /// persisting anything.
    static func registerDefaults() {
        defaults.register(defaults: [
            minKey: 0.0,
            maxKey: 100.0,
            gammaKey: 1.0,
            intervalMsKey: 50,
            clamshellKeysKey: true,
            showMenuBarIconKey: true,
        ])
    }

    static func fromDefaults() throws -> Config {
        let config = Config(
            min: defaults.double(forKey: minKey),
            max: defaults.double(forKey: maxKey),
            gamma: defaults.double(forKey: gammaKey),
            intervalMs: defaults.integer(forKey: intervalMsKey),
            clamshellKeys: defaults.bool(forKey: clamshellKeysKey))

        guard (0...100).contains(config.min), (0...100).contains(config.max), config.min < config.max else {
            throw ConfigError(description: "min/max must satisfy 0 <= min < max <= 100 (got \(config.min)/\(config.max))")
        }
        guard config.gamma > 0 else {
            throw ConfigError(description: "gamma must be > 0 (got \(config.gamma))")
        }
        guard config.intervalMs >= 10 else {
            throw ConfigError(description: "intervalMs must be >= 10 (got \(config.intervalMs))")
        }
        return config
    }

    /// Maps internal brightness (0.0-1.0) to an external luminance percentage
    /// on the configured curve.
    func luminancePercent(forInternal brightness: Double) -> Double {
        let clamped = Swift.min(Swift.max(brightness, 0), 1)
        return min + (max - min) * pow(clamped, gamma)
    }

    /// Inverse of luminancePercent: the internal brightness that maps to a
    /// given external luminance percentage. Seeds the virtual brightness when
    /// the daemon starts in clamshell mode and the only known value is what
    /// the display reports.
    func internalBrightness(forLuminancePercent percent: Double) -> Double {
        let clamped = Swift.min(Swift.max(percent, min), max)
        return pow((clamped - min) / (max - min), 1 / gamma)
    }
}

private let logTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let systemLogger = Logger(subsystem: brightsyncID, category: "daemon")

/// Logs to stdout for foreground runs and to the unified log for the login
/// item, whose stdout goes nowhere. Messages are marked public - nothing
/// sensitive is logged and redacted lines are useless for debugging.
func log(_ message: String) {
    print("\(logTimestampFormatter.string(from: Date())) \(message)")
    fflush(stdout)
    systemLogger.notice("\(message, privacy: .public)")
}
