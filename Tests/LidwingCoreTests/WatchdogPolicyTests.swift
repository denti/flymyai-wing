import XCTest
@testable import LidwingCore

/// The dead man's logic. This is the code that stands between a user and a laptop that cannot
/// sleep in a backpack, so it is tested harder than anything else here.
final class WatchdogPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_500_000)

    private func observation(watching: Bool = true,
                             client: Bool = true,
                             heartbeatAge: TimeInterval = 0,
                             desktopMode: Bool = false,
                             onAC: Bool = false) -> WatchdogPolicy.Observation {
        WatchdogPolicy.Observation(isWatching: watching,
                                   hasClient: client,
                                   lastHeartbeat: now.addingTimeInterval(-heartbeatAge),
                                   now: now,
                                   desktopMode: desktopMode,
                                   onAC: onAC)
    }

    // MARK: the primary signal

    func testEOFWhileWatchingRecoversImmediately() {
        XCTAssertEqual(WatchdogPolicy.onEOF(observation()), .recover(.appDied))
    }

    func testEOFWhenNotWatchingDoesNothing() {
        // The app disconnected after telling us it disarmed cleanly. Clearing a bit nobody set
        // would be us causing the harm we exist to prevent.
        XCTAssertEqual(WatchdogPolicy.onEOF(observation(watching: false)), .idle)
    }

    // MARK: the secondary signal

    func testAConnectedAppThatKeepsTalkingIsLeftAlone() {
        XCTAssertEqual(WatchdogPolicy.tick(observation(heartbeatAge: 14)), .idle)
    }

    func testSilenceBeyondTheDeadlineRecovers() {
        XCTAssertEqual(WatchdogPolicy.tick(observation(heartbeatAge: 16)),
                       .recover(.heartbeatLost))
    }

    /// A five-second deadline would end an overnight run the first time a CPU-saturated build
    /// stalls a run loop. Fifteen is the number, and it is a decision rather than an accident.
    func testTheHeartbeatDeadlineIsGenerous() {
        XCTAssertGreaterThanOrEqual(WatchdogPolicy.heartbeatDeadline, 15)
    }

    func testNoClientAtAllWhileWatchingRecovers() {
        XCTAssertEqual(WatchdogPolicy.tick(observation(client: false)), .recover(.noClient))
    }

    func testNotWatchingIsAlwaysIdle() {
        XCTAssertEqual(WatchdogPolicy.tick(observation(watching: false, client: false,
                                                       heartbeatAge: 9_999)), .idle)
    }

    // MARK: invariant I7 — the configuration we must never clear in

    func testWeStandDownWherePowerdLegitimatelyOwnsTheClamshellState() {
        // External display plus AC: the kernel term is `desktopMode && acAdaptorConnected`, and
        // clearing the bit here would put somebody's lid-closed Mac to sleep mid-operation.
        XCTAssertEqual(WatchdogPolicy.onEOF(observation(desktopMode: true, onAC: true)),
                       .standDown(.appDied))
        XCTAssertEqual(WatchdogPolicy.tick(observation(client: false, desktopMode: true, onAC: true)),
                       .standDown(.noClient))
    }

    func testDesktopModeAloneIsNotEnoughToStandDown() {
        // On battery the kernel term is false regardless of desktop mode, so powerd does not
        // own the bit and we do have to clean up after ourselves.
        XCTAssertEqual(WatchdogPolicy.onEOF(observation(desktopMode: true, onAC: false)),
                       .recover(.appDied))
        XCTAssertEqual(WatchdogPolicy.onEOF(observation(desktopMode: false, onAC: true)),
                       .recover(.appDied))
    }

    // MARK: startup

    func testAMarkerFromAPreviousBootIsStaleAndIsJustDeleted() {
        // The mask is a kernel variable initialised to zero at boot, so the restart already
        // undid it. Writing to the machine here would be a pointless mutation at every boot.
        XCTAssertEqual(WatchdogPolicy.atStartup(markerBootSession: "BOOT-OLD",
                                                currentBootSession: "BOOT-NEW"),
                       .deleteStaleMarker)
    }

    func testNoMarkerMeansNothingToDo() {
        XCTAssertEqual(WatchdogPolicy.atStartup(markerBootSession: nil,
                                                currentBootSession: "BOOT-NEW"), .idle)
    }

    func testAMarkerFromThisBootWaitsForTheAppRatherThanActing() {
        // The app may simply be slow to start after a watchdog restart. The grace period, then
        // the ordinary tick with no client, is what turns this into a recovery.
        XCTAssertEqual(WatchdogPolicy.atStartup(markerBootSession: "BOOT-NOW",
                                                currentBootSession: "BOOT-NOW"), .idle)
        XCTAssertGreaterThanOrEqual(WatchdogPolicy.orphanGrace, 5)
    }

    // MARK: exhaustiveness

    func testEveryTriggerHasAStableWireName() {
        let triggers: [WatchdogPolicy.Trigger] = [.appDied, .heartbeatLost, .noClient,
                                                  .orphanAtStartup, .watchdogTerminating]
        let names = triggers.map(\.rawValue)
        XCTAssertEqual(Set(names).count, triggers.count)
        // These strings end up in recovered.json, which the app reads back to tell the user
        // what happened. Renaming one silently breaks that explanation.
        XCTAssertTrue(names.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") })
    }
}
