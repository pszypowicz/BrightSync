import CoreFoundation
import CoreGraphics
import CPrivateAPIs
import Dispatch
import Foundation

/// Mirrors built-in display brightness to all DDC-capable external displays.
///
/// Brightness change notifications arrive in bursts (macOS ramps brightness
/// smoothly, so one key press yields many events). Writes are coalesced: only
/// the most recent value is kept, and consecutive DDC transactions are spaced
/// by at least `intervalMs` so the I2C bus is never flooded.
///
/// In clamshell mode there is nothing to mirror - the built-in panel is
/// offline and macOS drops brightness key presses entirely - so the engine
/// owns a virtual brightness instead: ClamshellKeyTap feeds key presses to
/// stepBrightness, which walks the last known value in native-sized steps
/// through the same write path.
final class SyncEngine {
    /// Notification callbacks are C function pointers without context, so the
    /// engine is reachable through this global. Set once at startup.
    nonisolated(unsafe) static var shared: SyncEngine?

    private struct Target {
        let service: IOAVService
        let maxLuminance: Int
        var lastWritten: Int?
        /// Set while writes fail so the failure and the recovery are logged
        /// once each instead of once per keypress.
        var failing = false
    }

    /// Swapped whole on settings changes; every consumer takes a snapshot
    /// through the computed accessor, so reads are consistent per operation.
    private var _config: Config
    private var config: Config { lock.withLock { _config } }
    private let verbose: Bool
    private let queue = DispatchQueue(label: "brightsync.ddc")
    private let lock = NSLock()
    private var pending: Double?
    private var draining = false
    private var targets: [Target] = []
    private var builtin: CGDirectDisplayID?
    /// Last internal brightness seen or virtually stepped; the starting point
    /// for clamshell brightness key presses.
    private var lastBrightness: Double?
    /// True when brightness keys should be handled here instead of by macOS:
    /// the feature is enabled, the built-in panel is offline, no online
    /// display offers native brightness control, and there is at least one
    /// DDC target to drive.
    private var clamshellActive = false
    // Registration state; touched only on the main queue.
    private var registeredObserver: CGDirectDisplayID?
    private var rescanWork: DispatchWorkItem?

    init(config: Config, verbose: Bool) {
        self._config = config
        self.verbose = verbose
    }

    /// Applies new settings live: rescanning recomputes the clamshell state
    /// and the sync re-pushes the current brightness through the new curve.
    func update(config: Config) {
        lock.withLock { _config = config }
        queue.async {
            self.rescanLocked()
            self.syncCurrentLocked()
        }
    }

    /// Discovers displays and pushes the current brightness. Blocks until the
    /// initial DDC writes are done, so --once can rely on it.
    func start() {
        queue.sync {
            self.rescanLocked()
            self.syncCurrentLocked()
        }
    }

    /// Registers for brightness change notifications; requires a running main
    /// run loop. Safe to call again after a rescan changed the built-in ID.
    func registerForNotifications() {
        DispatchQueue.main.async {
            guard let register = DisplayServices.registerForBrightnessChanges else {
                log("error: DisplayServices notification API unavailable; cannot continue")
                exit(1)
            }
            let display = self.lock.withLock { self.builtin }
            guard let display else {
                log("no built-in display online (clamshell?); waiting for display changes")
                return
            }
            if let old = self.registeredObserver {
                guard old != display else { return }
                _ = DisplayServices.unregisterForBrightnessChanges?(old, old)
            }
            let status = register(display, display, brightnessChangedCallback)
            if status == 0 {
                self.registeredObserver = display
                log("listening for brightness changes on built-in display \(display)")
            } else {
                log("error: brightness notification registration failed (status \(status))")
                exit(1)
            }
        }
    }

    /// Whether brightness key events should be consumed instead of passed on
    /// to macOS. Cheap enough for an event-tap callback.
    var handlesBrightnessKeys: Bool {
        lock.withLock { clamshellActive }
    }

    /// Steps the virtual brightness for a clamshell key press: native-sized
    /// steps (1/16, or 1/64 with Option+Shift) snapped to the step grid,
    /// written like any other brightness change, with the system bezel as
    /// feedback.
    func stepBrightness(up: Bool, fine: Bool) {
        let step = fine ? 1.0 / 64 : 1.0 / 16
        let current = lock.withLock { lastBrightness } ?? 0.5
        let position = (current / step).rounded() + (up ? 1 : -1)
        let value = Swift.min(Swift.max(position * step, 0), 1)
        submit(value)
        BrightnessHUD.show(
            percent: config.luminancePercent(forInternal: value),
            brightening: up,
            on: CGMainDisplayID())
    }

    /// New internal brightness value from a notification.
    func submit(_ brightness: Double) {
        if verbose { log("event: internal brightness \(String(format: "%.4f", brightness))") }
        lock.lock()
        lastBrightness = brightness
        pending = brightness
        let shouldDrain = !draining
        if shouldDrain { draining = true }
        lock.unlock()
        if shouldDrain {
            queue.async { self.drain() }
        }
    }

    /// Re-reads the built-in brightness and submits it.
    func submitCurrent() {
        let display = lock.withLock { builtin }
        guard let display, let brightness = DisplayServices.brightness(of: display) else { return }
        submit(brightness)
    }

    /// Debounced re-discovery after display topology changes (hotplug, sleep,
    /// clamshell). Waits for the topology to settle before touching DDC.
    func scheduleRescan() {
        DispatchQueue.main.async {
            self.rescanWork?.cancel()
            let work = DispatchWorkItem {
                log("rescanning after display change")
                self.queue.async {
                    self.rescanLocked()
                    self.syncCurrentLocked()
                }
                self.registerForNotifications()
            }
            self.rescanWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    // MARK: - Work on the DDC queue

    private func rescanLocked() {
        let config = self.config
        let builtinDisplay = DisplayServices.builtinDisplay()
        let services = DDC.externalServices()
        var newTargets: [Target] = []
        var externalBrightness: Double?
        for service in services {
            let luminance = DDC.readLuminance(service)
            if let luminance {
                if externalBrightness == nil {
                    externalBrightness = config.internalBrightness(
                        forLuminancePercent: Double(luminance.current) / Double(luminance.max) * 100)
                }
            } else {
                log("warning: external display does not answer DDC luminance read; assuming max 100")
            }
            newTargets.append(Target(service: service, maxLuminance: luminance?.max ?? 100, lastWritten: nil))
        }
        let nativeControl = Self.nativeBrightnessControlOnline()
        lock.lock()
        builtin = builtinDisplay
        targets = newTargets
        if lastBrightness == nil { lastBrightness = externalBrightness }
        clamshellActive = config.clamshellKeys && builtinDisplay == nil
            && !nativeControl && !newTargets.isEmpty
        let active = clamshellActive
        lock.unlock()
        log("displays: built-in \(builtinDisplay.map(String.init) ?? "none"), \(newTargets.count) external DDC target(s)")
        if active {
            log("clamshell mode: brightness keys drive the external displays")
        }
    }

    /// True when any online display is brightness-controllable by macOS
    /// itself (built-in panel, Apple displays). The system then handles the
    /// keys and shows its own bezel, so ours must stay out of the way.
    private static func nativeBrightnessControlOnline() -> Bool {
        guard let canChange = DisplayServices.canChangeBrightness else { return false }
        return onlineDisplays().contains { canChange($0) }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func syncCurrentLocked() {
        if let display = lock.withLock({ builtin }),
            let brightness = DisplayServices.brightness(of: display) {
            lock.withLock { lastBrightness = brightness }
            write(brightness)
        } else if let value = lock.withLock({ lastBrightness }) {
            // Clamshell: push the virtual brightness so a display attached
            // with the lid closed is aligned without waiting for a key press.
            write(value)
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            write(value)
            usleep(useconds_t(config.intervalMs * 1000))
        }
    }

    private func write(_ internalBrightness: Double) {
        let percent = config.luminancePercent(forInternal: internalBrightness)
        lock.lock()
        var current = targets
        lock.unlock()

        for index in current.indices {
            let value = Int((percent / 100 * Double(current[index].maxLuminance)).rounded())
            guard current[index].lastWritten != value else { continue }
            if DDC.writeLuminance(current[index].service, value: value) {
                current[index].lastWritten = value
                if current[index].failing {
                    current[index].failing = false
                    log("ddc: writes recovered")
                }
                if verbose { log("ddc: luminance -> \(value)/\(current[index].maxLuminance)") }
            } else if !current[index].failing {
                current[index].failing = true
                log("ddc: write failed (display asleep or DDC unavailable)")
            }
        }

        lock.lock()
        // A rescan may have replaced the target list while writing; only keep
        // our lastWritten bookkeeping if it did not.
        if targets.count == current.count {
            targets = current
        }
        lock.unlock()
    }
}

/// CFNotification callback invoked by DisplayServices on brightness changes.
/// The new value (0.0-1.0) rides in userInfo["value"].
let brightnessChangedCallback: CFNotificationCallback = { _, _, _, _, userInfo in
    guard let engine = SyncEngine.shared else { return }
    if let value = (userInfo as NSDictionary?)?["value"] as? Double {
        engine.submit(value)
    } else {
        engine.submitCurrent()
    }
}

