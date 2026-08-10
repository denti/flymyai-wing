import AppKit
import LidwingCore
import LidwingSystem

/// A real window, not a popover and not a panel.
///
/// The safety defaults are the trust screen — the place a user decides whether this app is
/// careful — and they need room and a title, not a transient surface that vanishes when the
/// mouse moves.
final class SettingsWindowController: NSWindowController {

    private let coordinator: AppCoordinator
    // Built in `buildContent`, which the initialiser calls before it returns. Non-optional
    // because a settings window with no controls is not a state this class can be in.
    private let floorPopUp = NSPopUpButton()
    private let durationPopUp = NSPopUpButton()
    private let thermalCheckbox = NSButton(checkboxWithTitle: Strings.text("settings.thermal",
                                                                    "Stop if the Mac gets too hot"),
                                           target: nil, action: nil)
    private let soundCheckbox = NSButton(checkboxWithTitle: Strings.text("settings.sound.lidClose",
                                                                  "Play a sound when the lid closes"),
                                         target: nil, action: nil)

    private let modeControl = NSSegmentedControl(labels: [Strings.text("settings.mode.manual", "Manual"),
                                                          Strings.text("settings.mode.auto", "Auto")],
                                                 trackingMode: .selectOne,
                                                 target: nil, action: nil)

    private let floorChoices = [10, 15, 20, 30, 50]
    /// nil is "no limit", and it sits last behind a confirmation.
    private let durationChoices: [Int?] = [3600, 2 * 3600, 4 * 3600, 8 * 3600, 12 * 3600,
                                           24 * 3600, nil]

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = Strings.text("settings.title", "Lidwing Settings")
        super.init(window: window)
        window.setFrameAutosaveName("LidwingSettings")
        // A settings window that can be zoomed or minimised out of reach helps nobody, but the
        // Window menu still needs the items to exist for Full Keyboard Access.
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Lidwing builds its settings window in code")
    }

    func show() {
        // Without this the window opens *behind* the user's editor with no way to reach it.
        // This is the single most common mistake an accessory app makes.
        NSApp.activate(ignoringOtherApps: true)
        reload()
        if window?.frameAutosaveName.isEmpty ?? true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Open with focus on the first control rather than on nothing. Without this, a Full
        // Keyboard Access user presses Tab and focus appears somewhere unpredictable, and
        // VoiceOver announces the window title and then falls silent.
        window?.initialFirstResponder = modeControl
        window?.makeFirstResponder(modeControl)
    }

    // MARK: content

    private func buildContent() {
        guard let window else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionHeader(Strings.text("settings.when",
                                                            "When to keep this Mac awake")))
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        stack.addArrangedSubview(withExplanation(
            modeControl,
            Strings.text("settings.mode.detail",
                         "Auto turns Lidwing on by itself while claude, codex or cursor-agent "
                         + "is running, and off again a few minutes after the last one exits.")))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionHeader(Strings.text("settings.limits",
                                                            "It stops on its own")))

        for choice in floorChoices { floorPopUp.addItem(withTitle: "\(choice)%") }
        floorPopUp.target = self
        floorPopUp.action = #selector(settingsChanged)
        stack.addArrangedSubview(row(
            label: Strings.text("settings.floor", "Stop when the battery reaches"),
            control: floorPopUp,
            explanation: Strings.text("settings.floor.detail",
                                      "Your Mac goes to sleep instead of running the battery flat.")))

        for choice in durationChoices {
            durationPopUp.addItem(withTitle: choice.map {
                Strings.text("settings.duration.hours", "%1$lld hours", Int64($0 / 3600))
            } ?? Strings.text("settings.duration.none", "No limit"))
        }
        durationPopUp.target = self
        durationPopUp.action = #selector(settingsChanged)
        stack.addArrangedSubview(row(
            label: Strings.text("settings.duration", "Stop after"),
            control: durationPopUp,
            explanation: Strings.text("settings.duration.detail",
                                      "Lidwing turns itself off after this long, "
                                      + "even if you forget.")))

        thermalCheckbox.target = self
        thermalCheckbox.action = #selector(settingsChanged)
        stack.addArrangedSubview(withExplanation(
            thermalCheckbox,
            Strings.text("settings.thermal.detail",
                         "A closed lid blocks airflow. Lidwing stops before your Mac overheats.")))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionHeader(Strings.text("settings.sound", "Sound")))

        soundCheckbox.target = self
        soundCheckbox.action = #selector(settingsChanged)
        stack.addArrangedSubview(withExplanation(
            soundCheckbox,
            Strings.text("settings.sound.detail",
                         "You can't see the screen with the lid closed, "
                         + "so Lidwing says it out loud.")))

        stack.addArrangedSubview(separator())
        for view in agentsSection() { stack.addArrangedSubview(view) }
        stack.addArrangedSubview(separator())

        let warning = NSTextField(labelWithString: Strings.text(
            "settings.bagWarning",
            "\u{26A0}\u{FE0E} Don't put your Mac in a bag while Lidwing is on."))
        warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warning.textColor = .secondaryLabelColor
        stack.addArrangedSubview(warning)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])
        window.contentView = content
    }

    /// Every integration is off by default, and the only button that writes anything is
    /// labelled with what it will show you first.
    private func agentsSection() -> [NSView] {
        var views: [NSView] = [sectionHeader(Strings.text("settings.agents", "Coding agents"))]

        let note = NSTextField(labelWithString: Strings.text(
            "settings.agents.detail",
            "Lidwing can make a sound when your agent is waiting for you, so you hear it with "
            + "the lid closed. It shows you every line before it writes one."))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 480
        views.append(note)

        for agent in IntegrationInstaller.Agent.allCases {
            let present = IntegrationInstaller.isPresent(agent)
            let label = NSTextField(labelWithString: present
                ? Strings.text("settings.agents.found", "%1$@ - found at ~/%2$@",
                               agent.displayName, agent.relativePath)
                : Strings.text("settings.agents.missing", "%1$@ - not installed",
                               agent.displayName))
            let add = NSButton(title: Strings.text("settings.agents.show",
                                                   "Show What Will Be Written\u{2026}"),
                               target: self, action: #selector(addIntegration(_:)))
            add.identifier = NSUserInterfaceItemIdentifier(agent.rawValue)
            add.isEnabled = present
            let remove = NSButton(title: Strings.text("settings.agents.remove", "Remove"),
                                  target: self, action: #selector(removeIntegration(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(agent.rawValue)
            remove.isEnabled = present
            let row = NSStackView(views: [label, add, remove])
            row.orientation = .horizontal
            row.spacing = 8
            views.append(row)
        }
        return views
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        // VoiceOver announces the context rather than reading five controls with no grouping.
        field.setAccessibilityRole(.staticText)
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// Label, control, and a one-line explanation underneath in secondary colour. Every row in
    /// this window has all three; a checkbox whose consequence is not stated is a checkbox
    /// nobody can make an informed decision about.
    private func row(label: String, control: NSView, explanation: String) -> NSView {
        let title = NSTextField(labelWithString: label)
        // The visible label is a separate text field, so a pop-up reached by Tab or by VoiceOver
        // announces only its own value - "20 per cent" with no hint of what it governs. The
        // label has to be on the control itself.
        control.setAccessibilityLabel(label)
        // Attach the explanation to the control before wrapping it. This used to wrap first and
        // attach afterwards, and the attachment was guarded on `as? NSButton`, so a row built
        // this way handed a stack view to that cast, the cast failed, and the row silently had
        // no help text and no tooltip at all. The two rows built this way are the battery floor
        // and the duration limit - the two settings that decide when this Mac is allowed to
        // stop. Nothing was red; the accommodation was simply absent.
        attachExplanation(explanation, to: control)
        let line = NSStackView(views: [title, control])
        line.orientation = .horizontal
        line.spacing = 8
        return withExplanation(line, explanation)
    }

    /// Puts an explanation where both a pointer and VoiceOver can reach it.
    private func attachExplanation(_ explanation: String, to view: NSView) {
        // Any control, not only a button: pop-ups and sliders need this at least as much.
        guard let control = view as? NSControl else { return }
        control.toolTip = explanation
        control.setAccessibilityHelp(explanation)
    }

    private func withExplanation(_ view: NSView, _ explanation: String) -> NSView {
        let note = NSTextField(labelWithString: explanation)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 400
        attachExplanation(explanation, to: view)
        let stack = NSStackView(views: [view, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    // MARK: state

    /// Rendered from the live settings every time the window appears, never from a cached
    /// bool: the value can change while this window is closed.
    private func reload() {
        let settings = coordinator.machine.settings

        // A stored value that is not one of the offered choices must still be *shown*. Falling
        // back to a default here would display a number the app is not using, and the next
        // change the user made would silently overwrite their real setting with it.
        if let index = floorChoices.firstIndex(of: settings.batteryFloorPercent) {
            floorPopUp.selectItem(at: index)
        } else {
            let title = Strings.text("settings.floor.custom", "%1$lld%% (custom)",
                                     Int64(settings.batteryFloorPercent))
            if floorPopUp.item(withTitle: title) == nil { floorPopUp.addItem(withTitle: title) }
            floorPopUp.selectItem(withTitle: title)
        }

        if let index = durationChoices.firstIndex(where: { $0 == settings.maxDurationSeconds }) {
            durationPopUp.selectItem(at: index)
        } else if let seconds = settings.maxDurationSeconds {
            let title = Strings.text("settings.duration.custom", "%1$lld hours (custom)",
                                     Int64(seconds / 3600))
            if durationPopUp.item(withTitle: title) == nil {
                durationPopUp.addItem(withTitle: title)
            }
            durationPopUp.selectItem(withTitle: title)
        }
        modeControl.selectedSegment = coordinator.machine.mode == .auto ? 1 : 0
        thermalCheckbox.state = settings.thermalGuardEnabled ? .on : .off
        soundCheckbox.state = Preferences.shared.soundEnabled ? .on : .off
    }

    @objc private func modeChanged() {
        coordinator.setMode(modeControl.selectedSegment == 1 ? .auto : .manual)
    }

    @objc private func addIntegration(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let agent = IntegrationInstaller.Agent(rawValue: raw) else { return }
        IntegrationsPanel.offerInstall(agent)
    }

    @objc private func removeIntegration(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let agent = IntegrationInstaller.Agent(rawValue: raw) else { return }
        IntegrationsPanel.remove(agent)
    }

    @objc private func settingsChanged() {
        // A custom entry appended by `reload` sits past the end of the fixed list; selecting
        // it means "keep what is already stored" rather than reading past the array.
        let durationIndex = durationPopUp.indexOfSelectedItem
        var duration = durationIndex >= 0 && durationIndex < durationChoices.count
            ? durationChoices[durationIndex]
            : coordinator.machine.settings.maxDurationSeconds

        // "No limit" is the one choice that removes a safety net, so it is the one choice that
        // asks. Declining puts the control back rather than silently ignoring the click.
        if duration == nil && coordinator.machine.settings.maxDurationSeconds != nil {
            let alert = NSAlert()
            alert.messageText = Strings.text("settings.noLimit.title", "Run with no time limit?")
            alert.informativeText = Strings.text(
                "settings.noLimit.body",
                "The battery and heat limits still apply, so Lidwing will still stop before "
                + "your Mac runs flat or gets too hot. But it will not stop just because time "
                + "passed, and a forgotten Lidwing is how a laptop ends up warm in a bag.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: Strings.text("button.cancel", "Cancel"))
            alert.addButton(withTitle: Strings.text("settings.noLimit.confirm",
                                                    "Remove the Time Limit"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertSecondButtonReturn {
                duration = coordinator.machine.settings.maxDurationSeconds
                reload()
                return
            }
        }

        let floorIndex = floorPopUp.indexOfSelectedItem
        let floor = floorIndex >= 0 && floorIndex < floorChoices.count
            ? floorChoices[floorIndex]
            : coordinator.machine.settings.batteryFloorPercent

        coordinator.setSafetySettings(SafetySettings(
            batteryFloorPercent: floor,
            maxDurationSeconds: duration,
            thermalGuardEnabled: thermalCheckbox.state == .on))
        Preferences.shared.soundEnabled = (soundCheckbox.state == .on)
        coordinator.soundEnabledChanged()
        reload()
    }
}
