// Draws the S2725QC Speaker Setup app icon: two monitors turned toward a listener, their four
// speakers (same colours as the Setup window) and sound paths meeting at the listener.
// Usage: swift make-icon.swift <out.png>   (1024×1024; build.sh turns it into an .icns)
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: macOS icon grid (824 pt body on a 1024 canvas) with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle)
ctx.setFillColor(color(0x1E3A8A))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let background = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [color(0x4F46E5), color(0x1E3A8A), color(0x0F1B4C)] as CFArray,
                            locations: [0, 0.55, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Gentle top highlight.
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])

let listener = CGPoint(x: 512, y: 268)
let speakerColors: [UInt32] = [0x0A84FF, 0xFF9F0A, 0x30D5C8, 0xFF375F] // L, R, Ls, Rs

func path(_ points: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: points)
    p.closeSubpath()
    return p
}

/// A monitor drawn in perspective, turned toward the listener: its outer edge is nearer, so taller.
struct Monitor {
    let outerX: CGFloat, innerX: CGFloat, centerY: CGFloat
    let outerHalf = 132.0, innerHalf = 106.0

    /// Point on the bezel at horizontal fraction t (0 = outer edge, 1 = inner) and height v (-1 bottom ... 1 top).
    func at(_ t: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: outerX + (innerX - outerX) * t, y: centerY + v * (outerHalf + (innerHalf - outerHalf) * t))
    }

    var outerSpeaker: CGPoint { at(0.13, -0.82) }
    var innerSpeaker: CGPoint { at(0.87, -0.82) }
}

func draw(_ m: Monitor) {
    let at = m.at
    let centerY = m.centerY, outerHalf = m.outerHalf
    // Stand.
    let foot = at(0.5, -1)
    ctx.setFillColor(color(0xC7CCD9))
    ctx.fill(CGRect(x: foot.x - 16, y: foot.y - 70, width: 32, height: 74))
    ctx.addPath(CGPath(roundedRect: CGRect(x: foot.x - 66, y: foot.y - 84, width: 132, height: 20),
                       cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.fillPath()
    // Bezel.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0x000000, 0.4))
    ctx.setLineJoin(.round)
    ctx.setLineWidth(26)
    ctx.setStrokeColor(color(0xF2F4F8))
    ctx.setFillColor(color(0xF2F4F8))
    let bezel = path([at(0, -1), at(1, -1), at(1, 1), at(0, 1)])
    ctx.addPath(bezel); ctx.fillPath()
    ctx.addPath(bezel); ctx.strokePath()
    ctx.restoreGState()
    // Screen, inset from the bezel with a thicker chin for the speakers.
    ctx.saveGState()
    let screen = path([at(0.05, -0.62), at(0.95, -0.62), at(0.95, 0.9), at(0.05, 0.9)])
    ctx.addPath(screen)
    ctx.clip()
    let glass = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0x34467D), color(0x101828)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glass, start: CGPoint(x: 0, y: centerY + outerHalf), end: CGPoint(x: 0, y: centerY - outerHalf), options: [])
    ctx.restoreGState()
}

func speaker(_ p: CGPoint, _ hex: UInt32) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: color(hex, 0.9))
    ctx.setFillColor(color(hex))
    ctx.fillEllipse(in: CGRect(x: p.x - 19, y: p.y - 19, width: 38, height: 38))
    ctx.restoreGState()
}

let left = Monitor(outerX: 186, innerX: 478, centerY: 640)
let right = Monitor(outerX: 838, innerX: 546, centerY: 640)
let speakers: [(CGPoint, UInt32)] = [(left.innerSpeaker, speakerColors[0]), (right.innerSpeaker, speakerColors[1]),
                                     (left.outerSpeaker, speakerColors[2]), (right.outerSpeaker, speakerColors[3])]

// Sound paths first (they pass behind the stands), then the monitors, then the speaker dots.
for (p, hex) in speakers {
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineWidth(11)
    ctx.move(to: p)
    ctx.addLine(to: listener)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(hex, 0.3), color(hex, 0.95)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fade, start: p, end: listener, options: [])
    ctx.restoreGState()
}
draw(left)
draw(right)
for (p, hex) in speakers { speaker(p, hex) }

// Listener.
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 30, color: color(0xFFFFFF, 0.6))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: listener.x - 50, y: listener.y - 50, width: 100, height: 100))
ctx.restoreGState()
ctx.setFillColor(color(0x1E3A8A))
ctx.fillEllipse(in: CGRect(x: listener.x - 16, y: listener.y - 16, width: 32, height: 32))

ctx.restoreGState()
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
