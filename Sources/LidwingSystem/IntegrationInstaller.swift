import Foundation
import LidwingCore

/// Writes the coding-agent integrations to disk.
///
/// The transformations live in `LidwingCore` and are exhaustively tested. This is the part that
/// touches somebody else's file, and it follows the same six steps every time, in this order:
///
/// 1. **Read.**
/// 2. **Parse, preserving every unknown key.** On a parse failure, abort and write nothing.
/// 3. **Back up** to `<file>.lidwing-bak-<ISO8601>`.
/// 4. **Write a temp file in the same directory** — not in `/tmp`, or `rename(2)` would cross a
///    filesystem boundary and stop being atomic.
/// 5. **`fchmod` the temp to the original file's mode.** `~/.claude/settings.json` is 0600 on a
///    real machine, and rewriting it 0644 would leak whatever is in it to every other user.
/// 6. **`rename(2)`**, so a reader never sees a partial file.
public enum IntegrationInstaller {

    public enum Agent: String, CaseIterable, Sendable {
        case claude
        case codex

        public var relativePath: String {
            switch self {
            case .claude: return ".claude/settings.json"
            case .codex: return ".codex/config.toml"
            }
        }

        public var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            }
        }
    }

    public enum InstallError: Error {
        case cannotRead(String)
        case cannotParse(String)
        case cannotWrite(String)
        case notInstalled(Agent)
    }

    /// What will happen, computed without touching anything.
    ///
    /// Nothing is ever written to a third-party file that the user has not been offered the
    /// chance to read first. This is what the "Show what will be written" disclosure displays.
    public struct Preview {
        public let agent: Agent
        public let path: URL
        public let diff: String
        public let willChange: Bool
        /// For Codex: the command we are about to chain to, if any.
        public let displaced: [String]?
    }

    public static func url(for agent: Agent) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(agent.relativePath)
    }

    public static func isPresent(_ agent: Agent) -> Bool {
        FileManager.default.fileExists(atPath: url(for: agent).path)
    }

    // MARK: preview

    public static func previewInstall(_ agent: Agent, helperPath: String) throws -> Preview {
        let location = url(for: agent)
        let source = (try? String(contentsOf: location, encoding: .utf8)) ?? ""
        switch agent {
        case .claude:
            let patch = try ClaudeSettingsPatch.install(into: source, helperPath: helperPath)
            return Preview(agent: agent, path: location, diff: patch.diff,
                           willChange: patch.changed, displaced: nil)
        case .codex:
            let patch = try CodexConfigPatch.install(into: source, helperPath: helperPath)
            return Preview(agent: agent, path: location, diff: patch.diff,
                           willChange: patch.changed, displaced: patch.displaced)
        }
    }

    // MARK: install

    @discardableResult
    public static func install(_ agent: Agent, helperPath: String) throws -> Preview {
        let location = url(for: agent)
        guard FileManager.default.fileExists(atPath: location.path) else {
            // We never create a config file for a tool the user does not have. An empty
            // `~/.codex/config.toml` appearing out of nowhere is not our business to invent.
            throw InstallError.notInstalled(agent)
        }
        let source = try read(location)

        let text: String
        let preview: Preview
        switch agent {
        case .claude:
            let patch = try ClaudeSettingsPatch.install(into: source, helperPath: helperPath)
            text = patch.text
            preview = Preview(agent: agent, path: location, diff: patch.diff,
                              willChange: patch.changed, displaced: nil)
        case .codex:
            let patch = try CodexConfigPatch.install(into: source, helperPath: helperPath)
            text = patch.text
            preview = Preview(agent: agent, path: location, diff: patch.diff,
                              willChange: patch.changed, displaced: patch.displaced)
            if let displaced = patch.displaced {
                // Stored verbatim so uninstall restores exactly what was there, rather than a
                // reconstruction of it.
                UserDefaults.standard.set(displaced, forKey: displacedKey)
            }
        }

        guard preview.willChange else { return preview }
        try backUp(location)
        try writeAtomically(text, to: location)
        return preview
    }

    // MARK: uninstall

    @discardableResult
    public static func uninstall(_ agent: Agent) throws -> Bool {
        let location = url(for: agent)
        guard FileManager.default.fileExists(atPath: location.path) else { return false }
        let source = try read(location)

        let text: String
        switch agent {
        case .claude:
            let patch = try ClaudeSettingsPatch.uninstall(from: source)
            guard patch.changed else { return false }
            text = patch.text
        case .codex:
            let displaced = UserDefaults.standard.stringArray(forKey: displacedKey)
            let patch = CodexConfigPatch.uninstall(from: source, restoring: displaced)
            guard patch.changed else { return false }
            text = patch.text
            UserDefaults.standard.removeObject(forKey: displacedKey)
        }

        try backUp(location)
        try writeAtomically(text, to: location)
        return true
    }

    private static let displacedKey = "codexDisplacedNotify"

    // MARK: file mechanics

    // `internal` rather than `private` so the tests can exercise the real function. A test
    // that reimplements the code under test proves only that the copy works.
    static func read(_ location: URL) throws -> String {
        guard let text = try? String(contentsOf: location, encoding: .utf8) else {
            throw InstallError.cannotRead(location.path)
        }
        return text
    }

    /// A dated copy beside the original. Not overwritten: two installs on the same day should
    /// leave two backups, because the second one is the interesting one.
    static func backUp(_ location: URL) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let backup = location.deletingLastPathComponent()
            .appendingPathComponent("\(location.lastPathComponent)"
                                    + ".lidwing-bak-\(formatter.string(from: Date()))")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: location, to: backup)
    }

    /// Temp file in the same directory, original mode, then `rename(2)`.
    static func writeAtomically(_ text: String, to location: URL) throws {
        let directory = location.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(location.lastPathComponent).lidwing-tmp")

        // The original's mode, not a default. `~/.claude/settings.json` is 0600 on a real
        // machine, and a 0644 rewrite would leak it.
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(mode))
        guard descriptor >= 0 else { throw InstallError.cannotWrite(temporary.path) }
        var closed = false
        defer { if !closed { close(descriptor) } }

        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Foundation.write(descriptor, base.advanced(by: written),
                                              buffer.count - written)
                guard result > 0 else { throw InstallError.cannotWrite(temporary.path) }
                written += result
            }
        }
        guard fchmod(descriptor, mode_t(mode)) == 0 else {
            throw InstallError.cannotWrite(temporary.path)
        }
        _ = fcntl(descriptor, F_FULLFSYNC)
        close(descriptor)
        closed = true

        guard rename(temporary.path, location.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw InstallError.cannotWrite(location.path)
        }
    }
}
