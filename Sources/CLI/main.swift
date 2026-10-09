import Foundation

import CoreGraphics

// Optional "-d N": pick a monitor by position, 0 = leftmost (as arranged in System Settings).
var args = Array(CommandLine.arguments.dropFirst())
var index = 0
if args.first == "-d", args.count > 1, let n = Int(args[1]) {
    index = n
    args.removeFirst(2)
}

func leftEdge(_ display: DDCDisplay) -> CGFloat {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    let id = ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) == 0 && CGDisplaySerialNumber($0) == display.edidSerial }
    return id.map { CGDisplayBounds($0).minX } ?? .greatestFiniteMagnitude
}

let displays = DDCDisplay.externalDisplays().sorted { leftEdge($0) < leftEdge($1) }
guard displays.indices.contains(index) else {
    FileHandle.standardError.write("No external DDC display #\(index) (found \(displays.count))\n".data(using: .utf8)!)
    exit(1)
}
let display = displays[index]

func code(_ s: String) -> VCP? {
    switch s {
    case "brightness": return .brightness
    case "contrast": return .contrast
    case "volume": return .volume
    case "mute": return .mute
    default: return nil
    }
}

switch (args.first, args.dropFirst().first.flatMap(code), args.dropFirst(2).first.flatMap { UInt16($0) }) {
case ("list"?, _, _):
    for (i, d) in displays.enumerated() { print("\(i): \(d.port) serial \(d.edidSerial)") }
case ("get"?, let c?, _):
    if let v = display.read(c) { print("\(v.current)/\(v.max)") } else { print("read failed"); exit(2) }
case ("set"?, let c?, let v?):
    print(display.write(c, v) ? "ok" : "write failed")
default:
    print("usage: ddc [-d N] get|set brightness|contrast|volume|mute [value]\n       ddc list")
}
