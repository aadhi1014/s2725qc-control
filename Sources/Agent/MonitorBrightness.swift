import Foundation

/// The monitor's brightness (0...1), shared by the brightness keys and the menu bar slider.
/// Main thread only.
final class MonitorBrightness {
    private let writer: DDCWriter
    private(set) var value: Float32 = 1
    var onChange: ((Float32) -> Void)?

    init(writer: DDCWriter) {
        self.writer = writer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let value = writer.read(.brightness) else { return }
            DispatchQueue.main.async {
                self?.value = value
                self?.onChange?(value)
            }
        }
    }

    func set(_ newValue: Float32) {
        value = min(max(newValue, 0), 1)
        writer.submit(.brightness, UInt16((value * 100).rounded()))
        onChange?(value)
    }
}
