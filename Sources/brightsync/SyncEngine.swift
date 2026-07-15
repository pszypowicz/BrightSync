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
final class SyncEngine {
    /// Notification callbacks are C function pointers without context, so the
    /// engine is reachable through this global. Set once at startup.
    nonisolated(unsafe) static var shared: SyncEngine?

    private struct Target {
        let service: IOAVService
        let maxLuminance: Int
        var lastWritten: Int?
    }

    private let config: Config
    private let verbose: Bool
    private let queue = DispatchQueue(label: "brightsync.ddc")
    private let lock = NSLock()
    private var pending: Double?
    private var draining = false
    private var targets: [Target] = []
    private var builtin: CGDirectDisplayID?
    // Registration state; touched only on the main queue.
    private var registeredObserver: CGDirectDisplayID?
    private var rescanWork: DispatchWorkItem?

    init(config: Config, verbose: Bool) {
        self.config = config
        self.verbose = verbose
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

    /// New internal brightness value from a notification.
    func submit(_ brightness: Double) {
        if verbose { log("event: internal brightness \(String(format: "%.4f", brightness))") }
        lock.lock()
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
        let builtinDisplay = DisplayServices.builtinDisplay()
        let services = DDC.externalServices()
        var newTargets: [Target] = []
        for service in services {
            let luminance = DDC.readLuminance(service)
            if luminance == nil {
                log("warning: external display does not answer DDC luminance read; assuming max 100")
            }
            newTargets.append(Target(service: service, maxLuminance: luminance?.max ?? 100, lastWritten: nil))
        }
        lock.lock()
        builtin = builtinDisplay
        targets = newTargets
        lock.unlock()
        log("displays: built-in \(builtinDisplay.map(String.init) ?? "none"), \(newTargets.count) external DDC target(s)")
    }

    private func syncCurrentLocked() {
        let display = lock.withLock { builtin }
        guard let display, let brightness = DisplayServices.brightness(of: display) else { return }
        write(brightness)
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
                if verbose { log("ddc: luminance -> \(value)/\(current[index].maxLuminance)") }
            } else if verbose {
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

let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    let interesting: CGDisplayChangeSummaryFlags = [
        .addFlag, .removeFlag, .enabledFlag, .disabledFlag, .desktopShapeChangedFlag,
    ]
    guard !flags.intersection(interesting).isEmpty else { return }
    SyncEngine.shared?.scheduleRescan()
}
