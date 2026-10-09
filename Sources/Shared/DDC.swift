import Foundation
import IOKit
import CoreGraphics

// Private IOAVService API (Apple Silicon DDC/CI over DP/USB-C/HDMI)
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ offset: UInt32, _ outputBuffer: UnsafeMutableRawPointer, _ outputBufferSize: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: CFTypeRef, _ chipAddress: UInt32, _ dataAddress: UInt32, _ inputBuffer: UnsafeMutableRawPointer, _ inputBufferSize: UInt32) -> IOReturn

enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case volume = 0x62
    case mute = 0x8D
}

final class DDCDisplay {
    let service: CFTypeRef
    let name: String

    init(service: CFTypeRef, name: String) {
        self.service = service
        self.name = name
    }

    /// Finds external displays that expose an IOAVService (DCPAVServiceProxy with Location=External).
    static func externalDisplays() -> [DDCDisplay] {
        var result: [DDCDisplay] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External",
                  let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            result.append(DDCDisplay(service: av, name: "External \(result.count + 1)"))
        }
        return result
    }

    private static let chip: UInt32 = 0x37
    private static let hostAddress: UInt8 = 0x51

    private func checksum(_ bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    func write(_ code: VCP, _ value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, code.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(checksum(packet, seed: UInt8(Self.chip << 1) ^ Self.hostAddress))
        for attempt in 0..<2 {
            if attempt > 0 { usleep(20_000) }
            let result = packet.withUnsafeMutableBytes {
                IOAVServiceWriteI2C(service, Self.chip, UInt32(Self.hostAddress), $0.baseAddress!, UInt32($0.count))
            }
            if result == kIOReturnSuccess { return true }
        }
        return false
    }

    /// Returns (current, max) or nil.
    func read(_ code: VCP) -> (current: UInt16, max: UInt16)? {
        for _ in 0..<4 {
            var packet: [UInt8] = [0x82, 0x01, code.rawValue]
            packet.append(checksum(packet, seed: UInt8(Self.chip << 1) ^ Self.hostAddress))
            let wrote = packet.withUnsafeMutableBytes {
                IOAVServiceWriteI2C(service, Self.chip, UInt32(Self.hostAddress), $0.baseAddress!, UInt32($0.count))
            }
            guard wrote == kIOReturnSuccess else { usleep(50_000); continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let read = reply.withUnsafeMutableBytes {
                IOAVServiceReadI2C(service, Self.chip, 0, $0.baseAddress!, UInt32($0.count))
            }
            guard read == kIOReturnSuccess else { usleep(50_000); continue }
            // reply: [src, len, 0x02, result, vcp, type, maxHi, maxLo, curHi, curLo, chk]
            let expected = checksum(Array(reply[0..<10]), seed: 0x50)
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code.rawValue, reply[10] == expected else {
                usleep(50_000); continue
            }
            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let cur = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (cur, max)
        }
        return nil
    }
}
