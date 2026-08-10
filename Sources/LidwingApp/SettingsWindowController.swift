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
    private let thermalCheckbox = NSButton(checkboxWithTitle: "Stop if the Mac gets too hot",
                                           target: nil, action: nil)
    private let soundCheckbox = NSButton(checkboxWithTitle: "Play a sound when the lid closes",
                                         target: nil, action: nil)

    private let floorChoices = [10, 15, 20, 30, 50]
    /// nil is "no limit", and it sits last behind a confirmation.
    private let durationChoices: [Int?] = [3600, 2 * 3600, 4 * 3600, 8 * 3600, 12 * 3600,
                                           24 * 3600, nil]

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Lidwing Settings"
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

        stack.addArrangedSubview(sectionHeader("It stops on its own"))

        for choice in floorChoices { floorPopUp.addItem(withTitle: "\(choice)%") }
        floorPopUp.target = self
        floorPopUp.action = #selector(settingsChanged)
        stack.addArrangedSubview(row(label: "Stop when the battery reaches",
                                     control: floorPopUp,
                                     explanation: "Your Mac goes to sleep instead of running "
                                                + "the battery flat."))

        for choice in durationChoices {
            durationPopUp.addItem(withTitle: choice.map { "\($0 / 3600) hours" } ?? "No limit")
        }
        durationPopUp.target = self
        durationPopUp.action = #selector(settingsChanged)
        stack.addArrangedSubview(row(label: "Stop after",
                                     control: durationPopUp,
                                     explanation: "Lidwing turns itself off after this long, "
                                                + "even if you forget."))

        thermalCheckbox.target = self
        thermalCheckbox.action = #selector(settingsChanged)
        stack.addArrangedSubview(withExplanation(
            thermalCheckbox,
            "A closed lid blocks airflow. Lidwing stops before your Mac overheats."))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionHeader("Sound"))

        soundCheckbox.target = self
        soundCheckbox.action = #selector(settingsChanged)
        stack.addArrangedSubview(withExplanation(
            soundCheckbox,
            "You can't see the screen with the lid closed, so Lidwing says it out loud."))

        stack.addArrangedSubview(separator())

        let warning = NSTextField(labelWithString:
            "\u{26A0}\u{FE0E} Don't put your Mac in a bag while Lidwing is on.")
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
        let line = NSStackView(views: [title, control])
        line.orientation = .horizontal
        line.spacing = 8
        return withExplanation(line, explanation)
    }

    private func withExplanation(_ view: NSView, _ explanation: String) -> NSView {
        let note = NSTextField(labelWithString: explanation)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.preferredMaxLayoutWidth = 400
        if let control = view as? NSButton {
            control.toolTip = explanation
            control.setAccessibilityHelp(explanation)
        }
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
        floorPopUp.selectItem(at: floorChoices.firstIndex(of: settings.batteryFloorPercent) ?? 2)
        let durationIndex = durationChoices.firstIndex { $0 == settings.maxDurationSeconds }
        durationPopUp.selectItem(at: durationIndex ?? 3)
        thermalCheckbox.state = settings.thermalGuardEnabled ? .on : .off
        soundCheckbox.state = Preferences.shared.soundEnabled ? .on : .off
    }

    @objc private func settingsChanged() {
        var duration = durationChoices[max(0, durationPopUp.indexOfSelectedItem)]

        // "No limit" is the one choice that removes a safety net, so it is the one choice that
        // asks. Declining puts the control back rather than silently ignoring the click.
        if duration == nil && coordinator.machine.settings.maxDurationSeconds != nil {
            let alert = NSAlert()
            alert.messageText = "Run with no time limit?"
            alert.informativeText =
                "The battery and heat limits still apply, so Lidwing will still stop before "
                + "your Mac runs flat or gets too hot. But it will not stop just because time "
                + "passed, and a forgotten Lidwing is how a laptop ends up warm in a bag."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Remove the Time Limit")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertSecondButtonReturn {
                duration = coordinator.machine.settings.maxDurationSeconds
                reload()
                return
            }
        }

        coordinator.setSafetySettings(SafetySettings(
            batteryFloorPercent: floorChoices[max(0, floorPopUp.indexOfSelectedItem)],
            maxDurationSeconds: duration,
            thermalGuardEnabled: thermalCheckbox.state == .on))
        Preferences.shared.soundEnabled = (soundCheckbox.state == .on)
        coordinator.soundEnabledChanged()
        reload()
    }
}
