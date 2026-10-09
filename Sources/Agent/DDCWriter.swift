import Foundation

/// Sends values to the monitor over DDC/CI on a dedicated thread.
/// Only the latest requested value per control is written, so holding a key or
/// dragging a slider never queues up lag.
final class DDCWriter {
    private let lock = NSLock()
    private var pending: [VCP: UInt16] = [:]
    private var lastWritten: [VCP: UInt16] = [:]
    private let wake = DispatchSemaphore(value: 0)
    private var display: DDCDisplay?

    init() {
        let thread = Thread { [unowned self] in self.run() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func submit(_ code: VCP, _ value: UInt16) {
        lock.lock()
        let wasIdle = pending.isEmpty
        pending[code] = value
        lock.unlock()
        if wasIdle { wake.signal() }
    }

    /// Reads a control as a 0...1 fraction (blocking; call off the main thread).
    func read(_ code: VCP) -> Float32? {
        guard let display = currentDisplay(), let v = display.read(code), v.max > 0 else { return nil }
        lock.lock(); lastWritten[code] = v.current; lock.unlock()
        return Float32(v.current) / Float32(v.max)
    }

    private func currentDisplay() -> DDCDisplay? {
        lock.lock(); defer { lock.unlock() }
        if display == nil { display = DDCDisplay.externalDisplays().first }
        return display
    }

    private func run() {
        while true {
            wake.wait()
            while true {
                lock.lock()
                guard let (code, value) = pending.first else { lock.unlock(); break }
                pending[code] = nil
                let skip = lastWritten[code] == value
                lock.unlock()
                if skip { continue }
                if let display = currentDisplay(), display.write(code, value) {
                    lock.lock(); lastWritten[code] = value; lock.unlock()
                } else {
                    log("DDC write failed; will rediscover display")
                    lock.lock(); display = nil; lock.unlock()
                }
            }
        }
    }
}
