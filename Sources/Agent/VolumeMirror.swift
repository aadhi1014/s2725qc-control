import CoreAudio
import Foundation

/// Watches the virtual device's volume slider and mirrors it to every connected monitor.
final class VolumeMirror {
    private let device: AudioObjectID
    private let volumeAddr = HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "ddpm.volume", qos: .userInteractive)
    private var writers: [DDCWriter] = [] // accessed on `queue`

    init(device: AudioObjectID) {
        self.device = device
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.push() }
        var addr = volumeAddr
        AudioObjectAddPropertyListenerBlock(device, &addr, queue, listener)
        self.listener = listener
    }

    /// Replaces the set of monitors. The slider starts where the first (leftmost) monitor is,
    /// and every monitor is then brought to that level.
    func setWriters(_ newWriters: [DDCWriter]) {
        queue.async { [self] in
            writers = newWriters
            if let first = newWriters.first, let v = first.read(.volume) {
                HAL.set(device, volumeAddr, v)
                log("synced slider to monitor volume \(Int((v * 100).rounded()))%")
            }
            push()
        }
    }

    private func push() {
        guard let scalar = HAL.get(device, volumeAddr, Float32(0)) else { return }
        let value = UInt16((min(max(scalar, 0), 1) * 100).rounded())
        for writer in writers { writer.submit(.volume, value) }
    }

    func stop() {
        guard let listener else { return }
        var addr = volumeAddr
        AudioObjectRemovePropertyListenerBlock(device, &addr, queue, listener)
        self.listener = nil
    }
}
