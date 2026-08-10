import Foundation
import Darwin
import LidwingCore

/// Finds running coding agents.
///
/// Two rules, both non-negotiable:
///
/// 1. **Same uid only.** We list our own user's processes and nothing else. Enumerating other
///    users' processes is not needed for anything this product does.
/// 2. **By executable basename**, from the process table. Never by resolving `$PATH`: a
///    GUI-launched app inherits a minimal `PATH` and will not find `claude`, `codex` or
///    `cursor-agent`, all of which commonly live in `~/.local/bin`. And never by shelling out
///    to a login shell to resolve it — that is slow and it hangs on a bad `zshrc`.
///
/// This reads process names. It never reads another process's memory, arguments, environment
/// or files.
public enum ProcessScanner {

    /// The binaries we consider "a coding agent is running".
    public static let defaultAgentNames: Set<String> = ["claude", "codex", "cursor-agent"]

    /// Basenames of the current user's running executables that match `names`.
    public static func runningAgents(named names: Set<String> = defaultAgentNames) -> Set<String> {
        let ourUID = getuid()
        var found: Set<String> = []

        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                      Int32(pids.count * MemoryLayout<pid_t>.size))
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size

        var pathBuffer = [CChar](repeating: 0, count: Int(PROC_PIDPATHINFO_MAXSIZE))
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            guard uid(of: pid) == ourUID else { continue }

            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(cString: pathBuffer)
            // Exact basename match. `claude-something-else` is not Claude Code, and matching
            // it would arm the machine for an unrelated tool.
            let name = (path as NSString).lastPathComponent
            if names.contains(name) { found.insert(name) }
        }
        return found
    }

    private static func uid(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard result == size else { return nil }
        return info.pbi_uid
    }

    /// Which agents are installed, detected by configuration directory.
    ///
    /// By directory, not by `$PATH`, for the same reason as above.
    public static func installedAgents() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var installed: Set<String> = []
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) {
            installed.insert("claude")
        }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) {
            installed.insert("codex")
        }
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path) {
            installed.insert("cursor-agent")
        }
        return installed
    }
}
