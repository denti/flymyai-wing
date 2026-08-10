import XCTest
@testable import LidwingCore

/// Low Power Mode is the only feature that asks for an administrator password, so the rules
/// about when it engages and what it puts back are the ones that have to be exactly right.
final class LowPowerPolicyTests: XCTestCase {

    private func conditions(enabled: Bool = true, armed: Bool = true,
                            lidClosed: Bool = true, onAC: Bool = false)
        -> LowPowerPolicy.Conditions {
        LowPowerPolicy.Conditions(userEnabled: enabled, armed: armed,
                                  lidClosed: lidClosed, onAC: onAC)
    }

    func testItEngagesOnlyOnBatteryWithTheLidShutWhileArmedAndEnabled() {
        XCTAssertTrue(LowPowerPolicy.shouldEngage(conditions()))
    }

    /// The default state of the app is zero-privilege. If the user never turned this on, nothing
    /// here may ever ask for anything.
    func testItNeverEngagesWithoutTheUserTurningItOn() {
        XCTAssertFalse(LowPowerPolicy.shouldEngage(conditions(enabled: false)))
        // Not even in the configuration where it would otherwise be perfect.
        XCTAssertFalse(LowPowerPolicy.shouldEngage(
            conditions(enabled: false, armed: true, lidClosed: true, onAC: false)))
    }

    /// On a socket there is nothing to save, so the slowdown would be pure loss: the agent takes
    /// longer to finish and the user gains nothing at all.
    func testItNeverEngagesOnAC() {
        XCTAssertFalse(LowPowerPolicy.shouldEngage(conditions(onAC: true)))
    }

    /// It is about the closed-lid run, not about Lidwing being switched on while the user is
    /// still sitting there typing.
    func testItDoesNotEngageWhileTheLidIsOpen() {
        XCTAssertFalse(LowPowerPolicy.shouldEngage(conditions(lidClosed: false)))
    }

    func testItDoesNotEngageWhenLidwingIsNotProtecting() {
        XCTAssertFalse(LowPowerPolicy.shouldEngage(conditions(armed: false)))
    }

    /// Every single condition must be necessary. A policy where one input does not matter is a
    /// policy with a bug in it.
    func testEveryConditionIsLoadBearing() {
        XCTAssertTrue(LowPowerPolicy.shouldEngage(conditions()))
        for flip in 0..<4 {
            let candidate = conditions(enabled: flip != 0, armed: flip != 1,
                                       lidClosed: flip != 2, onAC: flip == 3)
            XCTAssertFalse(LowPowerPolicy.shouldEngage(candidate),
                           "flipping input \(flip) alone did not stop it engaging")
        }
    }
}

/// Being a guest in a setting the user may have configured deliberately.
final class LowPowerGuestTests: XCTestCase {

    func testEngagingWritesOnlyWhenTheMachineDisagrees() {
        let off = LowPowerSnapshot(battery: false, ac: false)
        XCTAssertEqual(LowPowerGuest.writesToEngage(true, current: off),
                       [LowPowerGuest.Write(source: .battery, value: true)])
    }

    /// The owner's own Mac already has `lowpowermode 1` on both sources. Writing it again would
    /// be a privileged operation that changes nothing and leaves a trace in his `pmset -g custom`.
    func testItWritesNothingWhenTheValueIsAlreadyInPlace() {
        let alreadyOn = LowPowerSnapshot(battery: true, ac: true)
        XCTAssertTrue(LowPowerGuest.writesToEngage(true, current: alreadyOn).isEmpty)
        let alreadyOff = LowPowerSnapshot(battery: false, ac: false)
        XCTAssertTrue(LowPowerGuest.writesToEngage(false, current: alreadyOff).isEmpty)
    }

    /// An unreadable value is a reason to do nothing, not a reason to guess.
    func testItWritesNothingWhenTheCurrentValueCannotBeRead() {
        let unknown = LowPowerSnapshot(battery: nil, ac: nil)
        XCTAssertTrue(LowPowerGuest.writesToEngage(true, current: unknown).isEmpty)
    }

    /// Lidwing has no business changing Low Power Mode for the plugged-in case at all.
    func testItNeverWritesTheACSource() {
        for engage in [true, false] {
            let writes = LowPowerGuest.writesToEngage(
                engage, current: LowPowerSnapshot(battery: !engage, ac: !engage))
            XCTAssertTrue(writes.allSatisfy { $0.source == .battery },
                          "something wrote the AC source: \(writes)")
        }
    }

    func testRestorePutsBackExactlyWhatWasThere() {
        let snapshot = LowPowerSnapshot(battery: false, ac: true, wroteBattery: true)
        let current = LowPowerSnapshot(battery: true, ac: true)
        XCTAssertEqual(LowPowerGuest.writesToRestore(snapshot: snapshot, current: current),
                       [LowPowerGuest.Write(source: .battery, value: false)])
    }

    func testRestoreWritesNothingIfWeNeverWroteAnything() {
        let snapshot = LowPowerSnapshot(battery: true, ac: true)
        let current = LowPowerSnapshot(battery: true, ac: true)
        XCTAssertTrue(LowPowerGuest.writesToRestore(snapshot: snapshot, current: current).isEmpty)
    }

    /// The case that decides whether this app is trustworthy with a password. If the user or
    /// another tool changed the value after us, their choice is newer than ours and we leave it.
    func testRestoreLeavesAValueSomebodyElseChanged() {
        let snapshot = LowPowerSnapshot(battery: false, ac: false, wroteBattery: true)
        // We set it to true; it now reads false, so somebody else has been here.
        let current = LowPowerSnapshot(battery: false, ac: false)
        XCTAssertTrue(LowPowerGuest.writesToRestore(snapshot: snapshot, current: current).isEmpty,
                      "wrote over a value that somebody else had changed after us")
        XCTAssertTrue(LowPowerGuest.restoreWasOverruled(snapshot: snapshot, current: current))
    }

    func testAnOrdinaryRestoreIsNotReportedAsOverruled() {
        let snapshot = LowPowerSnapshot(battery: false, ac: false, wroteBattery: true)
        let current = LowPowerSnapshot(battery: true, ac: false)
        XCTAssertFalse(LowPowerGuest.restoreWasOverruled(snapshot: snapshot, current: current))
    }

    /// The owner's configuration end to end: already on, so we write nothing going in, and there
    /// is nothing to undo coming out. His `pmset -g custom` is byte-identical before and after.
    func testTheOwnersMacIsNeverTouched() {
        let his = LowPowerSnapshot(battery: true, ac: true)
        XCTAssertTrue(LowPowerGuest.writesToEngage(true, current: his).isEmpty)

        let afterAnEngageThatWroteNothing = LowPowerSnapshot(battery: true, ac: true,
                                                             wroteBattery: nil)
        XCTAssertTrue(LowPowerGuest.writesToRestore(snapshot: afterAnEngageThatWroteNothing,
                                                    current: his).isEmpty)
        XCTAssertFalse(LowPowerGuest.restoreWasOverruled(snapshot: afterAnEngageThatWroteNothing,
                                                         current: his))
    }

    /// The snapshot is written to disk by the helper and read back after a reboot, so it has to
    /// survive a round trip with its nils intact - a nil that decodes as false would turn "we
    /// could not read it" into "it was off", and restore would write a value nobody chose.
    func testTheSnapshotRoundTripsWithItsNilsIntact() throws {
        let snapshot = LowPowerSnapshot(battery: nil, ac: true, wroteBattery: false)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LowPowerSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNil(decoded.battery)
        XCTAssertNil(decoded.wroteAC)
    }
}
