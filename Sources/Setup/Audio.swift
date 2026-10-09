import AVFoundation
import Accelerate
import CoreAudio
import Foundation

/// Quad channels of the virtual device, in its channel order.
enum Speaker: Int, CaseIterable, Identifiable {
    case frontLeft, frontRight, rearLeft, rearRight
    var id: Int { rawValue }

    var name: String {
        switch self {
        case .frontLeft: "Front left"
        case .frontRight: "Front right"
        case .rearLeft: "Rear left"
        case .rearRight: "Rear right"
        }
    }

    var place: String {
        switch self {
        case .frontLeft: "left monitor, inner"
        case .frontRight: "right monitor, inner"
        case .rearLeft: "left monitor, outer"
        case .rearRight: "right monitor, outer"
        }
    }

    var short: String { ["L", "R", "Ls", "Rs"][rawValue] }
}

/// The S2725QC virtual output device and the agent's settings.
enum VirtualDevice {
    static let uid = "S2725QC_UID"
    static let agentDefaults = UserDefaults(suiteName: "dev.solderable.s2725qc-control")!
    static let delaysKey = "speakerDelaysMs"
    static let delaysChanged = Notification.Name("dev.solderable.s2725qc.speakerDelaysChanged")
    static let rate = 48000.0

    static var id: AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    private static let volumeAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                               mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static let muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                             mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    /// Volume (0...1) and mute of the virtual device; setting it also moves the monitors via the agent.
    static var volume: (level: Float32, muted: Bool) {
        get {
            guard let device = id else { return (0, false) }
            var addr = volumeAddr, level = Float32(0), size = UInt32(4)
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &level)
            var mAddr = muteAddr, mute = UInt32(0)
            size = 4
            AudioObjectGetPropertyData(device, &mAddr, 0, nil, &size, &mute)
            return (level, mute != 0)
        }
        set {
            guard let device = id else { return }
            var addr = volumeAddr, level = newValue.level
            AudioObjectSetPropertyData(device, &addr, 0, nil, 4, &level)
            var mAddr = muteAddr, mute = UInt32(newValue.muted ? 1 : 0)
            AudioObjectSetPropertyData(device, &mAddr, 0, nil, 4, &mute)
        }
    }

    static var delays: [Double] {
        get {
            let stored = (agentDefaults.array(forKey: delaysKey) as? [Double]) ?? []
            return (0..<4).map { $0 < stored.count ? stored[$0] : 0 }
        }
        set {
            agentDefaults.set(newValue, forKey: delaysKey)
            agentDefaults.synchronize()
            DistributedNotificationCenter.default().postNotificationName(delaysChanged, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
        }
    }
}

/// Plays a signal on the virtual device through a raw IOProc. `render(frame, channel)` returns the
/// sample for one channel; an inaudible marker on the rear channels keeps them discrete
/// (otherwise the agent copies the front channels to the rear speakers).
final class SignalPlayer {
    private var proc: AudioDeviceIOProcID?
    private let device: AudioObjectID
    private var frame = 0

    init?(render: @escaping (_ frame: Int, _ channel: Int) -> Float32, onBuffer: ((Int, Double) -> Void)? = nil) {
        guard let device = VirtualDevice.id else { return nil }
        self.device = device
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { [unowned self] _, _, _, out, outputTime in
            let list = UnsafeMutableAudioBufferListPointer(out)
            guard let buf = list.first, let p = buf.mData?.assumingMemoryBound(to: Float32.self) else { return }
            let ch = Int(buf.mNumberChannels), n = Int(buf.mDataByteSize) / 4 / max(ch, 1)
            onBuffer?(frame, Double(outputTime.pointee.mHostTime))
            for f in 0..<n {
                for c in 0..<ch {
                    let marker: Float32 = c >= 2 ? 3e-5 : 0
                    p[f * ch + c] = marker + render(frame + f, c)
                }
            }
            frame += n
        }
        guard status == noErr else { return nil }
    }

    func start() { if let proc { AudioDeviceStart(device, proc) } }

    func stop() {
        guard let proc else { return }
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
        self.proc = nil
    }

    deinit { stop() }

    /// A one-second tone on a single speaker.
    static func test(_ speaker: Speaker) {
        let freq = [330.0, 440.0, 550.0, 660.0][speaker.rawValue]
        let length = Int(VirtualDevice.rate)
        let player = SignalPlayer { frame, channel in
            guard channel == speaker.rawValue, frame < length else { return 0 }
            let edge = Float32(min(1, Double(min(frame, length - frame)) / 1200))
            return 0.15 * edge * Float32(sin(2 * .pi * freq * Double(frame) / VirtualDevice.rate))
        }
        player?.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { player?.stop() }
    }
}

/// Measures when each speaker's sound reaches the Mac's built-in microphone.
///
/// Plays a 40 ms sweep (1 -> 8 kHz) on each speaker in turn while recording the microphone,
/// locates every sweep by cross-correlation, and converts emission and arrival to host time.
enum Calibrator {
    static let rate = VirtualDevice.rate
    private static let spacing = Int(rate * 0.5)
    private static let leadIn = Int(rate * 0.6)
    private static let sweepLength = Int(rate * 0.04)

    private static let sweep: [Float] = (0..<sweepLength).map { i in
        let t = Double(i) / rate, d = Double(sweepLength) / rate
        let phase = 2 * Double.pi * (1000 * t + (8000 - 1000) * t * t / (2 * d))
        let edge = min(1, min(Double(i), Double(sweepLength - i)) / 96)
        return Float(sin(phase) * (0.5 - 0.5 * cos(Double.pi * edge)))
    }

    enum Failure: LocalizedError {
        case microphoneDenied, noDevice, microphone(String), notDetected([Speaker])
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone."
            case .noDevice: "The S2725QC virtual device isn't installed or the agent isn't running."
            case .microphone(let detail): "Couldn't use the microphone: \(detail)"
            case .notDetected(let speakers): "Couldn't hear: " + speakers.map(\.name).joined(separator: ", ")
                + ". Raise the volume or make the room quieter, then try again."
            }
        }
    }

    /// Returns each speaker's path latency in ms (median over `rounds`). Blocking; call off the main thread.
    static func measure(rounds: Int, progress: @escaping (Double) -> Void) throws -> [Double] {
        let access = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; access.signal() }
        access.wait()
        guard granted else { throw Failure.microphoneDenied }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)

        let total = rounds * 4
        let totalFrames = leadIn + total * spacing + Int(rate * 0.5)
        var emitted = [Double](repeating: 0, count: total)
        let player = SignalPlayer(render: { frame, channel in
            let k = (frame - leadIn) / spacing, inSweep = (frame - leadIn) % spacing
            guard frame >= leadIn, k < total, inSweep < sweepLength, channel == k % 4 else { return 0 }
            return 0.5 * sweep[inSweep]
        }, onBuffer: { firstFrame, hostTime in
            // Host time of each sweep's first sample, from the buffer it falls in.
            for k in 0..<total {
                let start = leadIn + k * spacing
                if start >= firstFrame, start < firstFrame + 4096, emitted[k] == 0 {
                    emitted[k] = hostTime + Double(start - firstFrame) / rate * ticksPerSecond
                }
            }
        })
        guard let player else { throw Failure.noDevice }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate == rate else { throw Failure.microphone("it runs at \(Int(format.sampleRate)) Hz, expected 48000") }
        var recorded: [Float] = []
        var recordedStart: Double?
        let lock = NSLock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            guard let data = buffer.floatChannelData?[0] else { return }
            lock.lock()
            if recordedStart == nil { recordedStart = Double(when.hostTime) }
            recorded.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            lock.unlock()
        }
        do { try engine.start() } catch { throw Failure.microphone(error.localizedDescription) }
        defer { engine.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        player.start()
        let duration = Double(totalFrames) / rate + 0.4
        let steps = 20
        for i in 1...steps {
            Thread.sleep(forTimeInterval: duration / Double(steps))
            progress(Double(i) / Double(steps))
        }
        player.stop()
        input.removeTap(onBus: 0)

        lock.lock()
        let mic = recorded
        let micStart = recordedStart ?? 0
        lock.unlock()

        var latencies = [[Double]](repeating: [], count: 4)
        for k in 0..<total where emitted[k] > 0 {
            let startIndex = Int((emitted[k] - micStart) / ticksPerSecond * rate)
            let window = Int(rate * 0.25)
            guard startIndex >= 0, startIndex + window + sweepLength < mic.count else { continue }
            var corr = [Float](repeating: 0, count: window)
            mic.withUnsafeBufferPointer { m in
                vDSP_conv(m.baseAddress! + startIndex, 1, sweep, 1, &corr, 1, vDSP_Length(window), vDSP_Length(sweepLength))
            }
            let mags = corr.map { abs($0) }
            var peak: Float = 0
            var peakIndex: vDSP_Length = 0
            vDSP_maxvi(mags, 1, &peak, &peakIndex, vDSP_Length(window))
            guard peak / max(mags.sorted()[window / 2], 1e-9) >= 8 else { continue } // too quiet to trust
            let arrival = micStart + Double(startIndex + Int(peakIndex)) / rate * ticksPerSecond
            latencies[k % 4].append((arrival - emitted[k]) / ticksPerSecond * 1000)
        }
        let missing = Speaker.allCases.filter { latencies[$0.rawValue].isEmpty }
        guard missing.isEmpty else { throw Failure.notDetected(missing) }
        return latencies.map { $0.sorted()[$0.count / 2] }
    }
}
