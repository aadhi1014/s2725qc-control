import AppKit
import CoreAudio
import Foundation

let virtualUID = "S2725QC_UID"
let monitorModel = "S2725QC"

let writer = DDCWriter()
var bridge: Bridge?
var mirror: VolumeMirror?
var idleSince: Date?
var idleTimer: DispatchSourceTimer?

/// Runs the bridge only while some app is playing to the virtual device.
func updatePlayback() {
    guard let bridge, let virtual = HAL.device(uid: virtualUID) else {
        idleTimer?.cancel()
        idleTimer = nil
        return
    }
    if HAL.othersPlaying(to: virtual) {
        idleSince = nil
        bridge.setRunning(true)
    } else if bridge.isRunning {
        let since = idleSince ?? Date()
        idleSince = since
        if Date().timeIntervalSince(since) >= 3 { bridge.setRunning(false) }
    }
    // Poll for the end of playback only while running; starts are event-driven.
    if bridge.isRunning, idleTimer == nil {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler(handler: updatePlayback)
        timer.resume()
        idleTimer = timer
    } else if !bridge.isRunning {
        idleTimer?.cancel()
        idleTimer = nil
    }
}

func findMonitorAudio() -> AudioObjectID? {
    HAL.devices().first {
        HAL.transportType($0) == kAudioDeviceTransportTypeDisplayPort
            && (HAL.string($0, kAudioObjectPropertyName) ?? "").contains(monitorModel)
    }
}

func findBuiltInSpeakers() -> AudioObjectID? {
    HAL.devices().first {
        HAL.transportType($0) == kAudioDeviceTransportTypeBuiltIn && HAL.outputChannelCount($0) > 0
    }
}

/// Idempotent: called at launch and whenever devices or the default output change.
func reconcile() {
    let virtual = HAL.device(uid: virtualUID)
    let monitor = findMonitorAudio()

    guard let virtual, let monitor else {
        bridge?.destroy(); bridge = nil
        mirror?.stop(); mirror = nil
        updatePlayback()
        // Monitor unplugged: don't leave the system routed into a dead virtual device.
        if let virtual, HAL.defaultOutput == virtual, let speakers = findBuiltInSpeakers() {
            HAL.setDefaultOutput(speakers)
        }
        if virtual == nil { log("virtual device \(virtualUID) not installed") }
        return
    }

    if bridge?.dell != monitor {
        bridge?.destroy()
        bridge = Bridge(dell: monitor, virtual: virtual)
        var addr = HAL.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectAddPropertyListenerBlock(virtual, &addr, .main) { _, _ in updatePlayback() }
    }
    if mirror == nil {
        mirror = VolumeMirror(device: virtual, writer: writer)
    }
    // When macOS picks the monitor's raw (volume-less) output, route through the virtual device instead.
    if HAL.defaultOutput == monitor {
        HAL.setDefaultOutput(virtual)
        log("default output -> \(HAL.string(virtual, kAudioObjectPropertyName) ?? virtualUID)")
    }
    updatePlayback()
}

/// Hands the output back to the monitor's raw device so audio keeps working without the agent.
func restoreOutput() {
    if let virtual = HAL.device(uid: virtualUID), HAL.defaultOutput == virtual, let monitor = findMonitorAudio() {
        HAL.setDefaultOutput(monitor)
    }
    bridge?.destroy()
    bridge = nil
}

var signalSources: [DispatchSourceSignal] = []
var brightness: MonitorBrightness?
var mediaKeys: MediaKeys?
var menuBar: MenuBar?

/// Entry point, called by the launcher (Sources/Launcher). All agent code lives in this
/// library so rebuilding it doesn't change the signed app and its Accessibility grant.
@_cdecl("agent_main")
public func agentMain() {
    for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
        var addr = HAL.address(selector)
        AudioObjectAddPropertyListenerBlock(HAL.system, &addr, .main) { _, _ in reconcile() }
    }

    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { restoreOutput(); exit(0) }
        source.resume()
        signalSources.append(source)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        restoreOutput()
    }
    let shared = MonitorBrightness(writer: writer)
    brightness = shared
    mediaKeys = MediaKeys(brightness: shared, virtualUID: virtualUID)
    menuBar = MenuBar(brightness: shared, virtualUID: virtualUID)
    reconcile()
    app.run()
}
