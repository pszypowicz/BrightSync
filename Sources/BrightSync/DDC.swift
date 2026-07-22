import CPrivateAPIs
import Foundation
import IOKit

/// DDC/CI over the Apple Silicon DCP I2C bus.
///
/// Protocol notes: the display is chip 0x37; packets are prefixed with the
/// host "source address" 0x51 (passed as the I2C data offset) and end with an
/// XOR checksum seeded with 0x6E (the display's write address). A "Get VCP
/// Feature" reply carries the maximum value in bytes 6-7 and the current
/// value in bytes 8-9, big-endian. Writes are repeated because some displays
/// ignore the first transaction after the bus has been idle.
enum DDC {
    static let luminanceVCP: UInt8 = 0x10
    private static let chipAddress: UInt32 = 0x37
    private static let sourceAddress: UInt8 = 0x51
    private static let transactionWait: useconds_t = 10_000
    private static let writeIterations = 2
    /// Whole transactions are retried too: right after wake or replug some
    /// displays NACK or ignore the bus for a while.
    private static let transactionAttempts = 3
    private static let attemptWait: useconds_t = 20_000

    /// IOAVService handles for every connected external display, discovered
    /// via DCPAVServiceProxy entries whose Location is "External".
    static func externalServices() -> [IOAVService] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [IOAVService] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let location = IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                location == "External",
                let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)
            else { continue }
            services.append(service)
        }
        return services
    }

    /// Reads the luminance VCP feature. Returns nil when the display does not
    /// answer (DDC/CI disabled, incompatible dock, display asleep).
    static func readLuminance(_ service: IOAVService) -> (current: Int, max: Int)? {
        for attempt in 0..<transactionAttempts {
            if attempt > 0 { usleep(attemptWait) }
            if let luminance = readLuminanceOnce(service) { return luminance }
        }
        return nil
    }

    @discardableResult
    static func writeLuminance(_ service: IOAVService, value: Int) -> Bool {
        for attempt in 0..<transactionAttempts {
            if attempt > 0 { usleep(attemptWait) }
            if writeLuminanceOnce(service, value: value) { return true }
        }
        return false
    }

    private static func readLuminanceOnce(_ service: IOAVService) -> (current: Int, max: Int)? {
        var request: [UInt8] = [0x82, 0x01, luminanceVCP, 0]
        request[3] = 0x6E ^ request[0] ^ request[1] ^ request[2]
        for _ in 0..<writeIterations {
            usleep(transactionWait)
            guard IOAVServiceWriteI2C(
                service, chipAddress, UInt32(sourceAddress), &request, UInt32(request.count)
            ) == kIOReturnSuccess else { return nil }
        }

        var reply = [UInt8](repeating: 0, count: 11)
        usleep(transactionWait)
        guard IOAVServiceReadI2C(
            service, chipAddress, UInt32(sourceAddress), &reply, UInt32(reply.count)
        ) == kIOReturnSuccess else { return nil }

        // Replies end with an XOR checksum seeded with 0x50 (the virtual
        // host address); a concurrent bus user or a half-awake display can
        // garble a read into a plausible-looking reply, so mismatches are
        // discarded. The DCP overwrites the reply's second byte (the 0x88
        // length marker) with the I2C offset argument, so the checksum is
        // computed with the canonical value substituted.
        var checksum: UInt8 = 0x50 ^ 0x88
        for (index, byte) in reply.dropLast().enumerated() where index != 1 {
            checksum ^= byte
        }
        guard checksum == reply[reply.count - 1] else { return nil }

        let maxValue = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        guard maxValue > 0 else { return nil }
        return (current, maxValue)
    }

    private static func writeLuminanceOnce(_ service: IOAVService, value: Int) -> Bool {
        let clamped = UInt16(clamping: value)
        var packet: [UInt8] = [
            0x84, 0x03, luminanceVCP, UInt8(clamped >> 8), UInt8(clamped & 0xFF), 0,
        ]
        packet[5] = 0x6E ^ sourceAddress
            ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
        for _ in 0..<writeIterations {
            usleep(transactionWait)
            guard IOAVServiceWriteI2C(
                service, chipAddress, UInt32(sourceAddress), &packet, UInt32(packet.count)
            ) == kIOReturnSuccess else { return false }
        }
        return true
    }
}
