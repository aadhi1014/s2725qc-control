import CoreAudio
import CoreGraphics
import Foundation
import IOKit

/// One external monitor, tying together its DDC channel, its screen and its DisplayPort audio device.
struct Monitor {
    let ddc: DDCDisplay
    let displayID: CGDirectDisplayID?
    let audioDevice: AudioObjectID?
    /// Left edge in global display coordinates; used to order monitors left to right.
    let x: CGFloat

    var port: String { ddc.port }

    /// Finds all external DDC monitors, sorted left to right as arranged in System Settings.
    ///
    /// Identical monitors share a model name, so they are told apart by:
    /// - DDC <-> screen: EDID serial vs CGDisplaySerialNumber
    /// - DDC <-> audio: the display coprocessor port ("dispextN") both services live under
    static func discover() -> [Monitor] {
        let audioByPort = displayPortAudioByPort()
        let screens = onlineExternalDisplays()
        return DDCDisplay.externalDisplays().map { ddc in
            let screen = screens.first { CGDisplaySerialNumber($0) == ddc.edidSerial }
            return Monitor(ddc: ddc,
                           displayID: screen,
                           audioDevice: audioByPort[ddc.port],
                           x: screen.map { CGDisplayBounds($0).minX } ?? .greatestFiniteMagnitude)
        }
        .sorted { $0.x < $1.x }
    }

    private static func onlineExternalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    /// Maps "dispextN" -> CoreAudio device, via the DCPAVAudioDriver's "device UID" property.
    private static func displayPortAudioByPort() -> [String: AudioObjectID] {
        var uidToPort: [String: String] = [:]
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVAudioDriver"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let port = DDCDisplay.port(ofRegistryEntry: entry),
                  let uid = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "device UID" as CFString, kCFAllocatorDefault,
                                                            IOOptionBits(kIORegistryIterateRecursively)) as? String else { continue }
            uidToPort[uid] = port
        }
        var result: [String: AudioObjectID] = [:]
        for device in HAL.devices() where HAL.transportType(device) == kAudioDeviceTransportTypeDisplayPort {
            if let uid = HAL.string(device, kAudioDevicePropertyDeviceUID), let port = uidToPort[uid] {
                result[port] = device
            }
        }
        return result
    }
}
