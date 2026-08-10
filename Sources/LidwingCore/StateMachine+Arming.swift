import Foundation

// Turning the mechanism on: the one path in this product that mutates the machine.
//
// Split out of `StateMachine+Transitions.swift` when that file crossed its length budget. Same
// type, same invariants; these three functions belong together because they are the only ways
// Lidwing ever arms, and the difference between them is who asked.
extension StateMachine {

    func onUserArm() -> [LidwingEffect] {
        arm(prompt: .askNow)
    }

    /// Arming because Lidwing just started, not because anybody clicked.
    ///
    /// Decision 0012: install to value is zero steps. The only difference from a user asking is
    /// that nothing here may interrupt - a refusal at launch is shown in the menu, never in a
    /// dialog. That is not a detail: presenting a modal from the launch path is what crashed
    /// v0.1.0, and a refusal is the *likely* outcome on a Mac that already has another
    /// keep-awake tool on it.
    func onArmAtLaunch() -> [LidwingEffect] {
        guard state == .idle else { return [] }

        // A desktop at launch and a laptop whose lid driver has not reported yet look identical:
        // no `AppleClamshellState` key, which is `.unknown`. That is deliberately not collapsed
        // into `.noLid` - doing so would disable the product at every login on a real laptop -
        // so arming here would take a genuine idle-sleep assertion on a Mac mini and hold it
        // awake for the whole duration lease, for a feature it cannot use.
        //
        // Waiting costs nothing. The lid driver reports within moments on a laptop, and the
        // ten-second determination settles the desktop case.
        guard facade.lidState != .unknown else {
            deferredArmAtLaunch = true
            return []
        }
        return arm(prompt: .quietly)
    }

    private func arm(prompt: Prompt) -> [LidwingEffect] {
        switch state {
        case .idle:
            break
        case .failed:
            // A failed state can still be holding the mechanism and can still own an open
            // session record. Close both before starting a new one.
            if session != nil {
                releaseMechanism()
                finishSession(reason: .failure)
                watchdog.disconnect()
                ledgerStore.delete()
            }
        case .repair:
            return [.offerRepair(repairCause ?? .noLedger, prompt)]
        case .unsupported:
            return [.refuseArm(.unsupportedOS, prompt)]
        case .arming, .armed, .degraded, .disarming:
            return []
        }

        let power = currentPowerSample()
        if facade.onlineDisplayCount > 1 && power.onAC {
            // macOS already keeps a Mac awake with the lid closed when an external display is
            // attached on AC. Saying so costs a user and buys the credibility that carries the
            // other ninety-nine.
            return [.refuseArm(.externalDisplayOnAC, prompt)]
        }
        if let refusal = SafetyPolicy.refusalReason(power: power,
                                                    thermal: facade.thermalState,
                                                    settings: settings,
                                                    lid: facade.lidState,
                                                    foreignHolders: facade.foreignAssertionHolders) {
            return [.refuseArm(refusal, prompt)]
        }

        // The dead-man goes up first. We never hold the mechanism without one.
        guard watchdog.connect() else {
            audit.note(.watchdogUnavailable, at: facade.now, context: [:])
            return [.refuseArm(.watchdogUnavailable, prompt)]
        }

        // The ledger is written before the first mutation so a panic between them is
        // recoverable at next boot.
        let ledger = Ledger(bootSessionUUID: facade.bootSessionUUID,
                            capturedAt: facade.now,
                            weSetClamshellBit: true,
                            reason: "arming",
                            appVersion: identity.appVersion)
        do {
            try ledgerStore.write(ledger)
        } catch {
            // Not fatal — the watchdog covers process death and the mask clears on reboot —
            // but it is recorded, because it degrades our ability to explain ourselves later.
            audit.note(.ledgerWriteFailed, at: facade.now, context: ["error": "\(error)"])
        }

        if case .failure(let error) = facade.setClamshellSleepDisabled(true) {
            watchdog.disconnect()
            ledgerStore.delete()
            audit.note(.applyNoEffect, at: facade.now, context: ["mechanism": "clamshell"])
            state = .failed
            return [.chime(.failure), .notify(.armFailed(error))]
        }
        weSetTheBit = true

        if case .failure(let error) = facade.setIdleAssertion(true) {
            // Without the idle lease the machine still sleeps on the ordinary timer, so the
            // promise is not kept. Roll the whole thing back rather than half-arm.
            releaseMechanism()
            watchdog.disconnect()
            ledgerStore.delete()
            audit.note(.applyNoEffect, at: facade.now, context: ["mechanism": "assertion"])
            state = .failed
            return [.chime(.failure), .notify(.armFailed(error))]
        }
        idleAssertionHeld = true

        state = .arming
        phaseStartedAt = facade.now
        session = AuditSession(armedAt: facade.now)
        warnedThisSession = []
        groundTruthMismatchSince = nil
        pendingDisarmReason = nil

        var effects: [LidwingEffect] = [.beginActivity, .startTimer(.verify)]
        if !power.onAC, shouldShowBagWarning() {
            lastBagWarningAt = facade.now
            effects.append(.notify(.bagWarning))
        }
        return effects
    }
}
