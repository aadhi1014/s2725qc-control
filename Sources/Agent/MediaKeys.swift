import AppKit
import ApplicationServices
import CoreAudio

/// Intercepts the volume and brightness keys: volume moves in 2% steps, brightness in
/// macOS's own 1/16 steps (1/64 with Shift+Option).
/// - volume/mute keys, while the S2725QC virtual device is the default output;
/// - brightness keys, for the external monitor under the mouse pointer.
/// Anything else passes through to macOS untouched.
final class MediaKeys {
    static let step: Float32 = 0.02
    static let brightnessStep: Float32 = 1.0 / 16
    static let fineBrightnessStep: Float32 = 1.0 / 64

    private let brightnessFor: (CGDirectDisplayID) -> MonitorBrightness?
    private let virtualUID: String
    private var tap: CFMachPort?

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
        installTap()
    }

    private func installTap() {
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
            | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let keys = Unmanaged<MediaKeys>.fromOpaque(refcon!).takeUnretainedValue()
            return keys.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            // Not trusted yet; retry until the user grants Accessibility.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.installTap() }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("media key handling active")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Some keyboards send brightness as plain key events (kVK 144/145) instead of NX_SYSDEFINED.
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == 144 || code == 145 else { return Unmanaged.passUnretained(event) }
            let handled = handleBrightness(up: code == 144, isDown: type == .keyDown, fine: Self.isFine(event.flags))
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
            handled = handleVolume(key, isDown: isDown)
        case .brightnessUp, .brightnessDown:
            handled = handleBrightness(up: key == .brightnessUp, isDown: isDown, fine: Self.isFine(event.flags))
        }
        return handled ? nil : Unmanaged.passUnretained(event)
    }

    private func handleVolume(_ key: Key, isDown: Bool) -> Bool {
        guard let device = HAL.device(uid: virtualUID), HAL.defaultOutput == device else { return false }
        guard isDown else { return true }
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
        return true
    }

    private func handleBrightness(up: Bool, isDown: Bool, fine: Bool) -> Bool {
        let display = OSD.displayUnderCursor
        guard let brightness = brightnessFor(display) else { return false }
        guard isDown else { return true }
        brightness.set(Self.stepped(brightness.value, by: fine ? Self.fineBrightnessStep : Self.brightnessStep, up: up))
        OSD.show(.brightness, level: brightness.value, on: display, chiclets: fine ? 64 : 16)
        return true
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
