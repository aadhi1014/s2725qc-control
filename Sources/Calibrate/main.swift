// Measures when each of the four speakers' sound reaches the Mac's built-in microphone.
//
// Plays a short sweep on each quad channel (L, R, Ls, Rs) of the default output in turn,
// records the built-in microphone, and finds each sweep in the recording by
// cross-correlation. Emission and arrival are both converted to host time, so the
// result is the full path latency: agent backlog + monitor + speaker-to-mic distance.
import Accelerate
import AVFoundation
import CoreAudio
import Foundation

let rate = 48000.0
let speakers = ["front left  (left monitor, inner)", "front right (right monitor, inner)",
                "rear left   (left monitor, outer)", "rear right  (right monitor, outer)"]
// Usage: S2725QCCalibrate [rounds] [--apply]
//   --apply  store per-speaker delays so all four speakers arrive together, and tell the agent.
let arguments = CommandLine.arguments.dropFirst()
let rounds = arguments.compactMap { Int($0) }.first ?? 3
let apply = arguments.contains("--apply")
let agentDefaults = UserDefaults(suiteName: "dev.solderable.s2725qc-control")!
let delaysKey = "speakerDelaysMs"
let spacing = Int(rate * 0.5)          // one sweep every 0.5 s
let leadIn = Int(rate * 0.6)
let sweepLength = Int(rate * 0.04)     // 40 ms, 1 kHz -> 8 kHz

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)

// Sweep template with raised-cosine edges.
let sweep: [Float] = (0..<sweepLength).map { i in
    let t = Double(i) / rate, d = Double(sweepLength) / rate
    let phase = 2 * Double.pi * (1000 * t + (8000 - 1000) * t * t / (2 * d))
    let edge = min(1, min(Double(i), Double(sweepLength - i)) / 96)
    return Float(sin(phase) * (0.5 - 0.5 * cos(Double.pi * edge)))
}

// MARK: Output: sweeps on the virtual quad device

func defaultOutput() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(0), size = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    return device
}

let output = defaultOutput()
let totalSweeps = rounds * 4
let totalFrames = leadIn + totalSweeps * spacing + Int(rate * 0.5)
var emittedHost = [Double](repeating: 0, count: totalSweeps)  // host time of each sweep's first sample
var frameCounter = 0
var proc: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&proc, output, nil) { _, _, _, out, outputTime in
    let list = UnsafeMutableAudioBufferListPointer(out)
    guard let buf = list.first, let p = buf.mData?.assumingMemoryBound(to: Float32.self) else { return }
    let ch = Int(buf.mNumberChannels), n = Int(buf.mDataByteSize) / 4 / ch
    let hostAtStart = Double(outputTime.pointee.mHostTime)
    for f in 0..<n {
        let t = frameCounter + f
        // Inaudible (-90 dB) marker keeps the rear channels discrete instead of copying the front.
        for c in 0..<ch { p[f * ch + c] = c >= 2 ? 3e-5 : 0 }
        let k = (t - leadIn) / spacing, inSweep = (t - leadIn) % spacing
        if t >= leadIn, k < totalSweeps, inSweep < sweepLength {
            let c = k % 4
            if c < ch { p[f * ch + c] = 0.5 * sweep[inSweep] }
            if inSweep == 0 { emittedHost[k] = hostAtStart + Double(f) / rate * ticksPerSecond }
        }
    }
    frameCounter += n
}

// MARK: Input: built-in microphone

let engine = AVAudioEngine()
let input = engine.inputNode
let inFormat = input.outputFormat(forBus: 0)
var recorded: [Float] = []
var recordedStartHost: Double?
let recordLock = NSLock()
input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, when in
    guard let data = buffer.floatChannelData?[0] else { return }
    recordLock.lock()
    if recordedStartHost == nil {
        recordedStartHost = Double(when.hostTime)
    }
    recorded.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    recordLock.unlock()
}

// Ask for microphone access first (prompts once) so recording doesn't start before it's granted.
let access = DispatchSemaphore(value: 0)
var granted = false
AVCaptureDevice.requestAccess(for: .audio) { granted = $0; access.signal() }
access.wait()
guard granted else {
    print("Microphone access denied (System Settings > Privacy & Security > Microphone).")
    exit(1)
}
do { try engine.start() } catch { print("Cannot start microphone: \(error)"); exit(1) }
Thread.sleep(forTimeInterval: 0.3)
AudioDeviceStart(output, proc)
Thread.sleep(forTimeInterval: Double(totalFrames) / rate + 0.4)
AudioDeviceStop(output, proc)
engine.stop()

// MARK: Analysis

let micRate = inFormat.sampleRate
recordLock.lock()
let mic = recorded
let micStart = recordedStartHost ?? 0
recordLock.unlock()
guard micRate == rate else { print("Microphone runs at \(micRate) Hz; expected 48000."); exit(1) }

/// Returns (arrival host time, peak-to-median ratio) of the sweep near `emitted`.
func locate(_ emitted: Double) -> (Double, Float)? {
    let startIndex = Int((emitted - micStart) / ticksPerSecond * micRate)
    let window = Int(micRate * 0.25)
    guard startIndex >= 0, startIndex + window + sweepLength < mic.count else { return nil }
    var corr = [Float](repeating: 0, count: window)
    mic.withUnsafeBufferPointer { m in
        vDSP_conv(m.baseAddress! + startIndex, 1, sweep, 1, &corr, 1, vDSP_Length(window), vDSP_Length(sweepLength))
    }
    let mags = corr.map { abs($0) }
    var peak: Float = 0
    var peakIndex: vDSP_Length = 0
    vDSP_maxvi(mags, 1, &peak, &peakIndex, vDSP_Length(window))
    let median = mags.sorted()[window / 2]
    return (micStart + Double(startIndex + Int(peakIndex)) / micRate * ticksPerSecond, peak / max(median, 1e-9))
}

var latencies = [[Double]](repeating: [], count: 4)
var weak = 0
for k in 0..<totalSweeps {
    guard let (arrival, quality) = locate(emittedHost[k]) else { continue }
    if quality < 8 { weak += 1; continue }
    latencies[k % 4].append((arrival - emittedHost[k]) / ticksPerSecond * 1000)
}

print("Path latency, sweep emitted -> heard at the Mac's microphone (median of \(rounds)):")
var medians: [Double?] = []
for (i, name) in speakers.enumerated() {
    let values = latencies[i].sorted()
    let median = values.isEmpty ? nil : values[values.count / 2]
    medians.append(median)
    let spread = values.count > 1 ? String(format: " (spread %.2f ms)", values.last! - values.first!) : ""
    print("  \(name): " + (median.map { String(format: "%7.2f ms", $0) } ?? "   not detected") + spread)
}
if weak > 0 { print("  \(weak) sweep(s) too quiet to detect reliably") }
let found = medians.compactMap { $0 }
if let earliest = found.min() {
    print("Relative to the earliest speaker:")
    for (i, name) in speakers.enumerated() {
        if let m = medians[i] { print("  \(name): +" + String(format: "%.2f ms", m - earliest)) }
    }
}

// MARK: Apply

guard apply else { exit(0) }
guard found.count == 4 else {
    print("Not all four speakers were detected; delays left unchanged.")
    exit(1)
}
// Measured latencies include the delays already applied. Delay every speaker so it arrives
// together with the latest one, then drop the common part so the smallest delay is 0.
let current = (agentDefaults.array(forKey: delaysKey) as? [Double]) ?? [0, 0, 0, 0]
let latest = found.max()!
var delays = (0..<4).map { current[$0] + (latest - medians[$0]!) }
let common = delays.min()!
delays = delays.map { ($0 - common) * 100 } .map { $0.rounded() / 100 }
agentDefaults.set(delays, forKey: delaysKey)
agentDefaults.synchronize()
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.solderable.s2725qc.speakerDelaysChanged"), object: nil, userInfo: nil, deliverImmediately: true)
print("Applied speaker delays (ms) L, R, Ls, Rs: " + delays.map { String(format: "%.2f", $0) }.joined(separator: ", "))
