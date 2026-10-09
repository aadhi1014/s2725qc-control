import Foundation

let args = CommandLine.arguments.dropFirst()
let displays = DDCDisplay.externalDisplays()
guard let display = displays.first else {
    FileHandle.standardError.write("No external DDC display found\n".data(using: .utf8)!)
    exit(1)
}

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
case ("get"?, let c?, _):
    if let v = display.read(c) { print("\(v.current)/\(v.max)") } else { print("read failed"); exit(2) }
case ("set"?, let c?, let v?):
    print(display.write(c, v) ? "ok" : "write failed")
default:
    print("usage: ddc get|set brightness|contrast|volume|mute [value]")
}
