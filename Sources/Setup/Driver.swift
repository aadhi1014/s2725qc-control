import Foundation

/// Installs, updates and removes the S2725QC virtual audio driver bundled inside this app.
enum DriverInstaller {
    enum Status: Equatable {
        case notInstalled, upToDate, differs, notBundled

        var description: String {
            switch self {
            case .notInstalled: "Not installed"
            case .upToDate: "Installed and up to date"
            case .differs: "Installed, but different from this app's version"
            case .notBundled: "This copy of the app doesn't include the driver"
            }
        }
    }

    static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/S2725QC.driver")
    static var bundled: URL? { Bundle.main.url(forResource: "S2725QC", withExtension: "driver") }

    private static func binary(_ driver: URL) -> Data? {
        try? Data(contentsOf: driver.appendingPathComponent("Contents/MacOS/S2725QC"))
    }

    static var status: Status {
        guard let bundled, let ours = binary(bundled) else { return .notBundled }
        guard let theirs = binary(installed) else { return .notInstalled }
        return ours == theirs ? .upToDate : .differs
    }

    /// Copies the bundled driver into /Library/Audio/Plug-Ins/HAL and restarts Core Audio.
    /// Shows the standard administrator password dialog. Blocking; call off the main thread.
    static func install() throws {
        guard let bundled else { throw Failure("This copy of the app doesn't include the driver.") }
        // Stage it outside the app first: privacy protection can stop the admin helper from reading
        // folders such as Desktop or Documents where the app might be running from.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("s2725qc-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("S2725QC.driver")
        try FileManager.default.copyItem(at: bundled, to: staged)
        try runAsAdmin("""
            rm -rf \(quoted(installed.path)) && \
            cp -R \(quoted(staged.path)) \(quoted(installed.deletingLastPathComponent().path))/ && \
            chown -R root:wheel \(quoted(installed.path)) && \
            killall coreaudiod
            """)
    }

    /// Removes the driver and restarts Core Audio. Blocking; call off the main thread.
    static func uninstall() throws {
        try runAsAdmin("rm -rf \(quoted(installed.path)) && killall coreaudiod")
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAsAdmin(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.contains("-128") { throw Failure("Cancelled.") }
            throw Failure(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
