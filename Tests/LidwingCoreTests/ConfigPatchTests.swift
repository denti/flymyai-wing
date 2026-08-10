import XCTest
@testable import LidwingCore

/// These files belong to somebody else. Every test here is about what we did **not** touch.
final class ClaudeSettingsPatchTests: XCTestCase {

    private let helper = "/Applications/Lidwing.app/Contents/Resources/lidwing-notify"

    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? URL(fileURLWithPath: "Tests/LidwingCoreTests/Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: ordered JSON, which everything below depends on

    func testUnchangedFilesRoundTripExactly() throws {
        let source = try fixture("claude-settings-existing-hooks.json")
        let parsed = try OrderedJSON.parse(source)
        let written = OrderedJSON.serialise(parsed, indent: OrderedJSON.detectIndent(source))
        XCTAssertEqual(written, source,
                       "a round trip must not reformat a file we were only reading")
    }

    func testKeyOrderIsPreserved() throws {
        let source = #"{"zebra": 1, "apple": 2, "mango": 3}"#
        let written = OrderedJSON.serialise(try OrderedJSON.parse(source))
        let order = ["zebra", "apple", "mango"].map { written.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertEqual(order, order.compactMap { $0 }.map { Optional($0) })
        XCTAssertTrue(order.compactMap { $0 } == order.compactMap { $0 }.sorted(),
                      "keys came back in a different order: \(written)")
    }

    func testNumbersAreKeptVerbatim() throws {
        // Rewriting 1.0 as 1 changes bytes in somebody else's file for no reason.
        let written = OrderedJSON.serialise(try OrderedJSON.parse(#"{"a": 1.0, "b": 1e3}"#))
        XCTAssertTrue(written.contains("1.0"))
        XCTAssertTrue(written.contains("1e3"))
    }

    func testSurrogatePairsSurvive() throws {
        let parsed = try OrderedJSON.parse(#"{"emoji": "🚀 go"}"#)
        XCTAssertEqual(parsed["emoji"]?.stringValue, "\u{1F680} go")
    }

    func testGarbageIsRejectedRatherThanGuessedAt() {
        for bad in ["{", "{\"a\"}", "{\"a\": }", "[1,]", "{\"a\": 1} trailing", "{'a': 1}"] {
            XCTAssertThrowsError(try OrderedJSON.parse(bad), "accepted: \(bad)")
        }
    }

    // MARK: install

    func testInstallingIntoAnEmptyFileAddsOnlyTheHook() throws {
        let patch = try ClaudeSettingsPatch.install(into: "{}", helperPath: helper)
        let parsed = try OrderedJSON.parse(patch.text)
        let entries = try XCTUnwrap(parsed["hooks"]?["Notification"]?.arrayValue)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["matcher"]?.stringValue, ClaudeSettingsPatch.matcher)
        XCTAssertTrue(patch.changed)
    }

    /// The golden-file assertion: a file with unrelated keys and an existing hook must come
    /// back differing **only** by our addition.
    func testEverythingElseInTheFileIsUntouched() throws {
        let source = try fixture("claude-settings-existing-hooks.json")
        let patch = try ClaudeSettingsPatch.install(into: source, helperPath: helper)

        let before = try OrderedJSON.parse(source)
        let after = try OrderedJSON.parse(patch.text)

        XCTAssertEqual(before["model"], after["model"])
        XCTAssertEqual(before["theme"], after["theme"])
        XCTAssertEqual(before["env"], after["env"])
        XCTAssertEqual(before["hooks"]?["PreToolUse"], after["hooks"]?["PreToolUse"],
                       "another tool's PreToolUse hook was modified")

        // Their own Notification hook survives alongside ours.
        let entries = try XCTUnwrap(after["hooks"]?["Notification"]?.arrayValue)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { entry in
            entry["hooks"]?.arrayValue?.contains {
                $0["command"]?.stringValue == "/usr/local/bin/their-own-notifier"
            } ?? false
        }, "the incumbent notifier was removed")
    }

    func testInstallingTwiceIsByteIdentical() throws {
        let source = try fixture("claude-settings-empty.json")
        let once = try ClaudeSettingsPatch.install(into: source, helperPath: helper)
        let twice = try ClaudeSettingsPatch.install(into: once.text, helperPath: helper)
        XCTAssertEqual(once.text, twice.text)
        XCTAssertFalse(twice.changed, "the second install reported a change it did not make")

        let entries = try XCTUnwrap(try OrderedJSON.parse(twice.text)["hooks"]?["Notification"]?
            .arrayValue)
        XCTAssertEqual(entries.count, 1, "a second entry was appended")
    }

    func testAnUnparseableFileThrowsAndProducesNoText() throws {
        XCTAssertThrowsError(try ClaudeSettingsPatch.install(into: "{ this is not json",
                                                             helperPath: helper)) { error in
            guard case ClaudeSettingsPatch.PatchError.unparseable = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testANonObjectTopLevelIsRefused() {
        XCTAssertThrowsError(try ClaudeSettingsPatch.install(into: "[1, 2, 3]", helperPath: helper))
    }

    // MARK: uninstall

    func testUninstallRemovesOnlyOurEntry() throws {
        let source = try fixture("claude-settings-existing-hooks.json")
        let installed = try ClaudeSettingsPatch.install(into: source, helperPath: helper)
        let removed = try ClaudeSettingsPatch.uninstall(from: installed.text)

        let before = try OrderedJSON.parse(source)
        let after = try OrderedJSON.parse(removed.text)
        XCTAssertEqual(before, after, "uninstall did not return the file to its original state")
    }

    func testUninstallLeavesNoEmptyScaffolding() throws {
        let installed = try ClaudeSettingsPatch.install(into: "{}", helperPath: helper)
        let removed = try ClaudeSettingsPatch.uninstall(from: installed.text)
        let after = try OrderedJSON.parse(removed.text)
        XCTAssertNil(after["hooks"], "an empty hooks object was left behind: \(removed.text)")
    }

    func testUninstallOnAFileWeNeverTouchedChangesNothing() throws {
        let source = try fixture("claude-settings-existing-hooks.json")
        let removed = try ClaudeSettingsPatch.uninstall(from: source)
        XCTAssertFalse(removed.changed)
        XCTAssertEqual(try OrderedJSON.parse(removed.text), try OrderedJSON.parse(source))
    }

    func testTheDiffShownToTheUserNamesTheCommand() throws {
        let patch = try ClaudeSettingsPatch.install(into: "{}", helperPath: helper)
        XCTAssertTrue(patch.diff.contains(helper), "the diff hides what will be run")
        XCTAssertTrue(patch.diff.split(separator: "\n").allSatisfy {
            $0.hasPrefix("+ ") || $0.hasPrefix("- ")
        })
    }
}

final class CodexConfigPatchTests: XCTestCase {

    private let helper = "/Applications/Lidwing.app/Contents/Resources/lidwing-notify"

    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
            ?? URL(fileURLWithPath: "Tests/LidwingCoreTests/Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testInstallingWhereNotifyIsFreeAddsOneLineAndTouchesNothingElse() throws {
        let source = try fixture("codex-config-no-notify.toml")
        let patch = try CodexConfigPatch.install(into: source, helperPath: helper)

        XCTAssertTrue(patch.changed)
        XCTAssertNil(patch.displaced)
        // Every original line survives, including the comment and the trailing comment.
        for line in source.components(separatedBy: "\n") where !line.isEmpty {
            XCTAssertTrue(patch.text.contains(line), "lost a line: \(line)")
        }
        XCTAssertTrue(patch.text.contains("# Codex configuration"))
        XCTAssertTrue(patch.text.contains("theme = \"dark\"   # trailing comment survives"))
    }

    /// The key case: `notify` is a single scalar and it is already occupied on real machines.
    /// Blind-writing it silently breaks a feature the user already had.
    func testAnOccupiedNotifyIsChainedAndNeverReplaced() throws {
        let source = try fixture("codex-config-notify-occupied.toml")
        let patch = try CodexConfigPatch.install(into: source, helperPath: helper)

        XCTAssertEqual(patch.displaced,
                       ["/Applications/SkyComputerUse.app/Contents/MacOS/SkyComputerUseClient",
                        "--codex"])
        XCTAssertTrue(patch.text.contains("--chain"))
        XCTAssertTrue(patch.text.contains("SkyComputerUseClient"),
                      "the incumbent command was dropped")
        XCTAssertTrue(patch.text.contains(helper))
    }

    func testUninstallRestoresTheOriginalArrayByteForByte() throws {
        let source = try fixture("codex-config-notify-occupied.toml")
        let patch = try CodexConfigPatch.install(into: source, helperPath: helper)
        let removed = CodexConfigPatch.uninstall(from: patch.text, restoring: patch.displaced)
        XCTAssertEqual(removed.text, source)
    }

    func testUninstallRemovesTheWholeLineWhenNothingWasDisplaced() throws {
        let source = try fixture("codex-config-no-notify.toml")
        let patch = try CodexConfigPatch.install(into: source, helperPath: helper)
        let removed = CodexConfigPatch.uninstall(from: patch.text, restoring: patch.displaced)
        XCTAssertEqual(removed.text, source)
        XCTAssertFalse(removed.text.contains("notify"))
    }

    func testInstallingTwiceDoesNotChainToOurselves() throws {
        let source = try fixture("codex-config-notify-occupied.toml")
        let once = try CodexConfigPatch.install(into: source, helperPath: helper)
        let twice = try CodexConfigPatch.install(into: once.text, helperPath: helper)
        XCTAssertEqual(once.text, twice.text)
        // Two helper paths in one argv would mean the argument list grows on every install.
        let occurrences = twice.text.components(separatedBy: helper).count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testAKeyInsideATableIsNotOurs() {
        let source = """
        model = "gpt-5-codex"

        [tui]
        notify = ["something"]
        """
        // `notify` under `[tui]` belongs to `[tui]`. Ours goes at the top level.
        XCTAssertNil(CodexConfigPatch.findTopLevelKey(in: source.components(separatedBy: "\n")))
    }

    func testOurLineIsInsertedBeforeTheFirstTableHeader() throws {
        let source = """
        model = "gpt-5-codex"

        [tui]
        theme = "dark"
        """
        let patch = try CodexConfigPatch.install(into: source, helperPath: helper)
        let lines = patch.text.components(separatedBy: "\n")
        let notifyIndex = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("notify") })
        let tableIndex = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("[tui]") })
        XCTAssertLessThan(notifyIndex, tableIndex,
                          "the key landed inside a table, where Codex will never look for it")
    }

    func testAValueWeCannotParseIsRefusedRatherThanMangled() {
        let source = "notify = \"a bare string\"\n"
        XCTAssertThrowsError(try CodexConfigPatch.install(into: source, helperPath: helper))
    }

    func testArrayParsingHandlesCommentsAndEscapes() {
        XCTAssertEqual(CodexConfigPatch.parseStringArray("[\"a\", \"b\"]  # trailing"), ["a", "b"])
        XCTAssertEqual(CodexConfigPatch.parseStringArray("[\"say \\\"hi\\\"\"]"), ["say \"hi\""])
        XCTAssertEqual(CodexConfigPatch.parseStringArray("[]"), [])
        XCTAssertNil(CodexConfigPatch.parseStringArray("[1, 2]"))
        XCTAssertNil(CodexConfigPatch.parseStringArray("\"scalar\""))
    }
}
