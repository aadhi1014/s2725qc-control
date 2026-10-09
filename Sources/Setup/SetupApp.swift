// S2725QC Setup: place the monitors in a top-down room view, test each speaker, and sync the
// four speakers either from the drawn layout or by measuring them with the built-in microphone.
// A normal windowed app: launched when needed, quits when its window closes.
import AppKit
import SwiftUI

@main
struct SetupApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("S2725QC Speaker Setup", id: "setup") {
            SetupView()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class SetupModel: ObservableObject {
    @Published var layout = RoomLayout.load() { didSet { layout.save() } }
    @Published var applied = VirtualDevice.delays
    @Published var source = UserDefaults.standard.string(forKey: "delaySource") ?? "none" {
        didSet { UserDefaults.standard.set(source, forKey: "delaySource") }
    }
    /// Arrival offsets (ms, relative to the earliest speaker) from the last microphone run.
    @Published var before: [Double]?
    @Published var after: [Double]?
    @Published var busy = false
    @Published var progress = 0.0
    @Published var message = ""

    var deviceInstalled: Bool { VirtualDevice.id != nil }

    func faceListener() {
        layout.left.angle = layout.left.facingListener
        layout.right.angle = layout.right.facingListener
    }

    func syncFromLayout() {
        apply(layout.delays, source: "layout")
        before = nil
        after = nil
        message = "Synced from the layout: nearer speakers wait for the farthest one."
    }

    func resetDelays() {
        apply([0, 0, 0, 0], source: "none")
        before = nil
        after = nil
        message = "Delays cleared."
    }

    private func apply(_ delays: [Double], source: String) {
        VirtualDevice.delays = delays
        applied = delays
        self.source = source
    }

    func calibrate() {
        busy = true
        progress = 0
        message = "Measuring… keep the room quiet."
        let savedVolume = VirtualDevice.volume
        let current = applied
        Task.detached { [self] in
            let report: @Sendable (Double) -> Void = { p in Task { @MainActor in self.progress = p } }
            VirtualDevice.volume = (0.25, false)
            defer { VirtualDevice.volume = savedVolume }
            do {
                // 1. Measure with the current delays, 2. apply corrections, 3. measure again to verify.
                let first = try Calibrator.measure(rounds: 4) { report($0 * 0.5) }
                let latest = first.max()!
                let raw = (0..<4).map { current[$0] + (latest - first[$0]) }
                let common = raw.min()!
                let delays = raw.map { (($0 - common) * 100).rounded() / 100 }
                await MainActor.run { self.apply(delays, source: "microphone") }
                try await Task.sleep(for: .milliseconds(400))
                let second = try Calibrator.measure(rounds: 4) { report(0.5 + $0 * 0.5) }
                let spread = second.max()! - second.min()!
                await MainActor.run {
                    self.before = first.map { $0 - first.min()! }
                    self.after = second.map { $0 - second.min()! }
                    self.message = String(format: "Synced with the microphone: all four speakers within %.2f ms.", spread)
                    self.busy = false
                }
            } catch {
                let text = error.localizedDescription
                await MainActor.run {
                    self.message = text
                    self.busy = false
                }
            }
        }
    }
}

struct SetupView: View {
    @StateObject private var model = SetupModel()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Room layout").font(.headline)
                Text("Drag a monitor to move it, drag its round handle to turn it.")
                    .font(.callout).foregroundStyle(.secondary)
                RoomView(layout: $model.layout)
                HStack {
                    Button("Face me", action: model.faceListener)
                    Spacer()
                    Text("Left and right follow System Settings → Displays → Arrange.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Speakers").font(.headline)
                SpeakerTable(model: model)
                Divider()
                Text("Sync").font(.headline)
                HStack {
                    Button("Sync from layout", action: model.syncFromLayout)
                    Button("Calibrate with microphone…", action: model.calibrate)
                        .buttonStyle(.borderedProminent)
                }
                .disabled(model.busy || !model.deviceInstalled)
                Text("Calibration plays short sweeps at 25% volume for about 20 seconds and listens with the Mac's microphone. Keep the Mac where it usually sits.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.busy {
                    ProgressView(value: model.progress)
                }
                if !model.deviceInstalled {
                    Text("The S2725QC virtual device isn't installed.").foregroundStyle(.red)
                } else if !model.message.isEmpty {
                    Text(model.message).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack {
                    Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset delays", action: model.resetDelays).disabled(model.busy)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
        .frame(height: 520)
    }

    private var sourceDescription: String {
        switch model.source {
        case "microphone": "Current delays: measured with the microphone"
        case "layout": "Current delays: from the layout"
        default: "No delays applied"
        }
    }
}

struct SpeakerTable: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Speaker")
                Text("Distance").gridColumnAlignment(.trailing)
                Text("Delay").gridColumnAlignment(.trailing)
                if model.before != nil { Text("Before → after").gridColumnAlignment(.trailing) }
                Text("")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(Speaker.allCases) { speaker in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(speaker.name)
                        Text(speaker.place).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(Int(model.layout.distance(to: speaker).rounded())) cm").monospacedDigit()
                    Text(String(format: "%.2f ms", model.applied[speaker.rawValue])).monospacedDigit()
                    if let before = model.before, let after = model.after {
                        Text(String(format: "+%.2f → +%.2f", before[speaker.rawValue], after[speaker.rawValue]))
                            .monospacedDigit().font(.callout)
                    }
                    Button("Test") { SignalPlayer.test(speaker) }
                        .controlSize(.small)
                        .disabled(model.busy || !model.deviceInstalled)
                }
            }
        }
    }
}

/// Top-down view: listener at the bottom centre, monitors draggable and rotatable.
struct RoomView: View {
    @Binding var layout: RoomLayout

    private let size = CGSize(width: 420, height: 380)
    private let scale = 3.2 // points per cm
    private var origin: CGPoint { CGPoint(x: size.width / 2, y: size.height - 46) }

    private func toView(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y - y * scale)
    }

    private func toModel(_ p: CGPoint) -> (Double, Double) {
        ((p.x - origin.x) / scale, (origin.y - p.y) / scale)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor))

            // Sound paths from each speaker to the listener.
            ForEach(Speaker.allCases) { speaker in
                let p = layout.position(of: speaker)
                Path { path in
                    path.move(to: origin)
                    path.addLine(to: toView(p.x, p.y))
                }
                .stroke(color(speaker).opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            monitor($layout.left, label: "Left")
            monitor($layout.right, label: "Right")

            ForEach(Speaker.allCases) { speaker in
                let p = layout.position(of: speaker)
                ZStack {
                    Circle().fill(color(speaker)).frame(width: 18, height: 18)
                    Text(speaker.short).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                }
                .position(toView(p.x, p.y))
                .allowsHitTesting(false)
            }

            VStack(spacing: 2) {
                Image(systemName: "person.fill").font(.title2)
                Text("You").font(.caption)
            }
            .position(x: origin.x, y: origin.y + 20)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "room")
    }

    private func color(_ speaker: Speaker) -> Color {
        [Color.blue, .orange, .teal, .pink][speaker.rawValue]
    }

    @ViewBuilder
    private func monitor(_ placement: Binding<MonitorPlacement>, label: String) -> some View {
        let m = placement.wrappedValue
        let center = toView(m.x, m.y)
        let a = m.angle * .pi / 180
        // The handle sits behind the monitor (away from the listener).
        let back = CGPoint(x: center.x - 30 * sin(a), y: center.y - 30 * cos(a))

        RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.75))
            .frame(width: RoomLayout.monitorWidth * scale, height: 12)
            .overlay(Text(label).font(.caption2.bold()).foregroundStyle(Color(nsColor: .windowBackgroundColor)))
            .rotationEffect(.degrees(-m.angle))
            .position(center)
            .gesture(DragGesture(coordinateSpace: .named("room")).onChanged { value in
                let (x, y) = toModel(value.location)
                placement.wrappedValue.x = min(max(x, -65), 65).rounded()
                placement.wrappedValue.y = min(max(y, 10), 105).rounded()
            })

        Path { path in
            path.move(to: center)
            path.addLine(to: back)
        }
        .stroke(Color.secondary, lineWidth: 1)
        .allowsHitTesting(false)

        Circle()
            .fill(Color.accentColor)
            .frame(width: 14, height: 14)
            .position(back)
            .gesture(DragGesture(coordinateSpace: .named("room")).onChanged { value in
                // Pointer direction from the centre is the monitor's back; the width axis is 90° from it.
                let dx = value.location.x - center.x, dy = center.y - value.location.y
                let degrees = atan2(dy, dx) * 180 / .pi - 90
                placement.wrappedValue.angle = (degrees * 2).rounded() / 2
            })
            .help("Drag to turn the monitor")
    }
}
