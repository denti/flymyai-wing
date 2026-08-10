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
final class ConflictPolicyTests: XCTestCase {

    private func conflicts() throws -> [ConflictPolicy.Conflict] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pmset-assertions-developer-mac",
                                                  withExtension: "txt",
                                                  subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return ConflictPolicy.conflicts(from: PowerAssertions.parse(text))
    }

    /// macOS asserts constantly on its own behalf and the user can do nothing about any of it.
    func testTheSystemsOwnNoiseIsNeverShown() throws {
        let names = try conflicts().map(\.displayName)
        for noise in ["powerd", "WindowServer", "mds_stores"] {
            XCTAssertFalse(names.contains(noise), "\(noise) was shown to a user")
        }
    }

    /// The case above cannot actually fail on its own: on the real fixture every system process
    /// happens to hold a display or user-active assertion, so the *kind* filter drops them even
    /// with the owner filter deleted. Each filter was masking the other, and a mutation removing
    /// either one left the suite green.
    ///
    /// This isolates the owner filter with the combination the fixture does not contain: a
    /// system process holding the strongest kind of hold there is.
    func testASystemProcessIsDroppedEvenWhenItsHoldIsTheStrongKind() {
        let systemHold = [PowerAssertions.Assertion(pid: 0, process: "powerd", kind: .systemSleep,
                                                    name: "com.apple.powermanagement.something")]
        XCTAssertTrue(ConflictPolicy.conflicts(from: systemHold).isEmpty,
                      "a hold the user can do nothing about was named to them")
    }

    /// And this isolates the kind filter: an ordinary app, which the owner filter keeps, holding
    /// a display assertion, which is meaningless once the lid is shut.
    func testAnOrdinaryAppsDisplayHoldIsStillNotAConflict() {
        let displayHold = [
            PowerAssertions.Assertion(pid: 700, process: "Safari", kind: .display,
                                      name: "Video playback"),
            PowerAssertions.Assertion(pid: 233, process: "SomeApp", kind: .userActive,
                                      name: "tickle")
        ]
        XCTAssertTrue(ConflictPolicy.conflicts(from: displayHold).isEmpty,
                      "a display hold was reported as competing for a closed lid")
    }

    /// A closed lid has no display to keep awake, and a trackpad tickle is not a conflict.
    func testDisplayAndUserActiveHoldsAreNotConflicts() throws {
        for conflict in try conflicts() {
            XCTAssertTrue(conflict.kind == .idleSleep || conflict.kind == .systemSleep,
                          "\(conflict.displayName) is a \(conflict.kind) hold")
        }
    }

    func testTheThreeRealHoldersSurvive() throws {
        XCTAssertEqual(Set(try conflicts().map(\.displayName)),
                       ["Claude", "caffeinate", "Internet Sharing"])
    }

    /// `configd` tells a user nothing. `InternetSharingPreferencePlugin` tells them what to
    /// switch off, and "Internet Sharing" is what that is called in System Settings.
    func testAnOwnerIsNamedTheWayAPersonWouldRecogniseIt() {
        XCTAssertEqual(ConflictPolicy.displayName(process: "configd",
                                                  assertionName: "InternetSharingPreferencePlugin"),
                       "Internet Sharing")
        // An Electron app names its assertion after the toolkit, not after itself.
        XCTAssertEqual(ConflictPolicy.displayName(process: "Claude", assertionName: "Electron"),
                       "Claude")
        XCTAssertEqual(ConflictPolicy.displayName(process: "caffeinate",
                                                  assertionName: "caffeinate command-line tool"),
                       "caffeinate")
    }

    /// The strongest hold leads: a system-sleep hold is the only kind that does what Lidwing
    /// does, so Internet Sharing outranks two idle-sleep holders.
    func testTheStrongestHoldIsRankedFirst() throws {
        XCTAssertEqual(try conflicts().first?.displayName, "Internet Sharing")
        XCTAssertEqual(try conflicts().first?.kind, .systemSleep)
    }

    /// The flap test, and the reason the threshold exists. Claude Code spawns
    /// `caffeinate -i -t 300` per command, so a detector that promotes it to the headline
    /// changes the menu bar every few minutes forever - which teaches the user to ignore it.
    func testASelfRespawningCaffeinateIsNeverTheHeadline() {
        let caffeinateOnly = [PowerAssertions.Assertion(
            pid: 47116, process: "caffeinate", kind: .idleSleep,
            name: "caffeinate command-line tool", releasesInSeconds: 262)]
        let conflicts = ConflictPolicy.conflicts(from: caffeinateOnly)

        XCTAssertEqual(conflicts.count, 1, "it is still detected and still listed")
        XCTAssertTrue(conflicts[0].isTransient)
        XCTAssertNil(ConflictPolicy.headline(from: conflicts),
                     "a hold that releases itself in four minutes became a menu-bar state")
    }

    /// ...but a real, standing holder is named immediately.
    func testAStandingHolderIsTheHeadline() throws {
        let headline = try XCTUnwrap(ConflictPolicy.headline(from: try conflicts()))
        XCTAssertEqual(headline.displayName, "Internet Sharing")
        XCTAssertFalse(headline.isTransient)
    }

    /// A hold with a very long timeout is not transient in any useful sense: it will outlive the
    /// agent run the user is trying to protect.
    func testALongTimeoutIsNotTreatedAsTransient() {
        let long = [PowerAssertions.Assertion(pid: 900, process: "somebody", kind: .systemSleep,
                                              name: "long hold", releasesInSeconds: 4 * 3600)]
        XCTAssertFalse(ConflictPolicy.conflicts(from: long)[0].isTransient)
        XCTAssertNotNil(ConflictPolicy.headline(from: ConflictPolicy.conflicts(from: long)))
    }

    func testNothingHeldMeansNothingSaid() {
        XCTAssertTrue(ConflictPolicy.conflicts(from: []).isEmpty)
        XCTAssertNil(ConflictPolicy.headline(from: []))
    }
}
