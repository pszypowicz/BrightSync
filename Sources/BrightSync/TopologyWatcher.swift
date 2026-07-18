import Foundation
import IOKit

/// Kernel-delivered display topology events - the approach proven by Lunar.
///
/// Two sources feed the engine's debounced rescan:
/// - General-interest messages from IOPMrootDomain: lid state changes (read
///   back from the AppleClamshellState registry property, only acted on when
///   the value actually flipped) and wake from sleep.
/// - First-match/terminate notifications for DCPAVServiceProxy: external
///   displays appearing and disappearing.
///
/// IOKit notifications are Mach messages dispatched directly to the main
/// queue - no WindowServer session involved, which is why they reach a
/// launchd agent while the CG reconfiguration callback does not.
enum TopologyWatcher {
    /// kIOMessageSystemHasPoweredOn (IOKit/IOMessage.h).
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    // Touched only on the main queue.
    nonisolated(unsafe) private static var lidClosed = false
    nonisolated(unsafe) private static var rootDomain: io_service_t = 0

    static func start() {
        DispatchQueue.main.async {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                log("error: cannot create IOKit notification port")
                exit(1)
            }
            IONotificationPortSetDispatchQueue(port, .main)

            rootDomain = IOServiceGetMatchingService(
                kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain"))
            lidClosed = readLidClosed()
            var interest: io_object_t = 0
            let interestStatus = IOServiceAddInterestNotification(
                port, rootDomain, kIOGeneralInterest, powerMessageCallback, nil, &interest)
            guard interestStatus == KERN_SUCCESS else {
                log("error: IOPMrootDomain interest notification failed (status \(interestStatus))")
                exit(1)
            }

            for event in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let status = IOServiceAddMatchingNotification(
                    port, event, IOServiceMatching("DCPAVServiceProxy"),
                    displayServiceCallback, nil, &iterator)
                guard status == KERN_SUCCESS else {
                    log("error: DCPAVServiceProxy \(event) notification failed (status \(status))")
                    exit(1)
                }
                // Draining arms the notification; the initial batch is the
                // already-present services, not an event.
                drain(iterator)
            }
            log("topology: watching IOPMrootDomain and DCPAVServiceProxy events")
        }
    }

    fileprivate static func drain(_ iterator: io_iterator_t) {
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            IOObjectRelease(entry)
        }
    }

    fileprivate static func handlePowerMessage(_ type: UInt32) {
        if type == systemHasPoweredOn {
            log("topology: woke from sleep")
            SyncEngine.shared?.scheduleRescan()
            return
        }
        let closed = readLidClosed()
        guard closed != lidClosed else { return }
        lidClosed = closed
        log("topology: lid \(closed ? "closed" : "opened")")
        SyncEngine.shared?.scheduleRescan()
    }

    private static func readLidClosed() -> Bool {
        IORegistryEntryCreateCFProperty(
            rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool ?? false
    }
}

private let powerMessageCallback: IOServiceInterestCallback = { _, _, type, _ in
    TopologyWatcher.handlePowerMessage(type)
}

private let displayServiceCallback: IOServiceMatchingCallback = { _, iterator in
    TopologyWatcher.drain(iterator)
    log("topology: display service change")
    SyncEngine.shared?.scheduleRescan()
}
