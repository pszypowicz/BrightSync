import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Brightness key handling for clamshell mode.
///
/// With the lid closed the built-in panel is offline, so macOS ignores the
/// brightness keys entirely: no brightness change, no notification, no bezel.
/// An active CGEvent tap picks the key presses out of the session event
/// stream (NX_SYSDEFINED media-key events), lets the SyncEngine step its
/// virtual brightness, and swallows the event. Whenever the engine is not in
/// clamshell mode - lid open, a natively controllable display present, no
/// DDC targets - every event passes through untouched.
///
/// Active event taps require the Accessibility permission. The system prompt
/// is requested once at startup; a grant made while the daemon runs is
/// picked up through the distributed notification TCC posts on trust
/// changes.
enum ClamshellKeyTap {
    // NX_SYSDEFINED and its aux-control-button subtype (IOKit/IOLLEvent.h),
    // plus the media key codes (IOKit/hidsystem/ev_keymap.h).
    private static let systemDefinedEventType: UInt32 = 14
    private static let auxControlButtonsSubtype: Int16 = 8
    private static let brightnessUpKey = 2
    private static let brightnessDownKey = 3

    // Touched only on the main queue.
    nonisolated(unsafe) private static var tap: CFMachPort?
    nonisolated(unsafe) private static var verbose = false
    nonisolated(unsafe) private static var trustObserver: NSObjectProtocol?

    /// Prompts for Accessibility if needed and installs the tap as soon as
    /// the permission allows. Needs the main run loop to be running.
    static func start(verbose: Bool) {
        DispatchQueue.main.async {
            self.verbose = verbose
            guard !attempt(prompt: true) else { return }
            observeTrustChanges()
        }
    }

    /// Removes the tap (or stops waiting for the permission) so brightness
    /// keys pass through to macOS again; the live settings-toggle path.
    /// Invalidating the mach port also removes its run-loop source.
    static func stop() {
        DispatchQueue.main.async {
            if let observer = trustObserver {
                DistributedNotificationCenter.default().removeObserver(observer)
                trustObserver = nil
            }
            guard let port = tap else { return }
            CFMachPortInvalidate(port)
            tap = nil
            log("clamshell keys: event tap removed")
        }
    }

    /// Tries to install the tap once. Returns true when the tap is active.
    @discardableResult
    private static func attempt(prompt: Bool) -> Bool {
        guard tap == nil else { return true }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            if prompt {
                log(
                    "clamshell keys: waiting for Accessibility permission (System Settings"
                        + " > Privacy & Security > Accessibility)")
            }
            return false
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << systemDefinedEventType),
            callback: brightnessKeyCallback,
            userInfo: nil
        ) else {
            log("clamshell keys: event tap creation failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        if let observer = trustObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            trustObserver = nil
        }
        log("clamshell keys: event tap installed; brightness keys work with the lid closed")
        return true
    }

    /// TCC posts this distributed notification on every Accessibility trust
    /// change (undocumented, the channel the popular utilities listen to),
    /// so a grant lands within a second instead of a retry interval. The
    /// trust state can lag the notification briefly, hence the small delay.
    private static func observeTrustChanges() {
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                attempt(prompt: false)
            }
        }
    }

    /// The system disables taps whose callback stalls; turn ours back on.
    fileprivate static func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// True when the event is a brightness key press handled here and must
    /// not reach the rest of the system.
    fileprivate static func consume(type: CGEventType, event: CGEvent) -> Bool {
        guard type.rawValue == systemDefinedEventType,
            let engine = SyncEngine.shared,
            engine.handlesBrightnessKeys,
            let nsEvent = NSEvent(cgEvent: event),
            nsEvent.subtype.rawValue == auxControlButtonsSubtype
        else { return false }

        // data1 packs the media key: key code in the high word, state and
        // repeat flag in the low word (0x0A = down, 0x0B = up).
        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        guard keyCode == brightnessUpKey || keyCode == brightnessDownKey else { return false }
        if (nsEvent.data1 & 0xFF00) >> 8 == 0x0A {
            let fine = nsEvent.modifierFlags.contains(.option)
                && nsEvent.modifierFlags.contains(.shift)
            if verbose {
                log("event: brightness key \(keyCode == brightnessUpKey ? "up" : "down")\(fine ? " (fine)" : "")")
            }
            SyncEngine.shared?.stepBrightness(up: keyCode == brightnessUpKey, fine: fine)
        }
        // Swallow the key-up as well so nothing else reacts to half a press.
        return true
    }
}

/// Tap callback: passes everything through except brightness keys the engine
/// claims, and revives the tap if the system disabled it.
private let brightnessKeyCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        ClamshellKeyTap.reenable()
        return Unmanaged.passUnretained(event)
    }
    return ClamshellKeyTap.consume(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
