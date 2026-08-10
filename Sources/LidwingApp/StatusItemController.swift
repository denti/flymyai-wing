import AppKit
import LidwingCore
import LidwingSystem

/// The entire visible surface of this product: one glyph and one menu.
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let coordinator: AppCoordinator
    private lazy var settingsWindow = SettingsWindowController(coordinator: coordinator)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        // `squareLength`, so the item never jitters width as the state changes.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // NEVER change this string. Bartender and Ice key their saved arrangements on
        // (bundle id, status item window title), and the window title *is* the autosave name.
        // Changing it silently destroys every user's menu-bar layout.
        statusItem.autosaveName = "Lidwing"
        // Not `.removalAllowed`: Apple's rule is that removal is appropriate only if the app
        // remains usable without the item. This app has no other UI, and an invisible process
        // holding a power override with no way to reach it is a trust catastrophe. The Dock
        // menu is the escape hatch instead.
        statusItem.behavior = []

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        statusItem.button?.setAccessibilityLabel("Lidwing")

        // Once, ever, and 400 ms after the item exists so it does not race the menu bar's own
        // layout. Nothing else happens at launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            FirstRun.showLocationCallout(near: self?.statusItem.button)
        }
    }

    // MARK: appearance

    func refresh() {
        let snapshot = coordinator.snapshot()
        let content = MenuPresenter.content(for: snapshot)
        guard let button = statusItem.button else { return }

        // Read the thickness; never hardcode 22 or 24. Three different numbers exist on one
        // machine: the drawable status item, the menu-bar band, and the notch safe area.
        let shape = StatusIcon.shape(for: snapshot.state)
        button.image = StatusIcon.image(for: shape, thickness: NSStatusBar.system.thickness)

        // Under Increase Contrast a dimmed thin outline is the first cue to vanish, so the OFF
        // state carries itself at full opacity instead.
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        button.appearsDisabled = (shape == .unsupported) && !increaseContrast

        button.toolTip = content.headline
        button.setAccessibilityValue(content.accessibilityValue)
        // Without this the value is readable if a VoiceOver user happens to navigate there,
        // but never announced — which defeats the point for an app whose state changes while
        // the user is somewhere else entirely.
        NSAccessibility.post(element: button, notification: .valueChanged)
    }

    func flash() {
        guard let button = statusItem.button else { return }
        var count = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler {
            button.highlight(count % 2 == 0)
            count += 1
            if count >= 6 {
                button.highlight(false)
                timer.cancel()
            }
        }
        timer.resume()
    }

    // MARK: menu

    /// Rebuilt on every open, so what the user reads is the truth at the instant they looked,
    /// not a value a background timer cached. Zero work happens while the menu is closed.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in buildItems() { menu.addItem(item) }
        // The user is looking, so "your agent is waiting" stops being news.
        coordinator.acknowledgeAgentWaiting()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in buildItems() { menu.addItem(item) }
        return menu
    }

    private func buildItems() -> [NSMenuItem] {
        let snapshot = coordinator.snapshot()
        let content = MenuPresenter.content(for: snapshot)
        var items: [NSMenuItem] = []

        if let waiting = coordinator.agentIsWaiting {
            let name = waiting.source == "hook"
                ? Strings.text("agent.generic", "Your coding agent") : waiting.source
            items.append(disabled(Strings.text("menu.agentWaiting", "%1$@ is waiting for you",
                                               name), secondary: false))
            items.append(.separator())
        }
        items.append(disabled(content.headline, secondary: false))
        if let detail = content.detail {
            items.append(disabled(detail, secondary: true))
        }
        items.append(.separator())

        if snapshot.state == .repair {
            let repair = NSMenuItem(title: Strings.text("menu.repair.action", "Repair Now\u{2026}"),
                                    action: #selector(repairNow), keyEquivalent: "")
            repair.target = self
            items.append(repair)
            items.append(.separator())
        }

        let toggle = NSMenuItem(title: content.toggleTitle,
                                action: #selector(toggleProtection), keyEquivalent: "k")
        toggle.target = self
        toggle.state = content.toggleChecked ? .on : .off
        // Disabled, never hidden: a row that disappears leaves the user wondering what they
        // did wrong.
        toggle.isEnabled = content.toggleEnabled
        items.append(toggle)
        items.append(.separator())

        let sleepNow = NSMenuItem(title: Strings.text("menu.sleepNow", "Sleep Now"),
                                  action: #selector(sleepNow), keyEquivalent: "")
        sleepNow.target = self
        items.append(sleepNow)

        let settings = NSMenuItem(title: Strings.text("menu.settings", "Settings\u{2026}"),
                                  action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        items.append(settings)

        let diagnostics = NSMenuItem(title: Strings.text("menu.diagnostics", "Copy Diagnostics"),
                                     action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        items.append(diagnostics)
        items.append(.separator())

        let uninstall = NSMenuItem(title: Strings.text("menu.uninstall", "Uninstall Lidwing\u{2026}"),
                                   action: #selector(uninstall), keyEquivalent: "")
        uninstall.target = self
        items.append(uninstall)

        let about = NSMenuItem(title: Strings.text("menu.about", "About Lidwing"),
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        items.append(about)

        let quit = NSMenuItem(title: Strings.text("menu.quit", "Quit Lidwing"),
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        items.append(quit)

        return items
    }

    /// A disabled item with an attributed title, not a custom view. Custom views silently kill
    /// arrow-key navigation, type-select, Full Keyboard Access and VoiceOver.
    private func disabled(_ text: String, secondary: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        item.attributedTitle = NSAttributedString(string: text, attributes: attributes)
        return item
    }

    // MARK: actions

    @objc private func toggleProtection() {
        // The explainer appears here and nowhere else: on the user's first deliberate click,
        // never at launch, never on a timer, never from an automation path.
        if !coordinator.machine.state.isProtecting {
            FirstRun.showExplainerIfNeeded(settings: coordinator.machine.settings)
        }
        let wasProtecting = coordinator.machine.state.isProtecting
        coordinator.toggle()
        if !wasProtecting && coordinator.machine.state == .arming {
            // Give the verification its window, then show the machine's own answer once ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.coordinator.machine.state.isProtecting,
                      FirstRun.shouldShowProof else { return }
                FirstRun.showProof()
            }
        }
    }

    @objc private func repairNow() {
        coordinator.repairNow()
    }

    @objc private func sleepNow() {
        coordinator.sleepNow()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func copyDiagnostics() {
        let text = coordinator.diagnosticsText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Diagnostics copied"
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// An app that can stop a Mac from sleeping and cannot remove itself is, definitionally,
    /// indistinguishable from malware. The removal path is in the menu, not in a document.
    @objc private func uninstall() {
        let confirm = NSAlert()
        confirm.messageText = "Remove Lidwing from this Mac?"
        confirm.informativeText = Uninstaller.confirmationText()
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Remove Lidwing")
        confirm.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let outcome = Uninstaller.run(coordinator: coordinator)
        let report = NSAlert()
        report.messageText = outcome.succeeded ? "Lidwing removed" : "Lidwing was not fully removed"
        report.informativeText = outcome.lines.joined(separator: "\n")
            + (outcome.succeeded
               ? "\n\nDrag Lidwing to the Trash to finish."
               : "\n\nIf your Mac still will not sleep when you close the lid, restarting it "
                 + "clears the setting: Lidwing never writes anything that survives a restart.")
        report.alertStyle = outcome.succeeded ? .informational : .critical
        report.addButton(withTitle: "OK")
        report.runModal()
        if outcome.succeeded { NSApp.terminate(nil) }
    }

    @objc private func showAbout() {
        // An accessory app that forgets to activate opens its window behind the user's editor,
        // with no way to reach it. This is the single most common LSUIElement bug.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [:])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
