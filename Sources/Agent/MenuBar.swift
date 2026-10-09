import AppKit
import CoreAudio

/// Menu bar item with brightness and volume sliders for the monitor.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let brightness: MonitorBrightness
    private let virtualUID: String
    private let brightnessSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeAddr = HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
    private let muteAddr = HAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    init(brightness: MonitorBrightness, virtualUID: String) {
        self.brightness = brightness
        self.virtualUID = virtualUID
        super.init()

        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "S2725QC")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(sectionHeader("DELL S2725QC"))
        menu.addItem(sliderRow(brightnessSlider, symbol: "sun.max.fill", action: #selector(brightnessChanged)))
        menu.addItem(sliderRow(volumeSlider, symbol: "speaker.wave.2.fill", action: #selector(volumeChanged)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit S2725QC Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        brightnessSlider.doubleValue = Double(brightness.value)
        brightness.onChange = { [weak self] value in self?.brightnessSlider.doubleValue = Double(value) }
    }

    private var virtualDevice: AudioObjectID? { HAL.device(uid: virtualUID) }

    func menuWillOpen(_ menu: NSMenu) {
        brightnessSlider.doubleValue = Double(brightness.value)
        if let device = virtualDevice {
            let muted = (HAL.get(device, muteAddr, UInt32(0)) ?? 0) != 0
            volumeSlider.doubleValue = muted ? 0 : Double(HAL.get(device, volumeAddr, Float32(0)) ?? 0)
            volumeSlider.isEnabled = true
        } else {
            volumeSlider.isEnabled = false
        }
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        brightness.set(Self.snapped(sender.floatValue))
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        guard let device = virtualDevice else { return }
        let value = Self.snapped(sender.floatValue)
        HAL.set(device, volumeAddr, value)
        HAL.set(device, muteAddr, UInt32(value == 0 ? 1 : 0))
    }

    private static func snapped(_ value: Float) -> Float32 {
        (value / MediaKeys.step).rounded() * MediaKeys.step
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func sliderRow(_ slider: NSSlider, symbol: String, action: Selector) -> NSMenuItem {
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        slider.controlSize = .regular

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, slider])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 30)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let item = NSMenuItem()
        item.view = row
        return item
    }
}
