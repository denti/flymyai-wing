import AppKit
import LidwingCore

/// First launch, and the screen before the first arm.
///
/// `applicationDidFinishLaunching` shows **nothing**: no dialog, no window, no notification, no
/// sound, no permission request, no login-item registration. The only thing that happens is a
/// small pointer at the status item, once ever, because a Dock-less app whose entire UI is one
/// glyph owes its user an arrow at it.
enum FirstRun {

    private static let explainerShownKey = "LidwingDidShowExplainer"

    // The location callout - a borderless popover pointing at the menu bar on first launch -
    // was deleted here. It said "look for the wing", which is true and changes nothing anybody
    // does: they have just installed a menu-bar app and are already looking at the menu bar.
    // The rule it failed: what does the user do differently because of this? Nothing.

    // MARK: the explainer

    static var shouldShowExplainer: Bool {
        !UserDefaults.standard.bool(forKey: explainerShownKey)
    }

    /// Shown on the user's first deliberate click on the toggle, never at launch and never on a
    /// timer. Returns true when the user chose to continue.
    ///
    /// Exactly one action button. A pre-permission screen with a second styled button competing
    /// with it is coercive, and it is an App Store rejection pattern even for apps that never
    /// go near the store.
    @discardableResult
    static func showExplainerIfNeeded(settings: SafetySettings) -> Bool {
        guard shouldShowExplainer else { return true }

        let alert = NSAlert()
        alert.messageText = FirstRunCopy.Explainer.title
        alert.alertStyle = .informational

        var body = [FirstRunCopy.Explainer.promise, ""]
        body.append(contentsOf: FirstRunCopy.Explainer.limitations.map { "\u{2022} \($0)" })
        body.append("")
        body.append(FirstRunCopy.Explainer.permissions)
        body.append("")
        body.append(FirstRunCopy.Explainer.safetyHeadline + ":")
        let hours = (settings.maxDurationSeconds ?? 0) / 3600
        body.append(contentsOf: FirstRunCopy.Explainer
            .safetyDefaults(floorPercent: settings.batteryFloorPercent, hours: hours)
            .map { "\u{2022} \($0)" })
        alert.informativeText = body.joined(separator: "\n")

        alert.addButton(withTitle: FirstRunCopy.Explainer.confirm)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        UserDefaults.standard.set(true, forKey: explainerShownKey)
        return true
    }

    // MARK: proof

    private static let proofShownKey = "LidwingDidShowProof"

    static var shouldShowProof: Bool {
        !UserDefaults.standard.bool(forKey: proofShownKey)
    }

    /// The machine, quoted back to the user, once. A non-technical person needs to see this
    /// prove itself a single time; after that the menu carries the state.
    static func showProof() {
        UserDefaults.standard.set(true, forKey: proofShownKey)
        let alert = NSAlert()
        alert.messageText = FirstRunCopy.Proof.title
        alert.informativeText = FirstRunCopy.Proof.body + "\n\nCheck it yourself:\n"
            + FirstRunCopy.Proof.command
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func label(_ text: String, font: NSFont, colour: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = colour
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 3
        field.preferredMaxLayoutWidth = 248
        return field
    }
}
