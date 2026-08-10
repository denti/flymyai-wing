import Foundation
import LidwingCore

/// Where our own files live. One directory, mode 0700, under Application Support.
public enum SupportDirectory {
    public static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(LidwingID.supportDirectoryName, isDirectory: true)
    }

    /// Creates the directory, or checks the one that is already there.
    ///
    /// The check is the part that was missing. This used to return as soon as the path existed,
    /// so a directory created with any other mode kept it forever - restored from a backup that
    /// lost the mode, migrated by Setup Assistant, or made by hand. Everything Lidwing knows
    /// lives in here, including an audit log of when this Mac was awake and which agent
    /// binaries ran.
    /// - Parameter directory: the directory to create or check. Defaults to the real one; the
    ///   parameter exists so the tests can run against a sandbox rather than against the state
    ///   of the machine running them.
    @discardableResult
    public static func ensure(at directory: URL = SupportDirectory.url) -> Bool {
        let path = directory.path

        // `lstat`, not `fileExists`: that follows symlinks, so a symlink pointing anywhere at
        // all reports a perfectly good directory. Writing our state through somebody else's
        // symlink is not something to accept quietly, and it is not something we can repair
        // either - refusing is the honest answer, and the caller degrades to no ledger rather
        // than to a ledger somewhere unexpected.
        var status = stat()
        if lstat(path, &status) == 0 {
            // Everything through `Int`. `st_mode` is `mode_t` (UInt16) while `S_IFMT` and
            // friends import as `Int32`, and mixing them is a type error rather than a warning.
            let kind = Int(status.st_mode) & Int(S_IFMT)
            if kind == Int(S_IFLNK) { return false }
            guard kind == Int(S_IFDIR) else { return false }
            let mode = Int(status.st_mode) & 0o7777
            if StatePermissions.isTooOpen(mode) {
                // Repair rather than refuse: this is our own directory, the user did not
                // choose its mode, and refusing would disable the product over something we
                // can simply fix.
                _ = chmod(path, mode_t(StatePermissions.tightened(mode)))
            }
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: StatePermissions.directoryMode])
            return true
        } catch {
            return false
        }
    }

    public static func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

/// Durable intent, written before the first mutation.
///
/// `F_FULLFSYNC`, not `fsync`. Plain `fsync` on APFS does not flush the device write cache, so
/// a panic loses the record — and a panic while armed is precisely the case the ledger exists
/// to survive. Then `rename(2)`, so a reader never sees a half-written file.
public final class FileLedgerStore: LedgerStore {
    private let url: URL

    public init(url: URL = SupportDirectory.file(LidwingID.ledgerFileName)) {
        self.url = url
    }

    public func read() -> Data? {
        try? Data(contentsOf: url)
    }

    public func write(_ ledger: Ledger) throws {
        SupportDirectory.ensure()
        let data = try ledger.encoded()
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw LedgerError.cannotOpen(errno) }
        defer { close(descriptor) }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Foundation.write(descriptor, base.advanced(by: written),
                                              buffer.count - written)
                guard result > 0 else { throw LedgerError.cannotWrite(errno) }
                written += result
            }
        }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw LedgerError.cannotSync(errno) }
        guard rename(temporary.path, url.path) == 0 else { throw LedgerError.cannotRename(errno) }
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    public enum LedgerError: Error {
        case cannotOpen(Int32)
        case cannotWrite(Int32)
        case cannotSync(Int32)
        case cannotRename(Int32)
    }
}

/// Append-only audit log, one JSON object per line.
///
/// Appends are `O_APPEND` single writes, which the kernel keeps atomic for a write smaller than
/// the pipe buffer — a record is either wholly present or wholly absent, never interleaved.
public final class FileAuditSink: AuditSink {
    private let url: URL
    private let queue = DispatchQueue(label: "ai.flymy.lidwing.audit")
    /// Trim the file when it exceeds this. An audit log that grows without bound on a machine
    /// that arms twice a day is a slow disk leak, and nobody reads the entries from last year.
    private let maximumBytes = 512 * 1024

    public init(url: URL = SupportDirectory.file(LidwingID.auditFileName)) {
        self.url = url
    }

    public func append(_ record: AuditRecord) {
        guard let line = try? record.jsonLine() else { return }
        appendLine(line)
    }

    public func note(_ failure: AuditFailure, at date: Date, context: [String: String]) {
        var payload: [String: Any] = [
            "event": failure.rawValue,
            "at": date.timeIntervalSince1970.rounded()
        ]
        for (key, value) in context { payload[key] = value }
        guard var data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return }
        data.append(0x0A)
        appendLine(data)
    }

    private func appendLine(_ data: Data) {
        queue.async { [url, maximumBytes] in
            SupportDirectory.ensure()
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)

            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int, size > maximumBytes {
                Self.trim(url: url, keepingBytes: maximumBytes / 2)
            }
        }
    }

    /// Keep the newest whole lines. Never truncate mid-record: a half line breaks every reader.
    private static func trim(url: URL, keepingBytes: Int) {
        guard let data = try? Data(contentsOf: url), data.count > keepingBytes else { return }
        let tail = data.suffix(keepingBytes)
        guard let firstNewline = tail.firstIndex(of: 0x0A) else { return }
        let whole = tail[tail.index(after: firstNewline)...]
        try? Data(whole).write(to: url, options: .atomic)
    }

    /// Records for the diagnostics panel, newest first.
    public func recentRecords(limit: Int = 3) -> [AuditRecord] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.split(separator: "\n")
            .reversed()
            .compactMap { try? decoder.decode(AuditRecord.self, from: Data($0.utf8)) }
            .prefix(limit)
            .map { $0 }
    }
}
