import AppKit
import CoreAudio
import Foundation

let virtualUID = "S2725QC_UID"

/// Everything attached to one connected monitor. Main thread only.
final class ConnectedMonitor {
    let monitor: Monitor
    let label: String
    let writer: DDCWriter
    let brightness: MonitorBrightness
    let bridge: Bridge?

    init(monitor: Monitor, label: String, role: DDPMRole, virtual: AudioObjectID?) {
        self.monitor = monitor
        self.label = label
        writer = DDCWriter(display: monitor.ddc)
        brightness = MonitorBrightness(writer: writer)
        if let virtual, let audio = monitor.audioDevice {
            bridge = Bridge(dell: audio, virtual: virtual, role: role)
        } else {
            bridge = nil
        }
    }

    func destroy() {
        bridge?.destroy()
        writer.stop()
    }
}

var connected: [ConnectedMonitor] = []
var connectedSignature = ""
var mirror: VolumeMirror?
var playbackListenerInstalled = false
var idleSince: Date?
var idleTimer: DispatchSourceTimer?

/// Runs the monitor bridges only while some app is playing to the virtual device.
func updatePlayback() {
    let bridges = connected.compactMap(\.bridge)
    guard !bridges.isEmpty, let virtual = HAL.device(uid: virtualUID) else {
        idleTimer?.cancel()
        idleTimer = nil
        return
    }
    let wasRunning = bridges.contains { $0.isRunning }
    var run = wasRunning
    if HAL.othersPlaying(to: virtual) {
        idleSince = nil
        run = true
    } else if wasRunning {
        let since = idleSince ?? Date()
        idleSince = since
        if Date().timeIntervalSince(since) >= 3 { run = false }
    }
    for bridge in bridges { bridge.setRunning(run) }
    if run != wasRunning { log(run ? "audio bridges started" : "audio bridges idle") }

    // Poll for the end of playback only while running; starts are event-driven.
    if run, idleTimer == nil {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler(handler: updatePlayback)
        timer.resume()
        idleTimer = timer
    } else if !run {
        idleTimer?.cancel()
        idleTimer = nil
    }
}

func findBuiltInSpeakers() -> AudioObjectID? {
    HAL.devices().first {
        HAL.transportType($0) == kAudioDeviceTransportTypeBuiltIn && HAL.outputChannelCount($0) > 0
    }
}

/// With several monitors side by side, the leftmost is the left front + left surround pair and
/// the rightmost the right pair; a single (or middle) monitor plays stereo.
func roleAndLabel(index: Int, count: Int) -> (DDPMRole, String) {
    if count == 1 { return (DDPMRoleStereo, "Monitor") }
    if index == 0 { return (DDPMRoleLeftSide, "Left") }
    if index == count - 1 { return (DDPMRoleRightSide, "Right") }
    return (DDPMRoleStereo, "Middle \(index)")
}

/// Idempotent: called at launch and whenever devices, the default output or the display arrangement change.
func reconcile() {
    let virtual = HAL.device(uid: virtualUID)
    if virtual == nil { log("virtual device \(virtualUID) not installed") }
    let monitors = Monitor.discover()

    // Rebuild only when the set of monitors, their audio devices or their left-to-right order changed.
    let signature = monitors.map { "\($0.port)/\($0.audioDevice ?? 0)/\($0.displayID ?? 0)" }.joined(separator: ",")
        + "|\(virtual ?? 0)"
    if signature != connectedSignature {
        connectedSignature = signature
        connected.forEach { $0.destroy() }
        connected = monitors.enumerated().map { index, monitor in
            let (role, label) = roleAndLabel(index: index, count: monitors.count)
            return ConnectedMonitor(monitor: monitor, label: label, role: role, virtual: virtual)
        }
        log("monitors: " + (connected.isEmpty ? "none" : connected.map {
            "\($0.label)=\($0.monitor.port)\($0.bridge == nil ? " (no audio)" : "")"
        }.joined(separator: ", ")))
        if let virtual, mirror == nil { mirror = VolumeMirror(device: virtual) }
        mirror?.setWriters(connected.map(\.writer))
        menuBar?.update(monitors: connected)
    }

    guard let virtual else { return }
    if !playbackListenerInstalled {
        var addr = HAL.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectAddPropertyListenerBlock(virtual, &addr, .main) { _, _ in updatePlayback() }
        playbackListenerInstalled = true
    }

    let monitorAudio = connected.compactMap(\.monitor.audioDevice)
    if monitorAudio.isEmpty {
        // Monitors unplugged: don't leave the system routed into a dead virtual device.
        if HAL.defaultOutput == virtual, let speakers = findBuiltInSpeakers() {
            HAL.setDefaultOutput(speakers)
        }
    } else if let current = HAL.defaultOutput, monitorAudio.contains(current) {
        // macOS picked a monitor's raw (volume-less) output: route through the virtual device instead.
        HAL.setDefaultOutput(virtual)
        log("default output -> \(HAL.string(virtual, kAudioObjectPropertyName) ?? virtualUID)")
    }
    updatePlayback()
}

/// Hands the output back to a monitor's raw device so audio keeps working without the agent.
func restoreOutput() {
    if let virtual = HAL.device(uid: virtualUID), HAL.defaultOutput == virtual,
       let monitor = connected.first(where: { $0.monitor.audioDevice != nil })?.monitor.audioDevice {
        HAL.setDefaultOutput(monitor)
    }
    connected.forEach { $0.bridge?.destroy() }
}

var signalSources: [DispatchSourceSignal] = []
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
    // Monitors plugged in, unplugged or rearranged in System Settings > Displays.
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
        reconcile()
    }
    mediaKeys = MediaKeys(virtualUID: virtualUID) { display in
        connected.first { $0.monitor.displayID == display }?.brightness
    }
    menuBar = MenuBar(virtualUID: virtualUID)
    reconcile()
    app.run()
}
