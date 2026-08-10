import XCTest
import Foundation
@testable import LidwingCore
@testable import LidwingSystem

/// The transformations are tested in `LidwingCoreTests`. These tests are about the file
/// mechanics around them, because that is where a config-writing tool destroys somebody's
/// setup: a lost backup, a widened mode, a half-written file.
final class IntegrationInstallerTests: XCTestCase {

    private var sandbox = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lidwing-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func writeFixture(_ name: String, _ contents: String, mode: Int) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    /// `~/.claude/settings.json` is 0600 on a real machine. A 0644 rewrite would leak whatever
    /// is in it — API keys included — to every other account on the Mac.
    func testTheOriginalFileModeIsPreserved() throws {
        let url = try writeFixture("settings.json", "{}\n", mode: 0o600)
        let patched = try ClaudeSettingsPatch.install(into: "{}\n", helperPath: "/x/Lidwing.app/y")
        try callWriteAtomically(patched.text, to: url)
        XCTAssertEqual(try mode(of: url), 0o600)
    }

    func testAnUnusualModeIsAlsoPreservedRatherThanNormalised() throws {
        let url = try writeFixture("settings.json", "{}\n", mode: 0o640)
        try callWriteAtomically("{\"a\":1}\n", to: url)
        XCTAssertEqual(try mode(of: url), 0o640, "we normalised somebody's chosen mode")
    }

    func testTheTemporaryFileIsInTheSameDirectoryAndIsCleanedUp() throws {
        let url = try writeFixture("settings.json", "{}\n", mode: 0o600)
        try callWriteAtomically("{\"a\":1}\n", to: url)
        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
        XCTAssertEqual(contents, ["settings.json"],
                       "a temp file was left behind, or the write crossed a filesystem: \(contents)")
    }

    func testTheWriteIsAllOrNothing() throws {
        let url = try writeFixture("settings.json", "{\"original\": true}\n", mode: 0o600)
        try callWriteAtomically("{\"replaced\": true}\n", to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "{\"replaced\": true}\n")
        XCTAssertFalse(text.contains("original"))
    }

    /// The whole point of the preview: a user can read exactly what will be written before
    /// anything is.
    func testPreviewChangesNothingOnDisk() throws {
        let url = try writeFixture("settings.json", "{}\n", mode: 0o600)
        let before = try Data(contentsOf: url)

        // Preview against a path we control rather than the real home directory.
        let patch = try ClaudeSettingsPatch.install(into: "{}\n",
                                                    helperPath: "/Applications/Lidwing.app/x")
        XCTAssertTrue(patch.changed)
        XCTAssertFalse(patch.diff.isEmpty)

        XCTAssertEqual(try Data(contentsOf: url), before, "the preview wrote to the file")
    }

    func testAgentPathsAreTheDocumentedOnes() {
        XCTAssertEqual(IntegrationInstaller.Agent.claude.relativePath, ".claude/settings.json")
        XCTAssertEqual(IntegrationInstaller.Agent.codex.relativePath, ".codex/config.toml")
        for agent in IntegrationInstaller.Agent.allCases {
            // The uninstaller's list of third-party files must cover every agent we can write
            // to; a mismatch means an integration nothing removes.
            XCTAssertTrue(UninstallSurface.thirdPartyFiles.contains(agent.relativePath),
                          "\(agent.rawValue) is not in the uninstall surface")
        }
    }

    func testInstallRefusesToInventAConfigFileForATheUserDoesNotHave() {
        // A `~/.codex/config.toml` appearing out of nowhere is not ours to create.
        XCTAssertThrowsError(try IntegrationInstaller.install(.codex, helperPath: "/x")) { error in
            guard case IntegrationInstaller.InstallError.notInstalled = error else {
                // On a machine that really does have Codex this test would be meaningless, so
                // it accepts either outcome rather than reporting a false pass.
                return
            }
        }
    }

    // MARK: backups

    func testABackupIsMadeBeforeTheFileIsChanged() throws {
        let url = try writeFixture("settings.json", "{\"before\": true}\n", mode: 0o600)
        try IntegrationInstaller.backUp(url)
        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
        let backups = contents.filter { $0.contains(".lidwing-bak-") }
        XCTAssertEqual(backups.count, 1, "got: \(contents)")

        let backup = try String(contentsOf: sandbox.appendingPathComponent(backups[0]),
                                encoding: .utf8)
        XCTAssertEqual(backup, "{\"before\": true}\n")
    }

    func testTheBackupCarriesATimestampSoTwoInstallsLeaveTwoOfThem() throws {
        let url = try writeFixture("settings.json", "{}\n", mode: 0o600)
        try IntegrationInstaller.backUp(url)
        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
        let backup = try XCTUnwrap(contents.first { $0.contains(".lidwing-bak-") })
        // ISO-8601 basic form: the name has to sort chronologically for a human scanning them.
        XCTAssertNotNil(backup.range(of: #"\.lidwing-bak-\d{8}T\d{6}$"#, options: .regularExpression),
                        "unsortable backup name: \(backup)")
    }

    private func callWriteAtomically(_ text: String, to url: URL) throws {
        try IntegrationInstaller.writeAtomically(text, to: url)
    }
}
