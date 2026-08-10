import XCTest
@testable import LidwingCore

final class StateMachineTests: XCTestCase {

    // MARK: arming

    func testArmReachesArmedOnlyAfterGroundTruthAgrees() {
        let (system, _, _, watchdog, machine) = TestFixture.harness()

        let armEffects = machine.handle(.userArm)
        XCTAssertEqual(machine.state, .arming,
                       "arming must not be reported as armed before the machine agrees")
        XCTAssertTrue(armEffects.contains(.startTimer(.verify)))
        XCTAssertEqual(system.lastClamshellWrite, true)
        XCTAssertEqual(system.assertionWrites, [true])

        let verify = machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)
        XCTAssertTrue(verify.contains(.startTimer(.reassert)))
        XCTAssertFalse(verify.contains(.chime(.sealed)),
                       "no sound for something the user is looking at")
        XCTAssertEqual(watchdog.sent.first, .armed(bootSession: "BOOT-0000", pid: 4412))
    }

    func testArmFailsWhenGroundTruthNeverChanges() {
        let (system, ledger, audit, watchdog, machine) = TestFixture.harness()
        // The write reports success and the machine does not change. This is the exact
        // failure mode both real mechanisms exhibit, and it must never read as armed.
        system.mechanismWorks = false

        machine.handle(.userArm)
        XCTAssertEqual(machine.state, .arming)

        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .arming, "must keep polling inside the deadline")

        system.advance(StateMachine.verifyDeadline + 0.1)
        let effects = machine.handle(.verifyTick)

        XCTAssertEqual(machine.state, .failed)
        XCTAssertTrue(audit.contains(.applyNoEffect))
        XCTAssertTrue(effects.contains(.notify(.armFailed(.noEffect))))
        XCTAssertFalse(machine.weSetTheBit, "a failed arm must not leave us believing we own the bit")
        XCTAssertEqual(system.clamshellWrites, [true, false], "a failed arm rolls its own write back")
        XCTAssertEqual(system.assertionWrites, [true, false])
        XCTAssertNil(ledger.currentLedger, "the ledger must not claim an arm that never happened")
        XCTAssertFalse(watchdog.isConnected)
    }

    func testArmIsRefusedWithoutADeadMan() {
        let (system, ledger, _, watchdog, machine) = TestFixture.harness()
        watchdog.canConnect = false

        let effects = machine.handle(.userArm)

        XCTAssertEqual(effects, [.refuseArm(.watchdogUnavailable)])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(system.clamshellWrites.isEmpty, "we never touch the machine without a dead-man")
        XCTAssertNil(ledger.currentLedger)
    }

    func testLedgerIsWrittenBeforeTheFirstMutation() {
        let (system, ledger, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        XCTAssertEqual(ledger.writes, 1)
        XCTAssertEqual(ledger.currentLedger?.weSetClamshellBit, true)
        XCTAssertEqual(ledger.currentLedger?.bootSessionUUID, system.bootSessionUUID)
    }

    func testLedgerWriteFailureIsRecordedButDoesNotBlockArming() {
        struct Boom: Error {}
        let (_, ledger, audit, _, machine) = TestFixture.harness()
        ledger.writeError = Boom()

        machine.handle(.userArm)
        machine.handle(.verifyTick)

        XCTAssertEqual(machine.state, .armed)
        XCTAssertTrue(audit.contains(.ledgerWriteFailed))
    }

    func testArmRefusedWhenExternalDisplayOnAC() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.onAC = true
        system.onlineDisplayCount = 2

        XCTAssertEqual(machine.handle(.userArm), [.refuseArm(.externalDisplayOnAC)])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(system.clamshellWrites.isEmpty)
    }

    func testArmRefusedWhenAnotherAppAlreadyHoldsTheMachineAwake() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.foreignAssertionHolders = [ForeignHolder(pid: 812, name: "Amphetamine")]

        let effects = machine.handle(.userArm)
        XCTAssertEqual(effects, [.refuseArm(.foreignHolder(ForeignHolder(pid: 812, name: "Amphetamine")))])
        XCTAssertEqual(machine.state, .idle)
    }

    func testArmRefusedBelowTheBatteryFloor() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.batteryCurrent = 900        // 18 %
        system.batteryMax = 5000

        XCTAssertEqual(machine.handle(.userArm), [.refuseArm(.batteryTooLow)])
    }

    func testBagWarningIsShownOnBatteryAndNotRepeatedWithinAWeek() {
        let (system, _, _, _, machine) = TestFixture.harness()
        let first = machine.handle(.userArm)
        XCTAssertTrue(first.contains(.notify(.bagWarning)))
        machine.handle(.verifyTick)
        machine.handle(.userDisarm)
        system.clamshellCausesSleep = true
        machine.handle(.verifyTick)

        system.advance(3600)
        let second = machine.handle(.userArm)
        XCTAssertFalse(second.contains(.notify(.bagWarning)))
    }

    // MARK: the sound that matters

    /// The defining moment of the product: the lid shuts and the Mac keeps running. At that
    /// instant the screen is not an output channel, so this is the only confirmation the user
    /// can actually receive.
    func testClosingTheLidWhileArmedChimesExactlyOnce() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.lidState = .closed
        let closing = machine.handle(.lidChanged(.closed))
        XCTAssertTrue(closing.contains(.chime(.sealed)))

        // Four non-lid events also deliver a clamshell notification, and it arrives twice per
        // transition. Diffing rather than counting is what stops a charger plug from sounding
        // like a lid close.
        let again = machine.handle(.lidChanged(.closed))
        XCTAssertFalse(again.contains(.chime(.sealed)))
        XCTAssertFalse(machine.handle(.clamshellNotification).contains(.chime(.sealed)))
        XCTAssertFalse(machine.handle(.powerSourceChanged).contains(.chime(.sealed)))
    }

    func testStandingDownWithTheLidClosedChimes() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        system.lidState = .closed
        machine.handle(.lidChanged(.closed))

        system.batteryCurrent = 900
        machine.handle(.reconcileTick)
        system.advance(SafetyPolicy.debounceInterval + 0.1)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .disarming)

        system.clamshellCausesSleep = true
        let effects = machine.handle(.verifyTick)
        XCTAssertTrue(effects.contains(.chime(.standingDown)),
                      "the user cannot see the screen; tell them the Mac is going to sleep")
    }

    func testClosingTheLidWhileIdleIsSilent() {
        let (_, _, _, _, machine) = TestFixture.harness()
        XCTAssertFalse(machine.handle(.lidChanged(.closed)).contains(.chime(.sealed)))
    }

    // MARK: re-assertion

    func testEveryReassertTriggerReIssuesTheWriteAndCountsIt() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        let writesAfterArm = system.clamshellWrites.count

        let triggers: [LidwingEvent] = [
            .reassertTick,
            .powerSourceChanged,
            .displayReconfigured,
            .systemHasPoweredOn,
            .clamshellNotification
        ]
        for trigger in triggers {
            machine.handle(trigger)
        }

        XCTAssertEqual(system.clamshellWrites.count, writesAfterArm + triggers.count)
        XCTAssertEqual(machine.session?.reasserts, triggers.count)
        XCTAssertTrue(system.clamshellWrites.dropFirst().allSatisfy { $0 == true })
    }

    func testReassertDoesNothingWhenNotProtecting() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.reassertTick)
        XCTAssertTrue(system.clamshellWrites.isEmpty)
    }

    // MARK: sleeping while armed — invariant I5

    func testSystemWillSleepWhileArmedIsAlwaysAFailureAndIsAlwaysAcknowledged() {
        let (_, _, audit, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        let effects = machine.handle(.systemWillSleep(argument: 0xDEAD))

        XCTAssertEqual(effects.first, .allowPowerChange(0xDEAD), "acknowledge first, do work never")
        XCTAssertEqual(machine.state, .failed)
        XCTAssertTrue(audit.contains(.sleptWhileArmed))
        XCTAssertEqual(machine.session?.sleepFailureCount, 1)
    }

    func testCanSystemSleepIsAlwaysAcknowledgedAndNeverVetoed() {
        let (_, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        let effects = machine.handle(.canSystemSleep(argument: 7))
        XCTAssertEqual(effects, [.allowPowerChange(7)])
        XCTAssertEqual(machine.state, .armed, "acknowledging a sleep query does not change our state")
    }

    func testWakeAfterAFailedSessionReArmsImmediately() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        machine.handle(.systemWillSleep(argument: 1))
        XCTAssertEqual(machine.state, .failed)

        system.clamshellCausesSleep = true          // the kernel cleared our bit across sleep
        machine.handle(.systemHasPoweredOn)
        XCTAssertEqual(machine.state, .arming)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)
    }

    // MARK: guards

    func testBatteryFloorDisarmsOnlyAfterTwoAgreeingSamples() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.batteryCurrent = 900                 // 18 %, below the 20 % floor
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .degraded, "one sample warns; it does not end the session")

        system.advance(SafetyPolicy.debounceInterval + 0.1)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .disarming)

        system.clamshellCausesSleep = true
        let effects = machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(effects.contains(.notify(.autoDisarmed(.batteryFloor))))
    }

    func testThermalCriticalMustPersistBeforeItEndsASession() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.thermalState = .critical
        machine.handle(.thermalChanged)
        XCTAssertEqual(machine.state, .degraded, "a momentary spike must not kill an overnight run")

        system.advance(SafetyPolicy.thermalCriticalDwell + 1)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .disarming)
    }

    func testThermalSeriousDegradesAndNotifiesOnce() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.thermalState = .serious
        let first = machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .degraded)
        XCTAssertTrue(first.contains(.notify(.degraded(.thermalSerious))))

        let second = machine.handle(.reconcileTick)
        XCTAssertFalse(second.contains(.notify(.degraded(.thermalSerious))), "warn once per session")

        system.thermalState = .nominal
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .armed)
    }

    func testLeaseExpiryDisarms() {
        let (system, _, _, _, machine) = TestFixture.harness(
            settings: SafetySettings(maxDurationSeconds: 3600))
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.advance(3601)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .disarming)
        system.clamshellCausesSleep = true
        let effects = machine.handle(.verifyTick)
        XCTAssertTrue(effects.contains(.notify(.autoDisarmed(.timer))))
    }

    func testGroundTruthLostWhileArmedBecomesFailedNotDegraded() {
        let (system, _, audit, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        // Something cleared our bit and the re-assert cannot get it back.
        system.mechanismWorks = false
        system.clamshellCausesSleep = true
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .armed, "one mismatch gets one retry")

        system.advance(StateMachine.verifyDeadline + 0.1)
        let effects = machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .failed)
        XCTAssertTrue(audit.contains(.groundTruthLost))
        XCTAssertTrue(effects.contains(.notify(.groundTruthLost)))
    }

    // MARK: watchdog

    func testLosingTheWatchdogForcesDisarm() {
        let (_, _, audit, watchdog, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        watchdog.canConnect = false
        machine.handle(.watchdogLost)
        XCTAssertEqual(machine.state, .disarming, "we refuse to hold the bit with no dead-man")
        XCTAssertTrue(audit.contains(.watchdogUnavailable))
    }

    func testWatchdogLossThatCanBeRepairedDoesNotDisarm() {
        let (_, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        machine.handle(.watchdogLost)
        XCTAssertEqual(machine.state, .armed)
    }

    // MARK: disarming and termination

    func testDisarmRestoresTheMachineAndClosesTheRecord() {
        let (system, ledger, audit, watchdog, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        machine.handle(.userDisarm)
        XCTAssertEqual(machine.state, .disarming)
        XCTAssertEqual(system.lastClamshellWrite, false)
        XCTAssertEqual(system.assertionWrites.last, false)

        let effects = machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertFalse(effects.contains(.chime(.standingDown)),
                       "the lid is open; the menu already said it")
        XCTAssertNil(ledger.currentLedger)
        XCTAssertEqual(audit.records.count, 1)
        XCTAssertEqual(audit.records.first?.reason, .user)
        XCTAssertEqual(watchdog.sent.last, .disarmed)
        XCTAssertFalse(watchdog.isConnected)
    }

    func testDisarmThatDoesNotTakeEffectIsLoud() {
        let (system, _, audit, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.mechanismWorks = false               // the release is a no-op too
        machine.handle(.userDisarm)
        system.advance(StateMachine.verifyDeadline + 0.1)
        let effects = machine.handle(.verifyTick)

        XCTAssertEqual(machine.state, .failed)
        XCTAssertTrue(audit.contains(.releaseNoEffect))
        XCTAssertTrue(effects.contains(.notify(.releaseFailed)))
    }

    func testTerminationRunsTheFullDisarmSynchronously() {
        let (system, ledger, audit, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        machine.handle(.appWillTerminate)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(system.lastClamshellWrite, false)
        XCTAssertFalse(machine.weSetTheBit)
        XCTAssertNil(ledger.currentLedger)
        XCTAssertEqual(audit.records.first?.reason, .quit)
    }

    /// Invariant I7: bit 0x02 is shared with powerd and has no reference count. Clearing it
    /// where powerd legitimately wants it set would sleep somebody else's machine.
    func testWeNeverClearTheBitInAConfigurationPowerdOwns() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        let writesBefore = system.clamshellWrites.count

        system.desktopMode = true
        system.onAC = true
        machine.handle(.appWillTerminate)

        XCTAssertEqual(system.clamshellWrites.count, writesBefore,
                       "no clamshell write at all in the desktop-mode-on-AC configuration")
        XCTAssertFalse(machine.weSetTheBit)
    }

    // MARK: launch reconciliation

    func testLaunchOnAStockMachineIsIdle() {
        let (_, ledger, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(ledger.deletes, 0)
    }

    func testLaunchOnAModifiedMachineWithNoLedgerOffersRepairAndNeverActsSilently() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false

        let effects = machine.handle(.launch)

        XCTAssertEqual(machine.state, .repair)
        XCTAssertEqual(effects.first, .offerRepair(.noLedger))
        XCTAssertTrue(system.clamshellWrites.isEmpty, "launch must never clear a bit on its own")
    }

    func testLaunchWithALedgerFromAnotherProcessStandsDown() throws {
        let (system, ledger, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false
        ledger.stored = try Ledger(bootSessionUUID: system.bootSessionUUID,
                                   capturedAt: system.now,
                                   weSetClamshellBit: false,
                                   reason: "user",
                                   appVersion: "1.0.0").encoded()

        let effects = machine.handle(.launch)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(effects.first, .showForeignHolder)
        XCTAssertTrue(system.clamshellWrites.isEmpty)
    }

    func testRepairClearsTheBitOnlyWhenTheUserAsks() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .repair)

        machine.handle(.repairRequested)
        XCTAssertEqual(system.clamshellWrites, [false])
        XCTAssertEqual(machine.state, .idle)
    }

    func testLaunchOnAMachineWithNoLidIsUnsupported() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .noLid
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .unsupported)
        XCTAssertEqual(machine.handle(.userArm), [.refuseArm(.unsupportedOS)])
    }

    // MARK: stress

    func testOneThousandArmDisarmCyclesLeaveNoResidue() {
        let (system, ledger, _, watchdog, machine) = TestFixture.harness()
        for _ in 0..<1000 {
            machine.handle(.userArm)
            machine.handle(.verifyTick)
            XCTAssertEqual(machine.state, .armed)
            machine.handle(.userDisarm)
            system.clamshellCausesSleep = true
            machine.handle(.verifyTick)
            XCTAssertEqual(machine.state, .idle)
        }
        XCTAssertFalse(machine.weSetTheBit)
        XCTAssertFalse(machine.idleAssertionHeld)
        XCTAssertFalse(system.ourAssertionLive, "zero leaked assertions after a thousand cycles")
        XCTAssertEqual(system.clamshellCausesSleep, true, "ground truth is stock at the end")
        XCTAssertNil(ledger.currentLedger)
        XCTAssertFalse(watchdog.isConnected)
    }

    /// Property test: no sequence of events may leave the machine reporting protection while
    /// it does not own the mechanism.
    func testRandomEventSequencesNeverLeaveUsArmedWithoutTheBit() {
        var generator = SplitMix64(seed: 0x11D_C105_ED)
        let events: [LidwingEvent] = [
            .userArm, .userDisarm, .verifyTick, .reassertTick, .reconcileTick,
            .systemWillSleep(argument: 1), .systemHasPoweredOn, .canSystemSleep(argument: 1),
            .watchdogLost, .powerSourceChanged, .displayReconfigured, .thermalChanged,
            .clamshellNotification, .lidChanged(.closed), .lidChanged(.open)
        ]

        for _ in 0..<200 {
            let (system, _, _, watchdog, machine) = TestFixture.harness()
            machine.handle(.launch)
            for _ in 0..<60 {
                let event = events[Int(generator.next() % UInt64(events.count))]
                // Perturb the world as well as the machine.
                switch generator.next() % 8 {
                case 0: system.onAC.toggle()
                case 1: system.thermalState = ThermalState(rawValue: Int(generator.next() % 4))!
                case 2: system.batteryCurrent = Int(generator.next() % 5000)
                case 3: watchdog.canConnect = (generator.next() % 4 != 0)
                case 4: system.mechanismWorks = (generator.next() % 5 != 0)
                default: break
                }
                system.advance(Double(generator.next() % 120))
                machine.handle(event)

                if machine.state.isProtecting {
                    XCTAssertTrue(machine.weSetTheBit,
                                  "reported protection without owning the mechanism")
                }
                if machine.state == .idle || machine.state == .unsupported {
                    XCTAssertFalse(machine.weSetTheBit,
                                   "quiescent while still holding the mechanism")
                    XCTAssertFalse(machine.idleAssertionHeld)
                }
            }
        }
    }
}

/// Deterministic PRNG so a failing property test reproduces exactly.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Auto mode. The user's mental model is "stay awake while my agent is running", not "stay
/// awake until I remember to turn it off" — and a session that ends by itself cannot be
/// forgotten, which independently mitigates the battery, thermal and orphan-state problems.
final class AutoModeTests: XCTestCase {

    private func autoHarness() -> (MockSystem, StateMachine) {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.mode = .auto
        return (system, machine)
    }

    func testAnAgentAppearingArms() {
        let (system, machine) = autoHarness()
        machine.handle(.launch)
        system.runningAgentBinaries = ["claude"]
        machine.handle(.agentAppeared)
        XCTAssertEqual(machine.state, .arming)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)
    }

    func testAnAgentAppearingInManualModeDoesNothing() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.mode = .manual
        machine.handle(.launch)
        system.runningAgentBinaries = ["claude"]
        machine.handle(.agentAppeared)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(system.clamshellWrites.isEmpty)
    }

    /// The grace period exists because agents restart. Standing down the instant one exits
    /// would end the session between two steps of the same run.
    func testTheGracePeriodIsHonoured() {
        let (system, machine) = autoHarness()
        system.runningAgentBinaries = ["claude"]
        machine.handle(.agentAppeared)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)

        system.runningAgentBinaries = []
        machine.handle(.agentDisappeared)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .armed, "we stood down before the grace period elapsed")

        system.advance(400)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .disarming)
        system.clamshellCausesSleep = true
        let effects = machine.handle(.verifyTick)
        XCTAssertTrue(effects.contains(.notify(.autoDisarmed(.agentExited))))
    }

    func testAnAgentComingBackDuringTheGracePeriodKeepsTheSessionAlive() {
        let (system, machine) = autoHarness()
        system.runningAgentBinaries = ["claude"]
        machine.handle(.agentAppeared)
        machine.handle(.verifyTick)

        system.runningAgentBinaries = []
        machine.handle(.agentDisappeared)
        system.advance(120)
        system.runningAgentBinaries = ["claude"]
        machine.handle(.agentAppeared)

        system.advance(400)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .armed, "a restarted agent ended the session anyway")
    }

    func testSwitchingModesClearsAPendingStandDown() {
        let (system, machine) = autoHarness()
        system.runningAgentBinaries = ["claude"]
        machine.handle(.agentAppeared)
        machine.handle(.verifyTick)

        system.runningAgentBinaries = []
        machine.handle(.agentDisappeared)
        machine.mode = .manual
        machine.mode = .auto
        system.advance(400)
        machine.handle(.reconcileTick)
        XCTAssertEqual(machine.state, .armed,
                       "a stale grace-period clock survived a mode change")
    }
}
