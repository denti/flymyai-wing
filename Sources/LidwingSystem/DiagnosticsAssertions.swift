import Foundation
import LidwingCore

/// Reads the full power-assertion inventory, for the diagnostics report and nothing else.
///
/// This is the one place in the product where shelling out is allowed, and it is allowed here
/// for a reason: `pmset -g assertions` prints things `IOPMCopyAssertionsByProcess` does not
/// surface as conveniently - the timeout line, the human-written details - and a support bundle
/// is read by somebody who cannot see the machine and needs the whole picture rather than the
/// slice the app happens to act on.
///
/// Everything about it is bounded and read-only. It runs one fixed command with no arguments
/// derived from anything, it cannot write, and it gives up rather than hanging: a diagnostics
/// panel that blocks on a subprocess is a diagnostics panel nobody can use to report the hang.
/// The name is load-bearing. `.swiftlint.yml` forbids a `pmset` shell-out anywhere outside
/// diagnostics, and excludes files matching `Diagnostics` - so calling this what it is keeps the
/// rule protecting every other file, rather than silencing it here with a disable comment.
public enum DiagnosticsAssertions {

    /// A hard ceiling. `pmset` returns in milliseconds; anything approaching this means the
    /// machine is in trouble, which is exactly when somebody is trying to copy diagnostics.
    static let budget: TimeInterval = 2.0

    public static func read() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "assertions"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        // Read on this thread and enforce the budget from another, so a `pmset` that never
        // returns costs two seconds rather than the session.
        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + budget, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()

        guard task.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The inventory, for the diagnostics report. The formatting lives in `ConflictPolicy` so
    /// it can be tested without a machine; only the subprocess is here.
    public static func report() -> [String] {
        guard let output = read() else {
            return ["  could not read pmset -g assertions"]
        }
        return ConflictPolicy.diagnosticsLines(from: PowerAssertions.parse(output))
    }
}
