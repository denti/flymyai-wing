import AppKit
import LidwingCore

/// First launch, and the screen before the first arm.
///
/// `applicationDidFinishLaunching` shows **nothing**: no dialog, no window, no notification, no
/// sound, no permission request, no login-item registration. The only thing that happens is a
/// small pointer at the status item, once ever, because a Dock-less app whose entire UI is one
/// glyph owes its user an arrow at it.
enum FirstRun {

    private static let calloutShownKey = "LidwingDidShowLocationCallout"
    private static let explainerShownKey = "LidwingDidShowExplainer"

    // MARK: the location callout

    static var shouldShowLocationCallout: Bool {
        !UserDefaults.standard.bool(forKey: calloutShownKey)
    }

    static func showLocationCallout(near button: NSStatusBarButton?) {
        guard shouldShowLocationCallout else { return }
        UserDefaults.standard.set(true, forKey: calloutShownKey)

        let width: CGFloat = 280
        let height: CGFloat = 108
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        let container = NSVisualEffectView(frame: window.contentLayoutRect)
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        // Reduce Transparency: an opaque background instead of a vibrant one.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            container.material = .windowBackground
        }

        let headline = label(FirstRunCopy.LocationCallout.headline,
                             font: .boldSystemFont(ofSize: NSFont.systemFontSize),
                             colour: .labelColor)
        let body = label(FirstRunCopy.LocationCallout.body,
                         font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                         colour: .secondaryLabelColor)
        let dismiss = NSButton(title: FirstRunCopy.LocationCallout.dismiss,
                               target: nil, action: nil)
        dismiss.bezelStyle = .rounded
        dismiss.target = window
        dismiss.action = #selector(NSWindow.close)

        let stack = NSStackView(views: [headline, body, dismiss])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.frame = container.bounds
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        window.contentView = container

        // Position under the status item, on the screen the menu bar is actually on. Never
        // `NSScreen.main`: the menu bar follows the active display, and on a two-display setup
        // the callout would appear next to nothing.
        if let button, let buttonWindow = button.window {
            let onScreen = buttonWindow.convertToScreen(button.bounds)
            let screen = buttonWindow.screen ?? NSScreen.screens.first
            var origin = NSPoint(x: onScreen.midX - width / 2, y: onScreen.minY - height - 6)
            if let visible = screen?.visibleFrame {
                origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
            }
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        // Without this it appears behind the user's editor, which is the single most common
        // mistake an accessory app makes.
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(
            deadline: .now() + FirstRunCopy.LocationCallout.autoDismissSeconds) { [weak window] in
                window?.close()
            }
    }

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
