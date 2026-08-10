import XCTest
@testable import LidwingCore

/// When the idle-sleep assertion is held, now that Lidwing arms itself at launch.
///
/// Both halves of the mechanism are required and orthogonal: the clamshell mask stops the demand
/// sleep from a lid close, the assertion stops the idle timer. They are not needed at the same
/// moments, and that stopped being academic the moment arming became the default state rather
/// than a deliberate act.
///
/// Held unconditionally, a Mac with Lidwing installed never idle-sleeps again from login until
/// the lease expires - so somebody who walks away with the lid open returns to a hot laptop that
/// never slept, for a feature they were not using.
final class IdleAssertionScopeTests: XCTestCase {

    private func armedAtLaunch(lid: LidState = .open, agents: Set<String> = [])
        -> (MockSystem, StateMachine) {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = lid
        system.runningAgentBinaries = agents
        machine.handle(.launch)
        machine.handle(.armAtLaunch)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed, "the fixture did not arm")
        return (system, machine)
    }

    /// The case this exists for. Nothing is happening, the lid is open, and nobody asked - so the
    /// Mac is allowed to sleep on its own like any other Mac.
    func testAnAutomaticArmWithTheLidOpenDoesNotHoldTheMacAwake() {
        let (system, machine) = armedAtLaunch()
        machine.handle(.reconcileTick)

        XCTAssertFalse(system.ourAssertionLive,
                       "a Mac nobody was using was held awake by an arm nobody asked for")
        XCTAssertEqual(system.clamshellCausesSleep, false,
                       "the clamshell mask must stay set - it costs nothing and is the promise")
    }

    /// Safety first: with the lid shut, the assertion is essential. The mask alone stops the
    /// demand sleep and leaves the idle timer running.
    func testTheAssertionIsHeldWheneverTheLidIsShut() {
        let (system, machine) = armedAtLaunch(lid: .closed)
        machine.handle(.reconcileTick)
        XCTAssertTrue(system.ourAssertionLive, "the lid was shut and the idle timer was left running")
    }

    /// A run has to survive the user walking away with the lid open. Same promise, different
    /// posture.
    func testTheAssertionIsHeldWhileAnAgentIsRunning() {
        let (system, machine) = armedAtLaunch(agents: ["claude"])
        machine.handle(.reconcileTick)
        XCTAssertTrue(system.ourAssertionLive,
                      "an agent run would have died when the user walked away")
    }

    /// Somebody who turned it on themselves is entitled to have it mean what it always meant.
    func testAUserRequestedArmHoldsItRegardless() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .open
        machine.handle(.launch)
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        machine.handle(.reconcileTick)

        XCTAssertTrue(system.ourAssertionLive,
                      "the user asked for this explicitly and it was quietly downgraded")
    }

    /// The transition that must never be slow: the lid shuts and the assertion is taken on the
    /// notification itself, not on the next tick.
    func testClosingTheLidTakesTheAssertionImmediately() {
        let (system, machine) = armedAtLaunch()
        machine.handle(.reconcileTick)
        XCTAssertFalse(system.ourAssertionLive)

        system.lidState = .closed
        machine.handle(.lidChanged(.closed))

        XCTAssertTrue(system.ourAssertionLive,
                      "the assertion waited for a timer while the lid was already shut")
    }

    /// And if that notification is missed, reconcile catches it within five seconds - far inside
    /// any idle-sleep timeout. Two independent paths, because the notification is best-effort.
    func testTheReconcileTickIsTheBackstopForAMissedLidClose() {
        let (system, machine) = armedAtLaunch()
        machine.handle(.reconcileTick)
        XCTAssertFalse(system.ourAssertionLive)

        system.lidState = .closed          // the notification never arrived
        machine.handle(.reconcileTick)

        XCTAssertTrue(system.ourAssertionLive, "a missed lid close left the idle timer running")
    }

    /// An agent starting while the lid is open is the other way in.
    func testAnAgentStartingTakesTheAssertion() {
        let (system, machine) = armedAtLaunch()
        machine.handle(.reconcileTick)
        XCTAssertFalse(system.ourAssertionLive)

        system.runningAgentBinaries = ["codex"]
        machine.handle(.reconcileTick)

        XCTAssertTrue(system.ourAssertionLive)
    }

    /// Releasing the assertion is not disarming. The clamshell mask stays set the whole time,
    /// because it is what makes the next lid close safe and it costs nothing to hold.
    func testReleasingTheAssertionNeverReleasesTheMask() {
        let (system, machine) = armedAtLaunch()
        let clamshellWritesBefore = system.clamshellWrites.filter { !$0 }.count

        machine.handle(.reconcileTick)

        XCTAssertEqual(system.clamshellWrites.filter { !$0 }.count, clamshellWritesBefore,
                       "releasing the idle assertion also cleared the clamshell mask")
        XCTAssertEqual(machine.state, .armed, "the session ended when the assertion was released")
        XCTAssertTrue(machine.weSetTheBit)
    }

    /// It must not thrash: once released, an unchanged machine produces no further writes.
    func testItDoesNotWriteOnEveryTickWhenNothingChanges() {
        let (system, machine) = armedAtLaunch()
        machine.handle(.reconcileTick)
        let writes = system.assertionWrites.count

        machine.handle(.reconcileTick)
        machine.handle(.reconcileTick)

        XCTAssertEqual(system.assertionWrites.count, writes,
                       "the assertion was rewritten on every tick: \(system.assertionWrites)")
    }
}
