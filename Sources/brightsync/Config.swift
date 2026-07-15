import Foundation

/// Effective settings after merging defaults, the optional config file, and
/// CLI flags (flags win).
///
/// The config file lives at $XDG_CONFIG_HOME/brightsync/config.json (default
/// ~/.config/brightsync/config.json) so the daemon stays configurable when
/// launched by launchd, where flags are impractical. Recognized keys: "min",
/// "max", "gamma", "intervalMs". A missing file is fine; a malformed one is a
/// fatal error so a typo never silently reverts to defaults.
struct Config {
    var min: Double = 0
    var max: Double = 100
    var gamma: Double = 1.0
    var intervalMs: Int = 50

    struct ConfigError: Error, CustomStringConvertible {
        let description: String
    }

    private struct FileValues: Codable {
        var min: Double?
        var max: Double?
        var gamma: Double?
        var intervalMs: Int?
    }

    static func filePath() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("brightsync/config.json")
    }

    static func load(min: Double?, max: Double?, gamma: Double?, intervalMs: Int?) throws -> Config {
        var config = Config()

        let url = filePath()
        if FileManager.default.fileExists(atPath: url.path) {
            let values: FileValues
            do {
                values = try JSONDecoder().decode(FileValues.self, from: Data(contentsOf: url))
            } catch {
                throw ConfigError(description: "cannot parse \(url.path): \(error)")
            }
            config.min = values.min ?? config.min
            config.max = values.max ?? config.max
            config.gamma = values.gamma ?? config.gamma
            config.intervalMs = values.intervalMs ?? config.intervalMs
        }

        config.min = min ?? config.min
        config.max = max ?? config.max
        config.gamma = gamma ?? config.gamma
        config.intervalMs = intervalMs ?? config.intervalMs

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
}

private let logTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

func log(_ message: String) {
    print("\(logTimestampFormatter.string(from: Date())) \(message)")
    fflush(stdout)
}
