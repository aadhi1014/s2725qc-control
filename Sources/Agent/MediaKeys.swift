import AppKit
import ApplicationServices
import CoreAudio

/// Intercepts the volume and brightness keys: volume moves in 2% steps, brightness in
/// macOS's own 1/16 steps (1/64 with Shift+Option).
/// - volume/mute keys, while the S2725QC virtual device is the default output;
/// - brightness keys, for the external monitor under the mouse pointer.
/// Anything else passes through to macOS untouched.
///
/// The event tap sees every key press, so it runs on its own thread and never waits on
/// anything: it decides from a cached snapshot (`update`) and does the actual work afterwards
/// on the main thread. A slow tap would make macOS drop key events, which loses the volume
/// HUD for other outputs such as AirPods and delays typing.
final class MediaKeys {
    static let step: Float32 = 0.02
    static let brightnessStep: Float32 = 1.0 / 16
    static let fineBrightnessStep: Float32 = 1.0 / 64

    private let brightnessFor: (CGDirectDisplayID) -> MonitorBrightness?
    private let virtualUID: String
    private var tap: CFMachPort?

    // Snapshot read by the tap thread, written by the main thread.
    private let lock = NSLock()
    private var virtualIsDefault = false
    private var monitorDisplays: Set<CGDirectDisplayID> = []

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private enum Key: Int {
        case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    }

    init(virtualUID: String, brightnessFor: @escaping (CGDirectDisplayID) -> MonitorBrightness?) {
        self.brightnessFor = brightnessFor
        self.virtualUID = virtualUID
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            log("waiting for Accessibility permission to handle volume/brightness keys")
        }
        let thread = Thread { [unowned self] in
            self.installTap()
            CFRunLoopRun()
        }
        thread.name = "media keys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Main thread: refreshes what the tap needs to decide whether a key is ours.
    func update(virtualIsDefault: Bool, monitorDisplays: Set<CGDirectDisplayID>) {
        lock.lock()
        self.virtualIsDefault = virtualIsDefault
        self.monitorDisplays = monitorDisplays
        lock.unlock()
    }

    /// Runs on the tap thread.
    private func installTap() {
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
            | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let keys = Unmanaged<MediaKeys>.fromOpaque(refcon!).takeUnretainedValue()
            return keys.handle(type: type, event: event)
        }
        while true {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: callback,
                                    userInfo: Unmanaged.passUnretained(self).toOpaque())
            if tap != nil { break }
            Thread.sleep(forTimeInterval: 3) // not trusted yet; retry until Accessibility is granted
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap!, enable: true)
        log("media key handling active")
    }

    /// Tap thread. Must return quickly and never block.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Some keyboards send brightness as plain key events (kVK 144/145) instead of NX_SYSDEFINED.
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == 144 || code == 145 else { return Unmanaged.passUnretained(event) }
            let handled = brightness(up: code == 144, isDown: type == .keyDown, fine: Self.isFine(event.flags), at: event.location)
            return handled ? nil : Unmanaged.passUnretained(event)
        }
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0x0A
        guard let key = Key(rawValue: (ns.data1 & 0xFFFF_0000) >> 16),
              // Option alone keeps its stock meaning (opens settings); Shift+Option means fine steps.
              !ns.modifierFlags.contains(.option) || ns.modifierFlags.contains(.shift)
        else { return Unmanaged.passUnretained(event) }

        let handled: Bool
        switch key {
        case .soundUp, .soundDown, .mute:
            handled = volume(key, isDown: isDown)
        case .brightnessUp, .brightnessDown:
            handled = brightness(up: key == .brightnessUp, isDown: isDown, fine: Self.isFine(event.flags), at: event.location)
        }
        return handled ? nil : Unmanaged.passUnretained(event)
    }

    /// Tap thread: claims the key if the virtual device is the output; the change happens on main.
    private func volume(_ key: Key, isDown: Bool) -> Bool {
        lock.lock(); let ours = virtualIsDefault; lock.unlock()
        guard ours else { return false }
        if isDown { DispatchQueue.main.async { self.applyVolume(key) } }
        return true
    }

    /// Tap thread: claims the key if the pointer is on a DDC monitor; the change happens on main.
    private func brightness(up: Bool, isDown: Bool, fine: Bool, at point: CGPoint) -> Bool {
        var display = CGDirectDisplayID(0)
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        lock.lock(); let ours = count > 0 && monitorDisplays.contains(display); lock.unlock()
        guard ours else { return false }
        if isDown { DispatchQueue.main.async { self.applyBrightness(up: up, fine: fine, display: display) } }
        return true
    }

    private func applyVolume(_ key: Key) {
        guard let device = HAL.device(uid: virtualUID) else { return }
        let volumeAddr = HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        let muteAddr = HAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var volume = HAL.get(device, volumeAddr, Float32(0)) ?? 0
        var muted = (HAL.get(device, muteAddr, UInt32(0)) ?? 0) != 0

        switch key {
        case .mute:
            muted.toggle()
        default:
            volume = Self.stepped(volume, by: Self.step, up: key == .soundUp)
            muted = volume == 0
            HAL.set(device, volumeAddr, volume)
        }
        HAL.set(device, muteAddr, UInt32(muted ? 1 : 0))
        OSD.show(muted ? .muted : .volume, level: muted ? 0 : volume, on: OSD.displayUnderCursor)
    }

    private func applyBrightness(up: Bool, fine: Bool, display: CGDirectDisplayID) {
        guard let brightness = brightnessFor(display) else { return }
        brightness.set(Self.stepped(brightness.value, by: fine ? Self.fineBrightnessStep : Self.brightnessStep, up: up))
        OSD.show(.brightness, level: brightness.value, on: display, chiclets: fine ? 64 : 16)
    }

    private static func isFine(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate) && flags.contains(.maskShift)
    }

    /// Moves one step and snaps to that step's grid.
    private static func stepped(_ value: Float32, by step: Float32, up: Bool) -> Float32 {
        let steps = (value / step).rounded() + (up ? 1 : -1)
        return min(max(steps * step, 0), 1)
    }
}
