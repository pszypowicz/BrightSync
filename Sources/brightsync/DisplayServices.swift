import CoreFoundation
import CoreGraphics
import Foundation

/// Bindings to DisplayServices.framework, the private framework that owns
/// built-in display brightness. It ships no SDK tbd, so symbols are resolved
/// at runtime via dlopen/dlsym; every binding is optional and callers must
/// treat a nil as "this macOS no longer exposes the symbol".
///
/// The change notification delivers the new brightness (0.0-1.0) in
/// userInfo["value"] of a CFNotification, observed per display ID.
enum DisplayServices {
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightnessFn = @convention(c) (CGDirectDisplayID) -> Bool
    typealias RegisterFn = @convention(c) (CGDirectDisplayID, CGDirectDisplayID, CFNotificationCallback) -> Int32
    typealias UnregisterFn = @convention(c) (CGDirectDisplayID, CGDirectDisplayID) -> Int32

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY
    )

    private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static let getBrightness = symbol(
        "DisplayServicesGetBrightness", as: GetBrightnessFn.self)
    static let setBrightness = symbol(
        "DisplayServicesSetBrightness", as: SetBrightnessFn.self)
    static let canChangeBrightness = symbol(
        "DisplayServicesCanChangeBrightness", as: CanChangeBrightnessFn.self)
    static let registerForBrightnessChanges = symbol(
        "DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self)
    static let unregisterForBrightnessChanges = symbol(
        "DisplayServicesUnregisterForBrightnessChangeNotifications", as: UnregisterFn.self)

    /// Current brightness of the display, 0.0-1.0, or nil if unavailable.
    static func brightness(of display: CGDirectDisplayID) -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return nil }
        return Double(value)
    }

    /// The online display backed by the built-in panel, if any (nil in
    /// clamshell mode).
    static func builtinDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
