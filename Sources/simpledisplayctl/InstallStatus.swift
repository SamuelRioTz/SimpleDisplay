import Foundation

struct InstallStatus {
    let installed: Bool
    let path: String?
    let running: Bool
    let pid: Int?

    static func detect() -> InstallStatus {
        let path = appBundlePath()
        return InstallStatus(
            installed: path != nil,
            path: path,
            running: processID() != nil,
            pid: processID()
        )
    }

    /// Checks the standard install locations. `/Applications` first (system-wide
    /// cask/DMG install), then `~/Applications` (per-user).
    private static func appBundlePath() -> String? {
        let candidates = [
            "/Applications/SimpleDisplay.app",
            ("~/Applications/SimpleDisplay.app" as NSString).expandingTildeInPath,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Shells out to `pgrep -x SimpleDisplay`. Picked over `NSRunningApplication`
    /// because that API only surfaces apps we're entitled to see — for a CLI
    /// that may run outside the user's GUI session, pgrep is more reliable.
    private static func processID() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "SimpleDisplay"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let line = text.split(whereSeparator: \.isNewline).first ?? ""
        return Int(line)
    }
}
