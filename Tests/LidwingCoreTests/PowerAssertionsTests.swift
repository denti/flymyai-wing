import XCTest
@testable import LidwingCore

/// Tested against the output of a real developer Mac rather than against a fixture written to
/// match the parser. Three assertion types, three owners, three lifetimes, plus the system noise
/// that surrounds them on any machine somebody actually works on.
final class PowerAssertionsTests: XCTestCase {

    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pmset-assertions-developer-mac",
                                                  withExtension: "txt",
                                                  subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testItFindsEveryOwnerInTheRealOutput() throws {
        let found = PowerAssertions.parse(try fixture())
        XCTAssertEqual(found.map(\.process),
                       ["Claude", "caffeinate", "configd", "powerd", "powerd",
                        "WindowServer", "mds_stores"])
    }

    /// The summary block above the list says how many holds exist and never who owns them.
    /// Reading it as assertions would invent owners that do not exist.
    func testTheSystemWideSummaryIsNotMistakenForOwners() throws {
        let found = PowerAssertions.parse(try fixture())
        XCTAssertFalse(found.contains { $0.process.contains("BackgroundTask") })
        XCTAssertEqual(found.filter { $0.pid == 0 }.count, 2, "only powerd holds pid 0 here")
    }

    /// The three that matter, each classified by what it actually prevents.
    func testEachKindIsRecognised() throws {
        let byProcess = Dictionary(grouping: PowerAssertions.parse(try fixture()),
                                   by: \.process)
        XCTAssertEqual(byProcess["Claude"]?.first?.kind, .idleSleep)
        XCTAssertEqual(byProcess["caffeinate"]?.first?.kind, .idleSleep)
        XCTAssertEqual(byProcess["configd"]?.first?.kind, .systemSleep,
                       "Internet Sharing is a strictly stronger hold than the idle ones")
        XCTAssertEqual(byProcess["WindowServer"]?.first?.kind, .userActive)
    }

    /// `caffeinate -i -t 300`, which Claude Code spawns per command.
    func testTheSelfReleasingHoldIsRecognisedAsTemporary() throws {
        let caffeinate = try XCTUnwrap(PowerAssertions.parse(try fixture())
            .first { $0.process == "caffeinate" })
        XCTAssertEqual(caffeinate.releasesInSeconds, 262)
    }

    func testAHoldWithNoTimeoutHasNoReleaseTime() throws {
        let claude = try XCTUnwrap(PowerAssertions.parse(try fixture())
            .first { $0.process == "Claude" })
        XCTAssertNil(claude.releasesInSeconds, "a persistent hold claimed it would release")
    }

    /// Only a timeout that hands the machine back counts. The others expire into a different
    /// behaviour, and treating those as temporary would be wrong in the direction that matters.
    func testOnlyAReleasingTimeoutCounts() {
        XCTAssertEqual(PowerAssertions.secondsUntilTimeout(
            in: "Timeout will fire in 262 secs Action=TimeoutActionRelease"), 262)
        XCTAssertNil(PowerAssertions.secondsUntilTimeout(
            in: "Timeout will fire in 262 secs Action=TimeoutActionTurnOff"))
        XCTAssertNil(PowerAssertions.secondsUntilTimeout(in: "Details: caffeinate asserting"))
    }

    func testAnEmptyOrGarbledOutputYieldsNothingRatherThanGuessing() {
        XCTAssertTrue(PowerAssertions.parse("").isEmpty)
        XCTAssertTrue(PowerAssertions.parse("Listed by owning process:\n   nonsense").isEmpty)
        XCTAssertTrue(PowerAssertions.parse("pid notanumber(x): 0:00 Foo named: \"y\"").isEmpty)
    }
}

/// What the user is actually told, out of all that.
///
/// The governing question is **not** "who is preventing sleep" but "who will interfere with
/// Lidwing". Asking the first one made every Mac report a conflict on every launch and called
/// the operating system an app.
final class ConflictPolicyTests: XCTestCase {

    private func assertions(_ resource: String) throws -> [PowerAssertions.Assertion] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: resource, withExtension: "txt",
                                                  subdirectory: "Fixtures"))
        return PowerAssertions.parse(try String(contentsOf: url, encoding: .utf8))
    }

    private func quietMac() throws -> [PowerAssertions.Assertion] {
        try assertions("pmset-assertions-quiet-mac")
    }

    private func developerMac() throws -> [PowerAssertions.Assertion] {
        try assertions("pmset-assertions-developer-mac")
    }

    // MARK: the ordinary Mac

    /// Seven assertions, six owners, and **not one of them is a conflict**. This is what a normal
    /// machine looks like, and the app must say nothing about any of it.
    func testAnOrdinaryMacProducesNothingToSay() throws {
        let held = try quietMac()
        XCTAssertEqual(held.count, 7, "the fixture is not the machine it claims to be")
        XCTAssertTrue(ConflictPolicy.noteworthy(from: held).isEmpty,
                      "an ordinary Mac was told something was wrong: "
                      + "\(ConflictPolicy.noteworthy(from: held).map(\.displayName))")
        XCTAssertNil(ConflictPolicy.headline(from: ConflictPolicy.noteworthy(from: held)))
    }

    /// The exact false positive a user saw on first launch: "Another app is already keeping this
    /// Mac awake: powerd (pid 368)." `powerd` holds that assertion whenever the display is on,
    /// which is to say always, on every Mac.
    func testPowerdIsNeverNamed() throws {
        let names = try ConflictPolicy.noteworthy(from: quietMac()).map(\.displayName)
            + ConflictPolicy.coexisting(from: quietMac()).map(\.displayName)
        XCTAssertFalse(names.contains("powerd"),
                       "named Apple's own power daemon to a user, on every Mac, on every launch")
    }

    /// The same class: Apple daemons doing ordinary work. None of them is an app, and none of
    /// them interferes with a clamshell demand sleep.
    func testNoAppleDaemonIsEverPresentedAsAConflict() throws {
        let noteworthy = try ConflictPolicy.noteworthy(from: quietMac()).map(\.displayName)
        for daemon in ["powerd", "WindowServer", "useractivityd", "sharingd", "mds_stores"] {
            XCTAssertFalse(noteworthy.contains(daemon), "\(daemon) was presented as a conflict")
        }
    }

    /// We coexist with every idle-sleep holder, Apple's or anybody's. Lidwing blocks the
    /// clamshell demand sleep; these are a different layer.
    func testIdleSleepHoldersAreIgnoredWhoeverOwnsThem() throws {
        for held in try quietMac() where held.kind == .idleSleep {
            XCTAssertEqual(ConflictPolicy.tier(for: held), .ignore,
                           "\(held.process) holding an idle assertion was treated as a conflict")
        }
    }

    /// Including the two most common third-party ones on a developer machine.
    func testCaffeinateAndTheClaudeAppAreIgnored() throws {
        let noteworthy = try ConflictPolicy.noteworthy(from: developerMac()).map(\.displayName)
        XCTAssertFalse(noteworthy.contains("caffeinate"))
        XCTAssertFalse(noteworthy.contains("Claude"))
    }

    // MARK: the one that is worth a line

    /// Internet Sharing holds `DenySystemSleep`: the Mac will not sleep at all while it is held,
    /// so Lidwing's promise is temporarily moot. Worth stating; not worth warning about.
    func testASystemSleepHolderIsWorthOneQuietLine() throws {
        let noteworthy = try ConflictPolicy.noteworthy(from: developerMac())
        XCTAssertEqual(noteworthy.map(\.displayName), ["Internet Sharing"])
        XCTAssertEqual(noteworthy.first?.kind, .systemSleep)
    }

    /// `configd` is an Apple daemon and this case is still reported - the *kind* of hold is the
    /// honest signal, not who owns it. Filtering by owner would both name `powerd` to users and
    /// hide Internet Sharing, which is precisely the pair of mistakes the old code made.
    func testOwnershipIsNotWhatDecidesIt() {
        let internetSharing = PowerAssertions.Assertion(
            pid: 366, process: "configd", kind: .systemSleep,
            name: "InternetSharingPreferencePlugin")
        XCTAssertEqual(ConflictPolicy.tier(for: internetSharing), .quietNote)
        XCTAssertEqual(ConflictPolicy.noteworthy(from: [internetSharing]).first?.displayName,
                       "Internet Sharing")
    }

    func testAnOwnerIsNamedTheWayAPersonWouldRecogniseIt() {
        XCTAssertEqual(ConflictPolicy.displayName(process: "configd",
                                                  assertionName: "InternetSharingPreferencePlugin"),
                       "Internet Sharing")
        XCTAssertEqual(ConflictPolicy.displayName(process: "Claude", assertionName: "Electron"),
                       "Claude")
    }

    // MARK: diagnostics

    /// Everything we coexist with is still available where being complete is the point and
    /// interrupting nobody is guaranteed.
    func testCoexistingHoldersAreStillAvailableForDiagnostics() throws {
        let coexisting = try ConflictPolicy.coexisting(from: developerMac()).map(\.displayName)
        XCTAssertTrue(coexisting.contains("Claude"))
        XCTAssertTrue(coexisting.contains("caffeinate"))
    }

    func testNothingHeldMeansNothingSaid() {
        XCTAssertTrue(ConflictPolicy.noteworthy(from: []).isEmpty)
        XCTAssertNil(ConflictPolicy.headline(from: []))
    }
}
