import Foundation
import SwiftUI

/// Top-down room layout in centimetres: the listener sits at the origin facing +y.
struct MonitorPlacement: Codable, Equatable {
    var x: Double
    var y: Double
    /// Rotation of the monitor's width axis, degrees counter-clockwise. 0 = square to the listener.
    var angle: Double

    /// Angle that turns the monitor's face toward the listener.
    var facingListener: Double { atan2(-x, y) * 180 / .pi }
}

struct RoomLayout: Codable, Equatable {
    var left = MonitorPlacement(x: -48, y: 62, angle: 0)
    var right = MonitorPlacement(x: 48, y: 62, angle: 0)

    /// S2725QC: 61 cm wide; speakers sit about 22 cm either side of centre.
    static let monitorWidth = 61.0
    static let speakerOffset = 22.0
    static let speedOfSound = 34.3 // cm per ms

    init() {
        left.angle = left.facingListener
        right.angle = right.facingListener
    }

    /// Position of a speaker. Each monitor's physical left speaker is at -offset along its width axis.
    func position(of speaker: Speaker) -> CGPoint {
        let (monitor, side): (MonitorPlacement, Double) = switch speaker {
        case .rearLeft: (left, -1)    // left monitor, outer (its left) speaker
        case .frontLeft: (left, 1)    // left monitor, inner (its right) speaker
        case .frontRight: (right, -1) // right monitor, inner (its left) speaker
        case .rearRight: (right, 1)   // right monitor, outer (its right) speaker
        }
        let a = monitor.angle * .pi / 180
        return CGPoint(x: monitor.x + side * Self.speakerOffset * cos(a), y: monitor.y + side * Self.speakerOffset * sin(a))
    }

    func distance(to speaker: Speaker) -> Double {
        let p = position(of: speaker)
        return (p.x * p.x + p.y * p.y).squareRoot()
    }

    /// Delays (ms, [L, R, Ls, Rs]) that make all four speakers arrive together: nearer speakers wait.
    var delays: [Double] {
        let distances = Speaker.allCases.map(distance(to:))
        let farthest = distances.max() ?? 0
        return distances.map { ((farthest - $0) / Self.speedOfSound * 100).rounded() / 100 }
    }

    static func load() -> RoomLayout {
        guard let data = UserDefaults.standard.data(forKey: "roomLayout"),
              let layout = try? JSONDecoder().decode(RoomLayout.self, from: data) else { return RoomLayout() }
        return layout
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "roomLayout")
    }
}
