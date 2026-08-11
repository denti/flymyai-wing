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

    /// **The regression test for the defect that made the product do nothing at all.**
    ///
    /// This used to assert a refusal, and on a real Mac that meant Lidwing never worked once:
    /// `SMAppService.agent` cannot register an ad-hoc signed app with no Team ID, so no watchdog
    /// existed, and every arm was refused with "could not start its safety watchdog". Gating the
    /// feature on a component whose only job is cleanup after a failure is backwards.
    ///
    /// What is risked by arming without one is bounded: if the app then dies, the Mac cannot
    /// sleep on lid close until the next restart - and `clamshellSleepDisableMask` is initialised
    /// to 0 in `IOPMrootDomain::start()`, so a reboot always clears it.
    func testItStillArmsWhenNoDeadManCanBeEstablished() {
        let (system, ledger, audit, watchdog, machine) = TestFixture.harness()
        watchdog.canConnect = false

        let effects = machine.handle(.userArm)

        XCTAssertEqual(machine.state, .arming, "the product refused to work with no watchdog")
        XCTAssertFalse(effects.contains { if case .refuseArm = $0 { return true } else { return false } })
        XCTAssertEqual(system.lastClamshellWrite, true)
        XCTAssertNotNil(ledger.currentLedger, "armed without recording durable intent")
    }

    /// ...and it is never silent about it. A session with no dead-man must be distinguishable in
    /// the audit from a protected one, or the record cannot explain a Mac left awake.
    func testArmingWithNoDeadManIsRecorded() {
        let (_, _, audit, watchdog, machine) = TestFixture.harness()
        watchdog.canConnect = false

        machine.handle(.userArm)

        XCTAssertTrue(audit.contains(.watchdogUnavailable),
                      "a session with no dead-man looks exactly like a protected one")
    }

    /// The dead-man is still preferred and still used whenever it exists.
    func testItStillUsesTheDeadManWhenThereIsOne() {
        let (_, _, _, watchdog, machine) = TestFixture.harness()

        machine.handle(.userArm)
        machine.handle(.verifyTick)

        XCTAssertTrue(watchdog.isConnected)
        XCTAssertEqual(watchdog.sent.first, .armed(bootSession: "BOOT-0000", pid: 4412))
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

        XCTAssertEqual(machine.handle(.userArm), [.refuseArm(.externalDisplayOnAC, .askNow)])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(system.clamshellWrites.isEmpty)
    }

    /// **Corrected in decision 0013.** This used to assert that Lidwing stood down whenever any
    /// other app held a power assertion. That was wrong, and it was wrong in the way that
    /// mattered most: on a developer Mac running an agent - the exact machine this product
    /// exists for - Claude holds a persistent idle assertion and Claude Code spawns
    /// `caffeinate -i -t 300` per command, so Lidwing would have refused to arm every single
    /// time, forever.
    ///
    /// An idle assertion cannot stop a lid close. Clamshell sleep is a *demand* sleep, and only
    /// idle sleep can be vetoed by an assertion - which is precisely why this product needs
    /// selector 12 rather than an assertion of its own. So another app holding one is not doing
    /// Lidwing's job, and must not stop Lidwing doing it.
    func testAnotherAppsIdleAssertionDoesNotStopLidwingArming() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.foreignAssertionHolders = [
            ForeignHolder(pid: 41846, name: "Claude", kind: .idleSleep),
            ForeignHolder(pid: 47116, name: "caffeinate", kind: .idleSleep, isTransient: true)
        ]

        let effects = machine.handle(.userArm)

        XCTAssertEqual(machine.state, .arming, "refused to arm on an ordinary developer Mac")
        XCTAssertFalse(effects.contains { if case .refuseArm = $0 { return true } else { return false } })
        XCTAssertEqual(system.lastClamshellWrite, true)
    }

    /// Nor does a stronger one. Lidwing's mechanism is a separate kernel mask that it sets and
    /// clears itself, so there is nothing to fight over - and the user's agent run should not
    /// die because Internet Sharing happens to be on.
    func testAStrongerForeignHoldAlsoDoesNotStopArming() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.foreignAssertionHolders = [
            ForeignHolder(pid: 366, name: "Internet Sharing", kind: .systemSleep)
        ]

        machine.handle(.userArm)

        XCTAssertEqual(machine.state, .arming)
    }
    func testArmRefusedBelowTheBatteryFloor() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.batteryCurrent = 900        // 18 %
        system.batteryMax = 5000

        XCTAssertEqual(machine.handle(.userArm), [.refuseArm(.batteryTooLow, .askNow)])
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

    // MARK: coming back after a disarm
    //
    // "Install it and it works" was true exactly once. The default mode is manual, so nothing
    // re-armed after a disarm - and the duration lease disarms after eight hours. On a Mac that
    // stays logged in for days, Lidwing protected for one lease after login and then silently
    // never again, while the user believed they had installed something that keeps working.

    /// A wake is a new working session, and the zero-step promise applies again.
    func testItArmsAgainAfterTheMachineWakes() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        machine.handle(.armAtLaunch)
        machine.handle(.verifyTick)
        machine.handle(.userDisarm)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .idle)

        machine.handle(.systemHasPoweredOn)

        XCTAssertEqual(machine.state, .arming, "protection never came back after a disarm")
        XCTAssertEqual(system.lastClamshellWrite, true)
    }

    /// A wake cannot defeat the duration lease, because reaching it requires the machine to have
    /// actually slept - which is the outcome the lease exists to force. The run is already over.
    func testAWakeCannotExtendARunPastItsLease() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        machine.handle(.armAtLaunch)
        machine.handle(.verifyTick)

        system.advance(Double(machine.settings.maxDurationSeconds ?? 0) + 1)
        machine.handle(.reconcileTick)
        XCTAssertNotEqual(machine.state, .armed, "the lease did not expire")

        // The new session that follows a sleep gets a fresh lease, not a continuation.
        machine.handle(.verifyTick)
        machine.handle(.systemHasPoweredOn)
        if machine.state == .arming {
            machine.handle(.verifyTick)
            XCTAssertEqual(machine.session?.armedAt, system.now,
                           "the new session inherited the old one's start time")
        }
    }

    /// Somebody who turned the preference off is not overruled by a wake.
    func testItDoesNotArmAfterAWakeWhenTheUserTurnedThatOff() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.armsItselfWhenThereIsAReason = false
        machine.handle(.launch)

        machine.handle(.systemHasPoweredOn)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(system.clamshellWrites.isEmpty, "armed itself against the user's preference")
    }

    /// Every refusal still applies on this path, and none of them may interrupt - it runs with
    /// no user present by definition.
    func testTheWakeArmStillRefusesQuietlyWhenItShould() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.batteryCurrent = 100
        system.batteryMax = 5000          // below the floor
        machine.handle(.launch)

        let effects = machine.handle(.systemHasPoweredOn)

        XCTAssertEqual(machine.state, .idle)
        for effect in effects {
            if case .refuseArm(_, let prompt) = effect {
                XCTAssertEqual(prompt, .quietly, "a wake opened a dialog with nobody there")
            }
        }
    }

    /// Waking while already armed re-asserts rather than starting a second session.
    func testAWakeWhileArmedDoesNotStartASecondSession() {
        let (_, _, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        machine.handle(.armAtLaunch)
        machine.handle(.verifyTick)
        let armedAt = machine.session?.armedAt

        machine.handle(.systemHasPoweredOn)

        XCTAssertEqual(machine.state, .armed)
        XCTAssertEqual(machine.session?.armedAt, armedAt, "the session restarted on a wake")
    }

    // MARK: the powerd stomp
    //
    // The known hole in this mechanism, and the one the 8-hour soak exists to measure: powerd
    // re-evaluates clamshell behaviour on charger and display events and can clear the bit we
    // set. The recovery path was written for it, and until now only its *failure* was tested -
    // the case where the bit cannot be recovered. The ordinary case, where it is recovered
    // within milliseconds, is what a user actually experiences every time they plug in.

    /// The charger goes in, powerd clears the bit, and the event itself brings it back - without
    /// waiting for any timer.
    func testAChargerEventRecoversTheBitImmediately() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)

        // powerd stomps it: the machine reports it would sleep on lid close again.
        system.clamshellCausesSleep = true
        let writesBefore = system.clamshellWrites.count

        machine.handle(.powerSourceChanged)

        XCTAssertEqual(system.clamshellWrites.count, writesBefore + 1,
                       "the charger event did not re-issue the write")
        XCTAssertEqual(system.clamshellCausesSleep, false, "the bit was not recovered")
        XCTAssertEqual(machine.state, .armed)
    }

    /// A display being attached or removed is the other trigger powerd reacts to.
    func testADisplayEventAlsoRecoversTheBit() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.clamshellCausesSleep = true
        machine.handle(.displayReconfigured)

        XCTAssertEqual(system.clamshellCausesSleep, false)
        XCTAssertEqual(machine.state, .armed)
    }

    /// If the event is missed, the five-second reconcile catches it. Two independent paths to
    /// the same recovery, which is the point: the notification is best-effort and the timer is not.
    func testTheReconcileTickRecoversAStompThatMissedItsEvent() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.clamshellCausesSleep = true
        machine.handle(.reconcileTick)

        XCTAssertEqual(system.clamshellCausesSleep, false, "the reconcile did not restore it")
        XCTAssertEqual(machine.state, .armed, "a recovered stomp is not a failure")
    }

    /// **The rule from decision 0014, applied to the most frequent event in the product.**
    /// Plugging in a charger recovers in milliseconds and there is nothing for the user to do,
    /// so it must produce no notification, no chime and no failure state. Five plug/unplug
    /// cycles is what the soak asks the owner to perform.
    func testFivePlugCyclesRecoverSilentlyAndStayArmed() {
        let (system, _, audit, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        var effects: [LidwingEffect] = []
        for _ in 0..<5 {
            system.onAC = true
            system.clamshellCausesSleep = true          // powerd stomps on the transition
            effects += machine.handle(.powerSourceChanged)
            system.onAC = false
            system.clamshellCausesSleep = true
            effects += machine.handle(.powerSourceChanged)
        }

        XCTAssertEqual(machine.state, .armed, "five charger events ended the session")
        XCTAssertEqual(system.clamshellCausesSleep, false)
        XCTAssertFalse(effects.contains { if case .notify = $0 { return true } else { return false } },
                       "a recovered stomp interrupted the user: \(effects)")
        XCTAssertFalse(effects.contains { if case .chime = $0 { return true } else { return false } },
                       "a recovered stomp made a sound")
        XCTAssertFalse(audit.contains(.groundTruthLost),
                       "a recovery that worked was recorded as a loss")
    }

    /// Every recovery is counted, because the number is the evidence about how often powerd
    /// actually does this - and that number is the whole reason the soak is worth eight hours.
    func testEveryRecoveryIsCountedInTheSessionRecord() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        let before = machine.session?.reasserts ?? 0

        for _ in 0..<3 {
            system.clamshellCausesSleep = true
            machine.handle(.powerSourceChanged)
        }

        XCTAssertEqual((machine.session?.reasserts ?? 0) - before, 3,
                       "the audit record cannot show how often the bit was stomped")
    }

    /// A stomp that is *not* recovered is still a failure, loudly. This is the boundary either
    /// side of which the product means something different.
    func testAStompThatCannotBeRecoveredStillFails() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)

        system.mechanismWorks = false
        system.clamshellCausesSleep = true
        machine.handle(.reconcileTick)
        system.advance(StateMachine.verifyDeadline + 0.1)
        let effects = machine.handle(.reconcileTick)

        XCTAssertEqual(machine.state, .failed)
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
        XCTAssertEqual(effects.first, .offerRepair(.noLedger, .quietly))
        XCTAssertTrue(system.clamshellWrites.isEmpty, "launch must never clear a bit on its own")
    }

    // MARK: armed but owned by nobody
    //
    // The state a real Mac was in when Lidwing first launched on it: a spike probe had set the
    // clamshell bit from a different process and been interrupted without disarming. It is not a
    // synthetic case - a crashed previous instance, a second copy of the app, or another utility
    // produces exactly the same thing, because the bit is global, unowned and carries no
    // reference count. Lidwing found the mechanism armed while owning nothing, went down the
    // repair path, and crashed presenting a modal from inside `applicationDidFinishLaunching`.

    /// The regression test for that crash: the launch path must offer repair **quietly**.
    /// `.askNow` is what opens a dialog, and a dialog on this path is what died.
    func testLaunchOnAnArmedButUnownedMachineNeverAsksToBlock() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false      // somebody has armed this machine

        let effects = machine.handle(.launch)

        XCTAssertEqual(machine.state, .repair)
        XCTAssertEqual(effects, [.offerRepair(.noLedger, .quietly), .uiNeedsRefresh])
        for effect in effects {
            if case .offerRepair(_, let prompt) = effect {
                XCTAssertEqual(prompt, .quietly,
                               "the launch path asked to open a dialog; that crashed a real Mac")
            }
        }
    }

    /// Whatever else happens, launching on a machine somebody else armed must not touch it.
    func testLaunchOnAnArmedButUnownedMachineTouchesNothing() {
        let (system, ledger, _, watchdog, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false

        machine.handle(.launch)

        XCTAssertTrue(system.clamshellWrites.isEmpty, "wrote to a bit it does not own")
        XCTAssertTrue(system.assertionWrites.isEmpty, "took an assertion while merely looking")
        XCTAssertFalse(machine.weSetTheBit, "claimed a bit set by another process")
        XCTAssertEqual(ledger.writes, 0, "recorded intent for something it did not do")
        XCTAssertEqual(watchdog.connectAttempts, 0, "started a dead-man for a session it has not")
    }

    /// And it must not claim to be protecting. The icon and the menu are driven from this.
    func testAnArmedButUnownedMachineIsNotReportedAsProtected() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false

        machine.handle(.launch)

        XCTAssertFalse(machine.state.isProtecting,
                       "a machine somebody else armed was reported as protected by us")
    }

    /// The user asking for something is the one case where a dialog is right - and the ellipsis
    /// in "Repair Now..." promises one.
    func testAskingToArmWhileUnownedIsAllowedToOpenADialog() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false
        machine.handle(.launch)

        let effects = machine.handle(.userArm)

        XCTAssertEqual(effects.first, .offerRepair(.noLedger, .askNow))
    }

    /// Repair, once the user asks for it, clears a bit this process never set - which is the
    /// entire point of the separate `repairClamshellState` call.
    func testRepairClearsABitWeNeverSet() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .repair)

        machine.handle(.repairRequested)

        XCTAssertEqual(system.repairCalls, 1, "repair went through the ordinary write, which "
                       + "refuses to clear a bit we did not set")
        XCTAssertEqual(machine.state, .idle)
    }

    // MARK: arming itself at launch (decision 0012)

    /// Install to value is zero steps: launch and it is already protecting.
    func testItArmsItselfAtLaunchOnAHealthyMac() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .idle)

        machine.handle(.armAtLaunch)

        XCTAssertEqual(machine.state, .arming)
        XCTAssertEqual(system.lastClamshellWrite, true)
    }

    /// **The invariant this whole path lives under.** Presenting a modal from the launch path is
    /// what crashed v0.1.0, and arming at launch means the refusal path runs there too - on a Mac
    /// with another keep-awake tool, refusal is the *likely* outcome, not the rare one.
    func testNothingOnTheLaunchPathMayEverInterrupt() {
        let cases: [(String, (MockSystem) -> Void)] = [
            ("another app holds it", { $0.foreignAssertionHolders =
                [ForeignHolder(pid: 812, name: "caffeinate")] }),
            ("the battery is below the floor", { $0.batteryCurrent = 100; $0.batteryMax = 5000 }),
            ("the Mac is too hot", { $0.thermalState = .critical }),
            ("there is no lid", { $0.lidState = .noLid }),
            ("an external display on AC", { $0.onlineDisplayCount = 2; $0.onAC = true })
        ]
        for (name, arrange) in cases {
            let (system, _, _, _, machine) = TestFixture.harness()
            arrange(system)
            machine.handle(.launch)

            for effect in machine.handle(.armAtLaunch) {
                switch effect {
                case .refuseArm(_, let prompt), .offerRepair(_, let prompt):
                    XCTAssertEqual(prompt, .quietly,
                                   "\(name): the launch path asked to open a dialog")
                default:
                    break
                }
            }
        }
    }

    /// A Mac that another tool is holding awake: Lidwing arms anyway and *says who*. Standing
    /// down would mean the machine this product was built for is the one machine it never works
    /// on. Decision 0013.
    func testItStillArmsAtLaunchWhenSomethingElseHoldsTheMac() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.foreignAssertionHolders = [
            ForeignHolder(pid: 47116, name: "caffeinate", kind: .idleSleep, isTransient: true)
        ]
        machine.handle(.launch)

        machine.handle(.armAtLaunch)

        XCTAssertEqual(machine.state, .arming,
                       "a caffeinate that releases itself in four minutes stopped the product")
        XCTAssertEqual(system.lastClamshellWrite, true)
    }
    /// Launching on a machine somebody else armed must not quietly arm on top of it.
    func testItDoesNotArmItselfIntoARepairState() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.clamshellCausesSleep = false
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .repair)

        let effects = machine.handle(.armAtLaunch)

        XCTAssertTrue(effects.isEmpty, "armed itself while the machine needed repair")
        XCTAssertTrue(system.clamshellWrites.isEmpty)
        XCTAssertEqual(machine.state, .repair)
    }

    /// Arming twice would take a second assertion and write a second ledger.
    func testArmingAtLaunchTwiceDoesNothingTheSecondTime() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        machine.handle(.armAtLaunch)
        let writes = system.clamshellWrites.count

        XCTAssertTrue(machine.handle(.armAtLaunch).isEmpty)
        XCTAssertEqual(system.clamshellWrites.count, writes)
    }

    /// The duration lease has to start at launch. An app that turns itself on at login and only
    /// starts counting at the first lid close would hold a Mac awake all day.
    func testTheDurationLeaseStartsWhenItArmsItself() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        machine.handle(.armAtLaunch)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)

        system.advance(machine.settings.maxDurationSeconds.map(Double.init) ?? 0 + 1)
        machine.handle(.reconcileTick)

        XCTAssertNotEqual(machine.state, .armed, "the lease never started")
    }

    /// A desktop at launch is indistinguishable from a laptop whose lid driver has not reported
    /// yet: both have no `AppleClamshellState` key, which is `.unknown`, and `.unknown` is
    /// deliberately not collapsed into `.noLid` because doing so would disable the product at
    /// every login on a real laptop.
    ///
    /// Arming there would take a genuine idle-sleep assertion and hold a Mac mini awake for the
    /// whole duration lease, for a feature that machine cannot use. Waiting costs nothing: the
    /// lid driver reports within moments on a laptop, and the ten-second determination settles
    /// the desktop case.
    func testItDoesNotArmItselfBeforeItKnowsThereIsALid() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .unknown
        machine.handle(.launch)

        let effects = machine.handle(.armAtLaunch)

        XCTAssertTrue(system.assertionWrites.isEmpty,
                      "held a machine awake before knowing it had a lid to close")
        XCTAssertTrue(system.clamshellWrites.isEmpty)
        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(effects.isEmpty)
    }

    /// ...and once the lid does report, the intent it was holding is honoured.
    func testTheDeferredArmHappensWhenTheLidReports() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .unknown
        machine.handle(.launch)
        machine.handle(.armAtLaunch)
        XCTAssertEqual(machine.state, .idle)

        system.lidState = .open
        machine.handle(.lidChanged(.open))

        XCTAssertEqual(machine.state, .arming, "the deferred arm never happened")
        XCTAssertEqual(system.lastClamshellWrite, true)
    }

    /// On a Mac with no lid the deferred intent never fires.
    ///
    /// There is no separate flag-clearing step for this, and there was: it turned out to be
    /// redundant with `onArmAtLaunch`'s own `state == .idle` guard, since a machine with no lid
    /// is `.unsupported`. Deleting that line changed nothing any test could see, so it went -
    /// a line that cannot fail is a line that only looks like a safeguard.
    ///
    /// The remaining behaviour is deliberate: if the no-lid determination is later reversed by
    /// a real clamshell report, the machine returns to `.idle` and the launch intent is honoured
    /// then. That is the right answer - the Mac does have a lid after all.
    func testTheDeferredArmIsForgottenOnAMachineWithNoLid() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .unknown
        machine.handle(.launch)
        machine.handle(.armAtLaunch)

        system.lidState = .noLid
        machine.handle(.lidDeterminedAbsent)
        XCTAssertEqual(machine.state, .unsupported)

        machine.handle(.lidChanged(.open))
        XCTAssertTrue(system.clamshellWrites.isEmpty, "armed a machine that has no lid")
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

    /// The case Repair exists for: a *previous* process left the bit set and this one does not
    /// own it. `setClamshellSleepDisabled(false)` refuses to clear a bit it did not set — that
    /// is invariant I7 and it is right — so Repair has to go through the one path that is
    /// allowed to, or the button reports success and changes nothing.
    func testRepairClearsABitLeftBehindByAPreviousProcess() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.simulateBitSetByAnotherProcess()
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .repair)

        machine.handle(.repairRequested)

        XCTAssertEqual(system.repairCalls, 1, "Repair went through the path that refuses to act")
        XCTAssertEqual(system.clamshellCausesSleep, true, "the machine was not actually repaired")
        XCTAssertEqual(machine.state, .idle)
    }

    func testRepairIsOnlyReachableFromTheRepairState() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .idle)
        machine.handle(.repairRequested)
        XCTAssertEqual(system.repairCalls, 0, "Repair ran without the user being in that state")
    }

    func testRepairThatDoesNotTakeEffectIsLoud() {
        let (system, _, audit, _, machine) = TestFixture.harness()
        system.simulateBitSetByAnotherProcess()
        machine.handle(.launch)

        system.mechanismWorks = false            // the clear is a no-op, as on a broken OS
        let effects = machine.handle(.repairRequested)

        XCTAssertEqual(machine.state, .failed)
        XCTAssertTrue(audit.contains(.releaseNoEffect))
        XCTAssertTrue(effects.contains(.notify(.releaseFailed)))
    }

    func testLaunchOnAMachineWithNoLidIsUnsupported() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .noLid
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .unsupported)
        XCTAssertEqual(machine.handle(.userArm), [.refuseArm(.unsupportedOS, .askNow)])
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

/// A Mac with no lid. The clamshell mask is meaningless there — there is nothing to close —
/// and showing "Awake, you can close the lid" on a Mac mini would be the product lying about
/// the one thing it does.
final class NoLidTests: XCTestCase {

    func testAnAbsentKeyAtLaunchIsNotYetEvidence() {
        let (system, _, _, _, machine) = TestFixture.harness()
        // A laptop reports nothing until the lid driver's first report. Concluding "no lid"
        // here would disable the product at every login.
        system.lidState = .unknown
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .idle, "we gave up on a lid that had not reported yet")
    }

    func testSilenceAfterTheGracePeriodIsEvidence() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .unknown
        machine.handle(.launch)

        system.lidState = .noLid            // the host concluded it after ten silent seconds
        machine.handle(.lidDeterminedAbsent)
        XCTAssertEqual(machine.state, .unsupported)
        XCTAssertEqual(machine.handle(.userArm), [.refuseArm(.unsupportedOS, .askNow)])
    }

    func testTheConclusionIsReversible() {
        let (system, _, _, _, machine) = TestFixture.harness()
        system.lidState = .noLid
        machine.handle(.lidDeterminedAbsent)
        XCTAssertEqual(machine.state, .unsupported)

        // A slow lid driver reported late. The machine has a lid after all.
        system.lidState = .open
        machine.handle(.launch)
        XCTAssertEqual(machine.state, .idle)
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)
    }

    func testWeNeverConcludeNoLidWhileProtecting() {
        let (system, _, _, _, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        XCTAssertEqual(machine.state, .armed)

        system.lidState = .noLid
        machine.handle(.lidDeterminedAbsent)
        XCTAssertEqual(machine.state, .armed, "a protected session was ended by a probe")
    }
}

/// What happens after the machine slept and the recovery did not work either. The user went to
/// sleep expecting an overnight run; standing down silently would be the quietest possible way
/// to lose it for them.
final class FailedRecoveryTests: XCTestCase {

    func testAFailedReArmTellsTheUserRatherThanGoingQuiet() {
        let (system, _, _, watchdog, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        machine.handle(.systemWillSleep(argument: 1))
        XCTAssertEqual(machine.state, .failed)

        // The socket did not survive the sleep and cannot be re-established, so there is no
        // dead-man and we refuse to hold the bit (invariant I2).
        watchdog.disconnect()
        watchdog.canConnect = false
        let effects = machine.handle(.systemHasPoweredOn)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertTrue(effects.contains(.chime(.failure)))
        XCTAssertTrue(effects.contains(.notify(.autoDisarmed(.watchdogLost))),
                      "the session ended and the user was not told: \(effects)")
        _ = system
    }

    func testTheRecordStillCarriesTheSleepEvenWhenTheReasonIsSomethingElse() {
        let (_, _, audit, watchdog, machine) = TestFixture.harness()
        machine.handle(.userArm)
        machine.handle(.verifyTick)
        machine.handle(.systemWillSleep(argument: 1))
        watchdog.disconnect()
        watchdog.canConnect = false
        machine.handle(.systemHasPoweredOn)

        let record = audit.records.last
        XCTAssertEqual(record?.reason, .watchdogLost)
        XCTAssertEqual(record?.groundTruthFailures, 1, "the sleep vanished from the record")
        XCTAssertTrue(record?.failures.contains(.sleptWhileArmed) ?? false)
        XCTAssertFalse(record?.isCleanSoak ?? true)
    }
}
