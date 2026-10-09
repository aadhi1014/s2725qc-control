import CoreAudio
import Foundation

/// Watches the virtual device's volume slider and mirrors it to the monitor.
final class VolumeMirror {
    private let device: AudioObjectID
    private let writer: DDCWriter
    private let volumeAddr = HAL.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "ddpm.volume", qos: .userInteractive)

    init(device: AudioObjectID, writer: DDCWriter) {
        self.device = device
        self.writer = writer

        // Start the slider where the monitor currently is.
        queue.async { [weak self] in
            guard let self, let v = writer.read(.volume) else { return }
            HAL.set(device, self.volumeAddr, v)
            log("synced slider to monitor volume \(Int((v * 100).rounded()))%")
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let scalar = HAL.get(device, self.volumeAddr, Float32(0)) else { return }
            writer.submit(.volume, UInt16((min(max(scalar, 0), 1) * 100).rounded()))
        }
        var addr = volumeAddr
        AudioObjectAddPropertyListenerBlock(device, &addr, queue, listener)
        self.listener = listener
    }

    func stop() {
        guard let listener else { return }
        var addr = volumeAddr
        AudioObjectRemovePropertyListenerBlock(device, &addr, queue, listener)
        self.listener = nil
    }
}
