import Foundation

/// Installs and removes exactly one hook in `~/.claude/settings.json`.
///
/// The discipline here applies to every third-party file this product touches, and it is not
/// negotiable: **parse preserving every unknown key; on a parse failure abort and write
/// nothing; back up before writing; preserve the file's mode.** Someone else's configuration
/// is not ours to normalise, reformat or repair.
///
/// The hook installed is `Notification`, whose matcher filters on `notification_type`, so it
/// fires when the agent is *blocked* and not when it breathes. `Stop` is offered separately and
/// defaults off — users want to know when they are needed, not when a task ended.
/// `PermissionRequest` is a *decision* hook and must never carry this helper: a notifier that
/// can accidentally answer a permission prompt is a security bug.
public enum ClaudeSettingsPatch {

    public static let hookKey = "hooks"
    public static let eventKey = "Notification"
    /// Fires only on the notification types that mean a human is needed.
    public static let matcher = "permission_prompt|idle_prompt|agent_needs_input"

    public enum PatchError: Error, Equatable {
        case unparseable(JSONParseError)
        /// The top level is not a JSON object, so there is nowhere to put a hook.
        case notAnObject
        /// The existing `hooks` value is not shaped the way Claude Code documents.
        case unexpectedShape(String)
    }

    /// The result of a patch: the new text, and whether anything actually changed.
    public struct Patch: Equatable {
        public let text: String
        public let changed: Bool
        /// A human-readable diff, shown before anything is written. Nothing is written to a
        /// third-party file that the user has not been offered the chance to read first.
        public let diff: String
    }

    /// Adds our hook, preserving everything else.
    ///
    /// - Parameter helperPath: the absolute path of `lidwing-notify` inside the app bundle. It
    ///   contains `/Lidwing.app/`, which is what the uninstaller matches on.
    public static func install(into source: String, helperPath: String) throws -> Patch {
        var root = try parseObject(source)
        let before = OrderedJSON.serialise(root, indent: OrderedJSON.detectIndent(source))

        var hooks = root[hookKey] ?? .object([])
        guard case .object = hooks else {
            throw PatchError.unexpectedShape("hooks is not an object")
        }

        var entries = hooks[eventKey]?.arrayValue ?? []
        if hooks[eventKey] != nil && hooks[eventKey]?.arrayValue == nil {
            throw PatchError.unexpectedShape("hooks.\(eventKey) is not an array")
        }

        // Idempotent: replace our own entry rather than appending a second one. Running the
        // installer twice must produce a byte-identical file.
        entries.removeAll { isOurs($0) }
        entries.append(ourEntry(helperPath: helperPath))

        hooks[eventKey] = .array(entries)
        root[hookKey] = hooks

        let indent = OrderedJSON.detectIndent(source)
        let after = OrderedJSON.serialise(root, indent: indent)
        return Patch(text: after, changed: after != before,
                     diff: lineDiff(before: before, after: after))
    }

    /// Removes our hook and nothing else.
    public static func uninstall(from source: String) throws -> Patch {
        var root = try parseObject(source)
        let indent = OrderedJSON.detectIndent(source)
        let before = OrderedJSON.serialise(root, indent: indent)

        guard var hooks = root[hookKey], case .object = hooks,
              var entries = hooks[eventKey]?.arrayValue else {
            return Patch(text: before, changed: false, diff: "")
        }

        let originalCount = entries.count
        entries.removeAll { isOurs($0) }
        guard entries.count != originalCount else {
            return Patch(text: before, changed: false, diff: "")
        }

        // Leave no empty scaffolding behind: a `"Notification": []` we created and then
        // emptied is residue, and residue is what an uninstaller exists to avoid.
        if entries.isEmpty {
            hooks[eventKey] = nil
        } else {
            hooks[eventKey] = .array(entries)
        }
        if case .object(let remaining) = hooks, remaining.isEmpty {
            root[hookKey] = nil
        } else {
            root[hookKey] = hooks
        }

        let after = OrderedJSON.serialise(root, indent: indent)
        return Patch(text: after, changed: true, diff: lineDiff(before: before, after: after))
    }

    /// True when this hook entry is ours. Matched on the bundle-path marker rather than on a
    /// key we invented, so it cannot collide with a third-party tool that merely mentions us.
    public static func isOurs(_ entry: JSONValue) -> Bool {
        guard let hooks = entry["hooks"]?.arrayValue else { return false }
        return hooks.contains { hook in
            hook["command"]?.stringValue?.contains(LidwingID.integrationMarker) ?? false
        }
    }

    private static func ourEntry(helperPath: String) -> JSONValue {
        .object([
            (key: "matcher", value: .string(matcher)),
            (key: "hooks", value: .array([
                .object([
                    (key: "type", value: .string("command")),
                    (key: "command", value: .string(helperPath)),
                    (key: "timeout", value: .number("5"))
                ])
            ]))
        ])
    }

    private static func parseObject(_ source: String) throws -> JSONValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([]) }
        do {
            let value = try OrderedJSON.parse(trimmed)
            guard case .object = value else { throw PatchError.notAnObject }
            return value
        } catch let error as JSONParseError {
            // Never write to a file we could not read. A half-understood config is how a tool
            // destroys somebody's setup while reporting success.
            throw PatchError.unparseable(error)
        }
    }

    /// A plain line diff, for the "show what will be written" disclosure.
    static func lineDiff(before: String, after: String) -> String {
        let old = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = after.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var lines: [String] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count && newIndex < new.count && old[oldIndex] == new[newIndex] {
                oldIndex += 1
                newIndex += 1
                continue
            }
            if newIndex < new.count && !old.contains(new[newIndex]) {
                lines.append("+ " + new[newIndex])
                newIndex += 1
            } else if oldIndex < old.count && !new.contains(old[oldIndex]) {
                lines.append("- " + old[oldIndex])
                oldIndex += 1
            } else {
                oldIndex += 1
                newIndex += 1
            }
        }
        return lines.joined(separator: "\n")
    }
}
