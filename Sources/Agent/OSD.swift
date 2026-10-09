import AppKit
import CoreGraphics

/// The native macOS volume/brightness HUD (private OSD.framework, same API Dell's DDPM uses).
enum OSD {
    enum Image: Int64 {
        case brightness = 1
        case volume = 3
        case muted = 4
    }

    @objc private protocol Manager {
        func showImage(_ image: Int64, onDisplayID: CGDirectDisplayID, priority: UInt32, msecUntilFade: UInt32,
                       filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
    }

    private static let manager: Manager? = {
        guard dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_NOW) != nil,
              let cls = NSClassFromString("OSDManager") as AnyObject?,
              let shared = cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() else {
            log("OSD.framework unavailable; no on-screen indicator")
            return nil
        }
        return unsafeBitCast(shared, to: Manager.self)
    }()

    static func show(_ image: Image, level: Float32, on display: CGDirectDisplayID, chiclets: UInt32 = 100) {
        manager?.showImage(image.rawValue, onDisplayID: display, priority: 0x1f4, msecUntilFade: 1000,
                           filledChiclets: UInt32((min(max(level, 0), 1) * Float32(chiclets)).rounded()),
                           totalChiclets: chiclets, locked: false)
    }

    /// The display under the mouse pointer.
    static var displayUnderCursor: CGDirectDisplayID {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
    }
}
