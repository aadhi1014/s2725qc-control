import CoreAudio
import Foundation

/// Plays everything sent to the virtual device (or one channel of it) out of a monitor's DisplayPort audio.
///
/// The driver publishes its mixed output in a shared-memory ring (Sources/ShmRing); this
/// runs an output-only IOProc on the monitor that drains it. Nothing is captured, so macOS
/// shows no microphone indicator.
final class Bridge {
    let dell: AudioObjectID
    let channel: DDPMChannel
    private var procID: AudioDeviceIOProcID?
    private let reader: OpaquePointer

    init?(dell: AudioObjectID, virtual: AudioObjectID, channel: DDPMChannel) {
        self.dell = dell
        self.channel = channel
        let reader = ddpm_reader_create(channel)!
        self.reader = reader

        // Match the virtual device's sample rate to the monitor's; the ring carries no rate conversion.
        let rateAddr = HAL.address(kAudioDevicePropertyNominalSampleRate)
        if let rate = HAL.get(dell, rateAddr, Float64(0)) {
            HAL.set(virtual, rateAddr, rate)
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, dell, nil) { _, _, _, outputData, _ in
            let first = outputData.pointee.mBuffers
            let bytesPerFrame = max(1, Int(first.mNumberChannels)) * MemoryLayout<Float32>.size
            ddpm_reader_render(reader, outputData, UInt32(Int(first.mDataByteSize) / bytesPerFrame))
        }
        guard status == noErr, procID != nil else {
            log("failed to create audio bridge (status \(status))")
            ddpm_reader_destroy(reader)
            return nil
        }
    }

    /// Whether the monitor output IOProc is running. Kept off while nothing plays to save power.
    private(set) var isRunning = false

    func setRunning(_ running: Bool) {
        guard running != isRunning, let procID else { return }
        if running {
            guard ddpm_ring_open() else {
                log("shared audio ring unavailable; is the S2725QC driver installed and loaded?")
                return
            }
            isRunning = AudioDeviceStart(dell, procID) == noErr
        } else {
            AudioDeviceStop(dell, procID)
            isRunning = false
        }
    }

    func destroy() {
        setRunning(false)
        if let procID {
            AudioDeviceDestroyIOProcID(dell, procID)
            ddpm_reader_destroy(reader)
        }
        procID = nil
    }
}

func log(_ message: String) {
    FileHandle.standardError.write("[ddpm] \(message)\n".data(using: .utf8)!)
}
