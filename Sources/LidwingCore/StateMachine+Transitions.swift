import Foundation

// The transitions themselves, in an extension so that the type's own body stays readable and
// the file stays a size a person can hold in their head. Same type, same invariants.
extension StateMachine {

    // MARK: Launch and reconciliation

    func onLaunch() -> [LidwingEffect] {
        // Before anything else, and regardless of what the ledger says: did macOS change under
        // us? This only records the question. Nothing here arms, and nothing here refuses.
        switch OSChangeWatch.compare(lastVerifiedOS: lastVerifiedOS,
                                     current: identity.osVersion) {
        case .noBaseline, .unchanged:
            pendingOSRecheck = nil
        case .changed(let from, let to):
            // Not an `audit.note`: that sink takes an `AuditFailure`, and a macOS update is not
            // a failure. Widening that enum to fit would quietly change what `AuditRecord.
            // failures` means - "what went wrong during this session" - for every reader of
            // every audit line ever written. The host logs this one instead.
            pendingOSRecheck = (from: from, to: to)
        }

        if facade.lidState == .noLid {
            state = .unsupported
            return []
        }

        let truth = GroundTruth(clamshellCausesSleep: facade.clamshellCausesSleep,
                                sleepDisabled: facade.sleepDisabled)
        let decision = LedgerReconciler.decide(rawLedger: ledgerStore.read(),
                                               truth: truth,
                                               currentBootSession: facade.bootSessionUUID)
        switch decision {
        case .stock(let deleteStale):
            if deleteStale { ledgerStore.delete() }
            state = .idle
            repairCause = nil
            return []
        case .repair(let cause):
            state = .repair
            repairCause = cause
            return [.offerRepair(cause, .quietly)]
        case .standDown:
            state = .idle
            repairCause = nil
            return [.showForeignHolder]
        }
    }

    /// The user pressed Repair. This is the only path that clears a bit we are not certain we
    /// set, and it exists because doing it silently is worse.
    func onRepairRequested() -> [LidwingEffect] {
        guard state == .repair else { return [] }
        // `repairClamshellState`, not `setClamshellSleepDisabled(false)`: the latter refuses to
        // clear a bit this process did not set, which is exactly the situation Repair exists
        // for. Using it here would make the button report success and change nothing.
        _ = facade.repairClamshellState()
        _ = facade.setIdleAssertion(false)
        weSetTheBit = false
        idleAssertionHeld = false
        ledgerStore.delete()

        let truth = GroundTruth(clamshellCausesSleep: facade.clamshellCausesSleep,
                                sleepDisabled: facade.sleepDisabled)
        if truth.isStock {
            state = .idle
            repairCause = nil
            return []
        }
        state = .failed
        audit.note(.releaseNoEffect, at: facade.now, context: ["phase": "repair"])
        return [.chime(.failure), .notify(.releaseFailed)]
    }

    /// The lid never reported within the grace period, so this Mac does not have one.
    ///
    /// On a desktop the clamshell mask is meaningless: there is no lid to close and nothing to
    /// prevent. Staying in `idle` would let the user turn Lidwing on and would show them a
    /// confident "Awake - you can close the lid" on a machine with no lid to close, which is
    /// the product lying about the one thing it does.
    ///
    /// Deliberately reversible: if a clamshell notification arrives afterwards — a slow lid
    /// driver, a hardware quirk — the next arm request finds a real lid and proceeds.
    func onLidDeterminedAbsent() -> [LidwingEffect] {
        // Never while protecting. If we somehow got here armed, the lid evidently exists.
        guard state == .idle || state == .repair else { return [] }
        guard facade.lidState == .noLid else { return [] }
        state = .unsupported
        return []
    }

    // MARK: Arming

    func shouldShowBagWarning() -> Bool {
        guard let last = lastBagWarningAt else { return true }
        return facade.now.timeIntervalSince(last) >= 7 * 24 * 3600
    }

    // MARK: Verification of both transitions

    func onVerifyTick() -> [LidwingEffect] {
        guard let started = phaseStartedAt else {
            // No deadline means nothing is being verified. Stop rather than leaving a 10 Hz
            // timer running for the life of the process.
            return [.stopTimer(.verify)]
        }
        let elapsed = facade.now.timeIntervalSince(started)

        switch state {
        case .arming:
            // Both mechanisms return success while doing nothing. The only acceptance signal
            // is the machine's own answer.
            if facade.clamshellCausesSleep == false {
                return completeArming()
            }
            if elapsed >= StateMachine.verifyDeadline {
                releaseMechanism()
                watchdog.disconnect()
                ledgerStore.delete()
                audit.note(.applyNoEffect, at: facade.now, context: ["phase": "verify"])
                session = nil
                state = .failed
                phaseStartedAt = nil
                return [.stopTimer(.verify), .endActivity, .chime(.failure), .notify(.armFailed(.noEffect))]
            }
            return []

        case .disarming:
            if facade.clamshellCausesSleep != false {
                return completeDisarming()
            }
            if elapsed >= StateMachine.verifyDeadline {
                audit.note(.releaseNoEffect, at: facade.now, context: ["phase": "verify"])
                state = .failed
                phaseStartedAt = nil
                return [.stopTimer(.verify), .endActivity, .chime(.failure), .notify(.releaseFailed)]
            }
            return []

        default:
            return [.stopTimer(.verify)]
        }
    }

    func completeArming() -> [LidwingEffect] {
        state = .armed
        phaseStartedAt = nil
        lastGroundTruthVerifiedAt = facade.now
        watchdog.send(.armed(bootSession: facade.bootSessionUUID, pid: pid))

        var effects: [LidwingEffect] = [
            .stopTimer(.verify),
            .startTimer(.reassert),
            .startTimer(.reconcile)
        ]
        // This arm verified against ground truth, so the mechanism demonstrably still works on
        // the build running right now. That is the only moment at which the OS is worth
        // recording, and the only moment at which "it still works" is a fact rather than a hope.
        if lastVerifiedOS != identity.osVersion {
            effects.append(.recordVerifiedOS(identity.osVersion))
            lastVerifiedOS = identity.osVersion
        }
        if let recheck = pendingOSRecheck {
            pendingOSRecheck = nil
            effects.append(.notify(.recheckedAfterOSUpdate(from: recheck.from, to: recheck.to)))
        }

        // No chime here. The user is looking at the menu they just clicked.
        if !hasEverArmed {
            hasEverArmed = true
            effects.append(.notify(.firstArm))
        }
        return effects
    }

    func completeDisarming() -> [LidwingEffect] {
        let reason = pendingDisarmReason ?? .user
        finishSession(reason: reason)
        ledgerStore.delete()
        watchdog.send(.disarmed)
        watchdog.disconnect()
        state = .idle
        phaseStartedAt = nil
        pendingDisarmReason = nil
        lastGroundTruthVerifiedAt = nil

        var effects: [LidwingEffect] = [.stopTimer(.verify), .endActivity]
        if lidWasClosed {
            // The screen is not an output channel right now, so this is the one confirmation
            // the user can actually receive: the Mac is about to sleep normally.
            effects.append(.chime(.standingDown))
        }
        if reason.userFacingSentence != nil {
            effects.append(.notify(.autoDisarmed(reason)))
        }
        return effects
    }

    // MARK: Re-assertion

    func onReassertTrigger(lidJustClosed: Bool = false) -> [LidwingEffect] {
        guard state.isProtecting else { return [] }
        // Idempotent by construction: the kernel term is a bit mask, and re-setting a set bit
        // is a no-op that also re-runs the clamshell evaluation, which refreshes the property
        // we verify against.
        if case .success = facade.setClamshellSleepDisabled(true) {
            session?.countReassert()
        }
        if !facade.ourAssertionLive {
            _ = facade.setIdleAssertion(true)
        }
        watchdog.send(.heartbeat(at: facade.now))
        // The defining moment of this product: the lid just shut and the Mac is still running.
        // The user cannot see anything, so say it out loud.
        return lidJustClosed ? [.chime(.sealed)] : []
    }

    // MARK: Reconciliation while armed

    func onReconcile() -> [LidwingEffect] {
        guard state.isProtecting else { return [] }
        guard let armedSince = session?.armedAt else { return [] }

        let power = currentPowerSample()
        session?.observe(batteryPercent: power.percentage)
        session?.observe(thermal: facade.thermalState)

        // Ground truth first. A machine that is no longer protected is not "degraded", it has
        // failed, and the user must be told rather than shown a confident green icon.
        switch checkGroundTruth() {
        case .lost(let effects):
            return effects
        case .retrying, .fine:
            break
        }

        if !facade.ourAssertionLive {
            _ = facade.setIdleAssertion(true)
        }

        // Auto mode: the natural end of a session is the agent exiting.
        if mode == .auto, let gone = agentGoneSince,
           facade.now.timeIntervalSince(gone) >= agentGracePeriod,
           facade.runningAgentBinaries.isEmpty {
            return beginDisarm(.agentExited)
        }

        let verdict = policy.evaluate(power: power,
                                      thermal: facade.thermalState,
                                      armedSince: armedSince,
                                      now: facade.now)
        switch verdict {
        case .disarm(let reason):
            return beginDisarm(reason)

        case .degrade(let warning):
            state = .degraded
            return warnOnce(warning)

        case .ok:
            if !facade.foreignAssertionHolders.isEmpty {
                state = .degraded
                return warnOnce(.foreignHolder)
            }
            state = .armed
            return []
        }
    }

    enum GroundTruthCheck {
        case fine
        case retrying
        case lost([LidwingEffect])
    }

    /// One mismatch buys one immediate re-write. A second, `verifyDeadline` later, is a
    /// failure: something on this machine is undoing us and the user needs to know.
    func checkGroundTruth() -> GroundTruthCheck {
        guard facade.clamshellCausesSleep == true else {
            if facade.clamshellCausesSleep == false {
                groundTruthMismatchSince = nil
                lastGroundTruthVerifiedAt = facade.now
            }
            return .fine
        }
        guard let mismatchSince = groundTruthMismatchSince else {
            groundTruthMismatchSince = facade.now
            _ = facade.setClamshellSleepDisabled(true)
            session?.countReassert()
            return .retrying
        }
        guard facade.now.timeIntervalSince(mismatchSince) >= StateMachine.verifyDeadline else {
            return .retrying
        }
        session?.record(.groundTruthLost)
        audit.note(.groundTruthLost, at: facade.now, context: [:])
        state = .failed
        groundTruthMismatchSince = nil
        return .lost([.stopTimer(.reassert), .stopTimer(.reconcile), .chime(.failure),
                      .notify(.groundTruthLost)])
    }

    /// Each warning reaches the user once per armed session. Repeating it every five seconds
    /// is how a product teaches people to ignore it.
    func warnOnce(_ warning: SafetyWarning) -> [LidwingEffect] {
        guard warnedThisSession.insert(warning).inserted else { return [] }
        return [.notify(.degraded(warning))]
    }

    // MARK: Sleep observation — invariant I5

    func onSystemWillSleep(_ argument: UInt) -> [LidwingEffect] {
        // Acknowledge first and do no work: the decision is irrevocable, and disk or network
        // access here blocks the whole machine.
        var effects: [LidwingEffect] = [.allowPowerChange(argument)]
        guard state.isProtecting else { return effects }

        let at = facade.now
        session?.record(.sleptWhileArmed)
        audit.note(.sleptWhileArmed, at: at, context: [
            "lid": facade.lidState.rawValue,
            "onAC": String(facade.onAC),
            "displays": String(facade.onlineDisplayCount),
            "thermal": String(describing: facade.thermalState)
        ])
        state = .failed
        effects.append(contentsOf: [.stopTimer(.reassert), .stopTimer(.reconcile),
                                    .notify(.sleptWhileArmed(at: at))])
        return effects
    }

    func onSystemHasPoweredOn() -> [LidwingEffect] {
        switch state {
        case .failed where session != nil:
            // We were protecting when the machine slept. Re-arm immediately rather than
            // leaving an eight-hour run unprotected for the rest of the night.
            return reArmAfterFailure()
        case .armed, .degraded:
            return onReassertTrigger()
        default:
            return []
        }
    }

    func reArmAfterFailure() -> [LidwingEffect] {
        guard watchdog.isConnected || watchdog.connect() else {
            return finishFailedSession(reason: .watchdogLost)
        }
        if case .failure = facade.setClamshellSleepDisabled(true) {
            return finishFailedSession(reason: .unsupportedState)
        }
        weSetTheBit = true
        if case .failure = facade.setIdleAssertion(true) {
            return finishFailedSession(reason: .unsupportedState)
        }
        idleAssertionHeld = true
        state = .arming
        phaseStartedAt = facade.now
        return [.startTimer(.verify)]
    }

    /// The machine slept, and the attempt to protect it again did not work either. This is the
    /// end of the session, and the user has to be told: they went to sleep expecting an
    /// eight-hour run and it is over. Standing down silently here would be the quietest
    /// possible way to lose somebody's night of work.
    func finishFailedSession(reason: DisarmReason) -> [LidwingEffect] {
        releaseMechanism()
        watchdog.send(.disarmed)
        watchdog.disconnect()
        ledgerStore.delete()
        finishSession(reason: reason)
        state = .idle
        var effects: [LidwingEffect] = [.stopTimer(.reassert), .stopTimer(.reconcile),
                                        .endActivity, .chime(.failure)]
        if reason.userFacingSentence != nil {
            effects.append(.notify(.autoDisarmed(reason)))
        }
        return effects
    }

    // MARK: Watchdog

    func onWatchdogLost() -> [LidwingEffect] {
        guard state.isProtecting || state == .arming else { return [] }
        if watchdog.connect() { return [] }
        // Invariant I2: no dead-man, no bit. Standing down is the safe direction.
        audit.note(.watchdogUnavailable, at: facade.now, context: ["phase": state.rawValue])
        return beginDisarm(.watchdogLost)
    }

    // MARK: Disarming

    func beginDisarm(_ reason: DisarmReason) -> [LidwingEffect] {
        guard state.isProtecting || state == .arming else { return [] }
        pendingDisarmReason = reason
        releaseMechanism()
        state = .disarming
        phaseStartedAt = facade.now
        return [.stopTimer(.reassert), .stopTimer(.reconcile), .startTimer(.verify)]
    }

    /// Runs the whole disarm synchronously, because the process is about to stop existing and
    /// there will be no run loop left to deliver a verify tick.
    func terminateNow() -> [LidwingEffect] {
        let reason: DisarmReason = pendingDisarmReason ?? .quit
        releaseMechanism()
        finishSession(reason: reason)
        ledgerStore.delete()
        watchdog.send(.disarmed)
        watchdog.disconnect()
        state = .idle
        phaseStartedAt = nil
        pendingDisarmReason = nil
        return [.stopTimer(.reassert), .stopTimer(.reconcile), .stopTimer(.verify), .endActivity]
    }

    /// Invariant I7. Bit 0x02 of `clamshellSleepDisableMask` is shared with powerd and has no
    /// reference count, so clearing it in a configuration where powerd legitimately wants it
    /// set would sleep somebody else's lid-closed machine mid-operation.
    func releaseMechanism() {
        if idleAssertionHeld {
            _ = facade.setIdleAssertion(false)
            idleAssertionHeld = false
        }
        guard weSetTheBit else { return }
        if facade.desktopMode && facade.onAC {
            weSetTheBit = false
            return
        }
        _ = facade.setClamshellSleepDisabled(false)
        weSetTheBit = false
    }

    func finishSession(reason: DisarmReason) {
        guard let session else { return }
        let record = session.finish(at: facade.now,
                                    reason: reason,
                                    tier: 1,
                                    sleepCountDelta: nil,
                                    darkWakeCountDelta: nil,
                                    os: identity.osVersion,
                                    arch: identity.arch,
                                    appVersion: identity.appVersion)
        audit.append(record)
        lastDisarmReason = reason
        self.session = nil
        warnedThisSession = []
        agentGoneSince = nil
    }

    func currentPowerSample() -> PowerSample {
        PowerSample(onAC: facade.onAC,
                    current: facade.batteryCurrent,
                    max: facade.batteryMax,
                    warning: facade.batteryWarningLevel)
    }

    // MARK: Invariants

    /// I3 and I1, checked on every transition. In debug these are hard preconditions; in
    /// release they become an audited record, because a violated invariant here means the
    /// machine may be unable to sleep and the user must find out.
    func assertInvariants() {
        let quiescent = !(state.isProtecting || state == .arming || state == .disarming
                          || state == .failed || state == .repair)
        if quiescent && (weSetTheBit || idleAssertionHeld) {
            audit.note(.groundTruthLost, at: facade.now,
                       context: ["invariant": "I3", "state": state.rawValue])
            assertionFailure("I3 violated: quiescent in \(state) while still holding the mechanism")
        }
        if state.isProtecting, let verified = lastGroundTruthVerifiedAt,
           facade.now.timeIntervalSince(verified) > StateMachine.groundTruthMaxAge * 4 {
            // Deliberately generous: the reconcile tick refreshes this every five seconds, so
            // four times the budget means the run loop itself has stopped.
            let age = String(Int(facade.now.timeIntervalSince(verified)))
            audit.note(.groundTruthLost, at: facade.now,
                       context: ["invariant": "I1", "age": age])
        }
    }
}
