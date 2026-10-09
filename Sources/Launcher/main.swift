// Stable launcher: loads the agent library that sits next to the app bundle.
// Keeping this binary unchanged keeps the app's code signature, and therefore its
// Accessibility permission, valid across agent rebuilds.
import Foundation

let library = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("libS2725QCAgent.dylib").path
guard let handle = dlopen(library, RTLD_NOW) else {
    FileHandle.standardError.write("[ddpm] cannot load \(library): \(String(cString: dlerror()))\n".data(using: .utf8)!)
    exit(1)
}
typealias Entry = @convention(c) () -> Void
unsafeBitCast(dlsym(handle, "agent_main"), to: Entry.self)()
