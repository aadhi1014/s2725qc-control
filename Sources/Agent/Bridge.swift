import CoreAudio
import Foundation

/// Plays everything sent to the virtual device out of the monitor's DisplayPort audio.
///
/// The driver publishes its mixed output in a shared-memory ring (Sources/ShmRing); this
/// runs an output-only IOProc on the monitor that drains it. Nothing is captured, so macOS
/// shows no microphone indicator.
final class Bridge {
    let dell: AudioObjectID
    private var procID: AudioDeviceIOProcID?

    init?(dell: AudioObjectID, virtual: AudioObjectID) {
        self.dell = dell

        // Match the virtual device's sample rate to the monitor's; the ring carries no rate conversion.
        let rateAddr = HAL.address(kAudioDevicePropertyNominalSampleRate)
        if let rate = HAL.get(dell, rateAddr, Float64(0)) {
            HAL.set(virtual, rateAddr, rate)
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, dell, nil) { _, _, _, outputData, _ in
            let first = outputData.pointee.mBuffers
            let bytesPerFrame = max(1, Int(first.mNumberChannels)) * MemoryLayout<Float32>.size
            ddpm_reader_render(outputData, UInt32(Int(first.mDataByteSize) / bytesPerFrame))
        }
        guard status == noErr, procID != nil else {
            log("failed to create audio bridge (status \(status))")
            return nil
        }
        log("audio bridge ready (\(HAL.outputChannelCount(dell))ch)")
    }

    /// Whether the monitor output IOProc is running. Kept off while nothing plays to save power.
    private(set) var isRunning = false

    func setRunning(_ running: Bool) {
        guard running != isRunning, let procID else { return }
        if running {
            guard ddpm_reader_open() else {
                log("shared audio ring unavailable; is the S2725QC driver installed and loaded?")
                return
            }
            isRunning = AudioDeviceStart(dell, procID) == noErr
        } else {
            AudioDeviceStop(dell, procID)
            isRunning = false
        }
        log(isRunning ? "audio bridge started" : "audio bridge idle")
    }

    func destroy() {
        setRunning(false)
        if let procID { AudioDeviceDestroyIOProcID(dell, procID) }
        procID = nil
    }
}

func log(_ message: String) {
    FileHandle.standardError.write("[ddpm] \(message)\n".data(using: .utf8)!)
}
