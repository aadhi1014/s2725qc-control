import AppKit
import CoreAudio

/// Menu bar item with a brightness slider per monitor and one volume slider for all of them.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let virtualUID: String
    private let menu = NSMenu()
    private var monitors: [ConnectedMonitor] = []
    private var brightnessSliders: [NSSlider] = []
    private let volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let volumeAddr = HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
    private let muteAddr = HAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    init(virtualUID: String) {
        self.virtualUID = virtualUID
        super.init()
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "S2725QC")
        menu.delegate = self
        item.menu = menu
        update(monitors: [])
    }

    /// Rebuilds the menu for the currently connected monitors (left to right).
    func update(monitors: [ConnectedMonitor]) {
        self.monitors = monitors
        menu.removeAllItems()
        brightnessSliders = []

        menu.addItem(sectionHeader(monitors.isEmpty ? "No DDC monitor connected" : "Brightness"))
        for (index, monitor) in monitors.enumerated() {
            let slider = NSSlider(value: Double(monitor.brightness.value), minValue: 0, maxValue: 1, target: nil, action: nil)
            slider.tag = index
            brightnessSliders.append(slider)
            monitor.brightness.onChange = { value in slider.doubleValue = Double(value) }
            menu.addItem(sliderRow(slider, symbol: "sun.max.fill",
                                   label: monitors.count > 1 ? monitor.label : nil, action: #selector(brightnessChanged)))
        }
        if !monitors.isEmpty {
            menu.addItem(sectionHeader(monitors.count > 1 ? "Volume (all monitors)" : "Volume"))
            menu.addItem(sliderRow(volumeSlider, symbol: "speaker.wave.2.fill", label: nil, action: #selector(volumeChanged)))
        }
        menu.addItem(.separator())
        let setup = NSMenuItem(title: "Speaker Setup…", action: #selector(openSetup), keyEquivalent: ",")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(NSMenuItem(title: "Quit S2725QC Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Opens S2725QC Setup, installed next to this app.
    @objc private func openSetup() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("S2725QC Setup.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private var virtualDevice: AudioObjectID? { HAL.device(uid: virtualUID) }

    func menuWillOpen(_ menu: NSMenu) {
        for (slider, monitor) in zip(brightnessSliders, monitors) {
            slider.doubleValue = Double(monitor.brightness.value)
        }
        if let device = virtualDevice {
            let muted = (HAL.get(device, muteAddr, UInt32(0)) ?? 0) != 0
            volumeSlider.doubleValue = muted ? 0 : Double(HAL.get(device, volumeAddr, Float32(0)) ?? 0)
            volumeSlider.isEnabled = true
        } else {
            volumeSlider.isEnabled = false
        }
    }

    @objc private func brightnessChanged(_ sender: NSSlider) {
        guard monitors.indices.contains(sender.tag) else { return }
        monitors[sender.tag].brightness.set(Self.snapped(sender.floatValue))
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

    private func sliderRow(_ slider: NSSlider, symbol: String, label: String?, action: Selector) -> NSMenuItem {
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        slider.controlSize = .regular

        var views: [NSView] = []
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        views.append(icon)
        if let label {
            let text = NSTextField(labelWithString: label)
            text.textColor = .secondaryLabelColor
            text.font = .menuFont(ofSize: 0)
            text.widthAnchor.constraint(equalToConstant: 38).isActive = true
            views.append(text)
        }
        views.append(slider)

        let row = NSStackView(views: views)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 30)

        let item = NSMenuItem()
        item.view = row
        return item
    }
}
