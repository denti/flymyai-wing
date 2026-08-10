import Foundation

/// Every user-visible string, in one place. **This app is English, everywhere, permanently.**
///
/// It used to carry a Russian catalogue selected from `Locale.preferredLanguages`, and that
/// shipped: `Выключено` and `Не спать` are both in the v0.1.0 binary, so on a Russian-language
/// Mac the interface really was Russian. `MISSION.md` says English. The substitution hook has
/// been removed rather than merely left unset - a switch nothing sets today is a switch
/// somebody sets tomorrow.
///
/// Strings that come from **macOS** rather than from here - error descriptions, the buttons in
/// system-provided dialogs - still appear in the user's own language, and that is not something
/// this product controls. Where one is shown it is never glued into a sentence of ours; it
/// appears on its own, as a quoted value.
///
/// The key stays as the first argument even though nothing looks it up: it is what
/// `StringKey.all` is checked against, which keeps these two rules enforceable.
///
/// Two rules that outlive any particular translation:
///
/// * **Never concatenate a sentence from fragments.** `"Lidwing is " + state` produces
///   something no translator can fix and no screen reader reads naturally, and it forces UI
///   fragments where whole sentences belong. Interpolation uses positional specifiers so word
///   order can change.
/// * **Every key has a comment.** A translator seeing `"stop_at_percent"` with no context will
///   guess, and the guess will be wrong in the direction that matters — this app's strings are
///   mostly about safety limits.
///
/// The lookup falls back to the key's own English text when no catalogue is present, so the
/// product is fully functional before a single translation exists and a missing key is visible
/// rather than blank.
public enum Strings {

    public static func text(_ key: String, _ english: String) -> String {
        english
    }

    /// Positional interpolation, so a translation can reorder the arguments.
    public static func text(_ key: String, _ english: String, _ arguments: CVarArg...) -> String {
        String(format: english, arguments: arguments)
    }
}

/// One catalogue entry. A struct rather than a tuple so the comment field cannot be dropped
/// silently when somebody adds a key in a hurry.
public struct StringEntry: Equatable, Sendable {
    public let key: String
    public let english: String
    /// Context for a translator, who will never see the code around this string.
    public let comment: String

    public init(_ key: String, _ english: String, _ comment: String) {
        self.key = key
        self.english = english
        self.comment = comment
    }
}

/// The keys, gathered so a test can assert that none is missing, duplicated, or written in a
/// way that cannot be translated.
public enum StringKey {
    public static let all: [StringEntry] = [
        // Status-item tooltips. Shown on hover, before any click, so each says what will
        // happen rather than restating the state the glyph already carries. Verb first, no
        // ending period.
        StringEntry("tip.off", "Turn on to keep this Mac awake with the lid closed",
         "Tooltip on the menu bar icon while Lidwing is off. Verb first, no ending period."),
        StringEntry("tip.on", "Keeping this Mac awake with the lid closed",
         "Tooltip while protection is active. No ending period."),
        StringEntry("tip.agent", "Keeping this Mac awake - %1$@ is running",
         "%1$@ is a coding-agent binary name such as claude or codex. No ending period."),
        StringEntry("tip.degraded", "Keeping this Mac awake - click, a guard is warning",
         "Tooltip while still protecting but a battery or heat guard is warning."),
        StringEntry("tip.nolid", "Close the lid freely - this Mac has none to sleep on",
         "Tooltip on a Mac with no lid, such as a Mac mini or a Mac Studio."),
        StringEntry("tip.repair", "Click to release whatever is keeping this Mac awake",
         "Tooltip when a leftover sleep override was found at launch."),
        StringEntry("tip.failed", "Click for details - this Mac is not protected",
         "Tooltip after protection failed. Must not sound reassuring."),
        StringEntry("tip.foreign", "Another app is already keeping this Mac awake",
         "Tooltip when a different app holds the sleep override and Lidwing stood down."),
        StringEntry("tip.arming", "Checking that the lid setting took effect",
         "Tooltip while verifying, before Lidwing claims to be on."),
        StringEntry("tip.disarming", "Letting this Mac sleep normally again",
         "Tooltip while releasing the override."),
        StringEntry("tip.slept", "Click for details - this Mac slept while protected",
         "Tooltip after the machine slept despite protection. The one failure that matters."),

        StringEntry("notify.osRechecked.title", "macOS changed, and Lidwing still works",
         "Notification after the first successful arm following a macOS update."),
        StringEntry("notify.osRechecked.body", "Checked against %1$@ just now, not assumed.",
         "%1$@ is a macOS version string such as \"Version 15.6 (Build 24G84)\"."),

        StringEntry("settings.sound.play", "Play the Lid-Close Sound",
         "Button that plays the confirmation sound so the user can verify it works. Title case."),
        StringEntry("settings.sound.play.detail",
         "Plays it now, even if the sound is switched off above.",
         "Explanation under the Play button."),
        StringEntry("settings.sound.missing",
         "This Mac is missing the sounds Lidwing uses (%1$@). "
         + "Lid-close confirmation will be silent.",
         "%1$@ is a comma-separated list of internal chime names. Shown only when sounds are "
         + "genuinely absent."),

        StringEntry("uninstall.step.login", "Stop it opening at login.",
         "One line in the uninstall plan the user reads before confirming."),
        StringEntry("settings.startup", "Startup",
         "Section header above the login checkbox."),
        StringEntry("settings.login", "Open Lidwing at login",
         "Checkbox. Never ticked by default."),
        StringEntry("settings.login.detail",
         "Lidwing starts with your Mac. It still does nothing until you turn it on.",
         "Explanation under the login checkbox. The second sentence matters: starting at login "
         + "does not mean arming at login."),
        StringEntry("login.unavailable", "Opening at login needs macOS 13 or later.",
         "Shown instead of the checkbox on macOS 12, where no compliant mechanism exists."),
        StringEntry("login.approval",
         "Waiting for your approval in System Settings, under General \u{25B8} Login Items.",
         "Shown when macOS has registered the login item but the user has not approved it."),
        StringEntry("login.notFound", "macOS lost track of this. Switch it on again to fix it.",
         "Shown when the registration exists but macOS cannot find the app, usually after a move."),
        StringEntry("login.failed", "macOS would not change this: %1$@",
         "%1$@ is a system error message. Shown when register or unregister throws."),

        StringEntry("hardware.untested",
         "Lidwing has not been tested on this Mac. It will tell you if it cannot do its job.",
         "Shown when no acceptance run has happened on this model, macOS and architecture. It "
         + "must not read as a prediction of failure - what is missing is evidence, not a "
         + "working mechanism."),
        StringEntry("hardware.partial", "Tested briefly on this kind of Mac, not for a full run.",
         "Shown where the mechanism has been seen working but no full acceptance run happened."),

        // Menu — the entire visible surface of the product.
        StringEntry("menu.toggle", "Keep Awake with the Lid Closed",
         "The one command in the menu. Title case."),
        StringEntry("menu.off", "Off - your Mac sleeps normally",
         "Menu header when Lidwing is not protecting the machine."),
        StringEntry("menu.awake", "Awake - you can close the lid",
         "Menu header when protection is verified and active."),
        StringEntry("menu.awake.agent", "Awake - %1$@ is running",
         "%1$@ is a coding-agent binary name such as claude or codex."),
        StringEntry("menu.hot", "Awake - your Mac is running hot",
         "Still protecting, but the thermal guard is warning."),
        StringEntry("menu.hot.detail", "Lidwing turns off if it gets hotter.",
         "Explains what happens next if the Mac keeps heating up."),
        StringEntry("menu.battery", "Awake - battery %1$lld%%",
         "%1$lld is a whole-number percentage. Note the doubled percent sign."),
        StringEntry("menu.battery.detail", "Lidwing turns off at %1$lld%%.",
         "The user's configured battery floor."),
        StringEntry("menu.arming", "Checking that it worked\u{2026}",
         "Shown for up to two seconds while the machine is asked to confirm."),
        StringEntry("menu.arming.detail", "Lidwing never says it is on until your Mac agrees.",
         "Why there is a delay. This is a trust statement, not a progress message."),
        StringEntry("menu.disarming", "Putting your sleep setting back\u{2026}", "Shown while releasing."),
        StringEntry("menu.failed", "Your Mac slept at %1$@ despite protection",
         "%1$@ is a wall-clock time such as 03:12. The worst thing this app can report."),
        StringEntry("menu.slept", "Your Mac slept at %1$@",
         "%1$@ is a wall-clock time. Shown while protecting again after a recovered failure."),
        StringEntry("menu.slept.detail", "Protection is back on. See Diagnostics.", ""),
        StringEntry("menu.failed.noTime", "Lidwing could not protect this Mac",
         "Failure header when the exact time of the sleep is not known."),
        StringEntry("menu.failed.detail", "See Diagnostics. Protection is not active.", ""),
        StringEntry("menu.foreign", "Another app is keeping this Mac awake",
         "Something else holds a sleep assertion. Shown when Lidwing itself is off."),
        StringEntry("menu.foreign.transient", "%1$@ is also holding it awake, briefly.",
         "%1$@ is a process that declared it will release its hold shortly, such as caffeinate."),
        StringEntry("menu.foreign.strong", "%1$@ is holding this Mac awake on its own.",
         "%1$@ holds a system-sleep assertion, which stops sleep without Lidwing's help."),
        StringEntry("menu.foreign.detail", "%1$@ is also holding this Mac awake.",
         "%1$@ is the other app's name. Information, not an excuse: Lidwing still works."),
        StringEntry("menu.nolid", "This Mac has no lid",
         "Shown on a desktop Mac. The feature is hidden here, not merely disabled."),
        StringEntry("menu.nolid.detail", "There is no lid-close sleep to prevent here.", ""),
        StringEntry("menu.repair", "Something is keeping this Mac awake",
         "Launch found the machine in a non-stock state that Lidwing did not set this session."),
        StringEntry("menu.repair.detail", "It may be left over from Lidwing. Click Repair to put it back.",
         ""),
        StringEntry("menu.repair.action", "Repair Now\u{2026}", "Menu command. Real ellipsis, U+2026."),
        StringEntry("menu.sleepNow", "Sleep Now", "Releases protection, then sleeps the Mac."),
        StringEntry("menu.diagnostics", "Copy Diagnostics", ""),
        StringEntry("menu.settings", "Settings\u{2026}", "Real ellipsis, U+2026. Never 'Preferences'."),
        StringEntry("menu.uninstall", "Uninstall Lidwing\u{2026}", ""),
        StringEntry("menu.about", "About Lidwing", ""),
        StringEntry("menu.quit", "Quit Lidwing", ""),
        StringEntry("menu.agentWaiting", "%1$@ is waiting for you",
         "%1$@ is an agent name, or 'Your coding agent' when it did not say."),

        // Power and battery detail line.
        StringEntry("detail.left", "%1$@ left", "%1$@ is a duration such as 7h 12m."),
        StringEntry("detail.battery", "battery %1$lld%%",
         "%1$lld is a whole-number percentage. Note the doubled percent sign."),
        StringEntry("detail.pluggedIn", "plugged in", ""),
        StringEntry("detail.onBattery", "on battery", ""),

        // Refusals. Each one names a specific cause; there is no generic error string.
        StringEntry("refuse.noLid", "This Mac has no lid, so there is no lid-close sleep to prevent.", ""),
        StringEntry("refuse.unsupported",
         "This version of macOS changed how sleep works. Lidwing needs an update.", ""),
        StringEntry("refuse.batteryLow",
         "The battery is already at or below your stop limit. Plug in and try again.", ""),
        StringEntry("refuse.tooHot", "This Mac is too hot right now. Let it cool down and try again.", ""),
        StringEntry("refuse.foreign",
         "Another app is already keeping this Mac awake: %1$@ (pid %2$lld).",
         "%1$@ is the other app's name, %2$lld its process id."),
        StringEntry("refuse.externalDisplay",
         "macOS already does this for you while an external display is attached on power.",
         "Saying this costs a user and buys the credibility that carries the rest."),
        StringEntry("refuse.watchdog",
         "Lidwing could not start its safety watchdog, so it will not keep this Mac awake.",
         "Lidwing refuses to hold the mechanism without something that can undo it."),
        StringEntry("refuse.notInApplications", "Move Lidwing to your Applications folder first.", ""),

        // Notifications.
        StringEntry("notify.firstArm.title", "Lidwing is running", ""),
        StringEntry("notify.firstArm.body",
         "Look for the wing in your menu bar. You can close the lid now.", ""),
        StringEntry("notify.stopped.title", "Lidwing stopped", ""),
        StringEntry("notify.armFailed.title", "Lidwing could not keep this Mac awake", ""),
        StringEntry("notify.armFailed.body",
         "Your Mac will still sleep when you close the lid. Open Lidwing for details.", ""),
        StringEntry("notify.releaseFailed.title", "Lidwing could not put your sleep setting back", ""),
        StringEntry("notify.releaseFailed.body",
         "Open Lidwing and choose Repair, or restart your Mac.", ""),
        StringEntry("notify.slept.title", "Your Mac slept despite protection", ""),
        StringEntry("notify.slept.body",
         "Lidwing re-armed itself. See Diagnostics for the exact time.", ""),
        StringEntry("notify.recovered.title", "Lidwing quit unexpectedly", ""),
        StringEntry("notify.recovered.body", "Lid-close sleep has been restored.", ""),
        StringEntry("notify.bag.title", "Don't put your Mac in a bag while Lidwing is on", ""),
        StringEntry("notify.bag.body", "With the lid closed and no airflow it can get very hot.", ""),
        StringEntry("notify.groundTruthLost.title", "Lidwing is no longer protecting this Mac", ""),
        StringEntry("notify.groundTruthLost.body",
         "Something else changed the sleep setting. Open Lidwing for details.", ""),
        StringEntry("notify.hot.title", "Your Mac is running hot", ""),
        StringEntry("notify.hot.body", "Lidwing stops automatically if it gets hotter.", ""),
        StringEntry("notify.lowBattery.title", "Battery is getting low", ""),
        StringEntry("notify.lowBattery.body",
         "Lidwing stops soon and lets your Mac sleep normally.", ""),

        // Why an automatic stand-down happened. Every reason explains itself; none of them is
        // allowed to be silent, because the user's long-running task just ended.
        StringEntry("stopped.batteryFloor",
         "Stopped at the battery limit. Your Mac is sleeping normally now.", ""),
        StringEntry("stopped.thermal", "Your Mac got too hot. Lidwing stopped so it can cool down.",
         ""),
        StringEntry("stopped.timer", "The time limit elapsed. Lidwing stopped.", ""),
        StringEntry("stopped.agentExited", "Your coding agent finished. Lidwing stopped.", ""),
        StringEntry("stopped.watchdogLost", "Lidwing lost its safety watchdog and stood down.", ""),
        StringEntry("stopped.unsupportedState",
         "Lidwing stood down because this Mac's state changed.", ""),
        StringEntry("stopped.failure",
         "Lidwing stopped protecting this Mac. Open Lidwing for details.", ""),

        StringEntry("agent.generic", "Your coding agent",
         "Used when the hook did not say which tool it came from."),
        StringEntry("agent.waiting.body", "It needs an answer before it can carry on.",
         "Shown when the agent sent no message of its own."),

        // Settings. Every row is a label, a control and a sentence saying what the choice
        // costs; a checkbox whose consequence is unstated is one nobody can decide about.
        StringEntry("settings.title", "Lidwing Settings",
         "Window title. Apple's rule: 'App Name Settings' for a single-pane window."),
        StringEntry("settings.when", "When to keep this Mac awake", "Section header."),
        StringEntry("settings.mode.manual", "Manual", "Segmented control label."),
        StringEntry("settings.mode.auto", "Auto", "Segmented control label."),
        StringEntry("settings.mode.detail",
         "Auto turns Lidwing on by itself while claude, codex or cursor-agent is running, "
         + "and off again a few minutes after the last one exits.", ""),
        StringEntry("settings.limits", "It stops on its own", "Section header. The trust screen."),
        StringEntry("settings.floor", "Stop when the battery reaches", ""),
        StringEntry("settings.floor.detail",
         "Your Mac goes to sleep instead of running the battery flat.", ""),
        StringEntry("settings.duration", "Stop after", ""),
        StringEntry("settings.duration.detail",
         "Lidwing turns itself off after this long, even if you forget.", ""),
        StringEntry("settings.duration.hours", "%1$lld hours",
         "%1$lld is a whole number of hours."),
        StringEntry("settings.floor.custom", "%1$lld%% (custom)",
         "Shown when the stored value is not one of the offered choices. %1$lld is a percentage."),
        StringEntry("settings.duration.custom", "%1$lld hours (custom)",
         "Shown when the stored value is not one of the offered choices. %1$lld is hours."),
        StringEntry("settings.duration.none", "No limit",
         "The one choice that removes a safety net, so the one choice that asks."),
        StringEntry("settings.thermal", "Stop if the Mac gets too hot", ""),
        StringEntry("settings.thermal.detail",
         "A closed lid blocks airflow. Lidwing stops before your Mac overheats.", ""),
        StringEntry("settings.sound", "Sound", "Section header."),
        StringEntry("settings.sound.lidClose", "Play a sound when the lid closes", ""),
        StringEntry("settings.sound.detail",
         "You can't see the screen with the lid closed, so Lidwing says it out loud.", ""),
        StringEntry("settings.agents", "Coding agents", "Section header."),
        StringEntry("settings.agents.detail",
         "Lidwing can make a sound when your agent is waiting for you, so you hear it with "
         + "the lid closed. It shows you every line before it writes one.", ""),
        StringEntry("settings.agents.found", "%1$@ - found at ~/%2$@",
         "%1$@ is a tool name such as Claude Code, %2$@ a path such as .claude/settings.json."),
        StringEntry("settings.agents.missing", "%1$@ - not installed",
         "%1$@ is a tool name."),
        StringEntry("settings.agents.show", "Show What Will Be Written\u{2026}",
         "The only button that leads to a write, named for what it does first."),
        StringEntry("settings.agents.remove", "Remove", ""),
        StringEntry("settings.bagWarning",
         "\u{26A0}\u{FE0E} Don't put your Mac in a bag while Lidwing is on.", ""),
        StringEntry("settings.noLimit.title", "Run with no time limit?", ""),
        StringEntry("settings.noLimit.body",
         "The battery and heat limits still apply, so Lidwing will still stop before your Mac "
         + "runs flat or gets too hot. But it will not stop just because time passed, and a "
         + "forgotten Lidwing is how a laptop ends up warm in a bag.", ""),
        StringEntry("settings.noLimit.confirm", "Remove the Time Limit", ""),

        // Buttons that appear in more than one dialog.
        StringEntry("button.ok", "OK", ""),
        StringEntry("button.cancel", "Cancel", ""),

        // Uninstall. An app that can stop a Mac sleeping and cannot remove itself is
        // indistinguishable from malware, so this path is as carefully worded as the install.
        StringEntry("uninstall.confirm.title", "Remove Lidwing from this Mac?", ""),
        StringEntry("uninstall.confirm.action", "Remove Lidwing", ""),
        StringEntry("uninstall.willDo", "Lidwing will:", ""),
        StringEntry("uninstall.willDelete", "Files it will delete:", ""),
        StringEntry("uninstall.noSettings",
         "It changes no system settings on the way out: Lidwing never wrote one.", ""),
        StringEntry("uninstall.checkWith", "You can check afterwards with:", ""),
        StringEntry("uninstall.step.disarm",
         "Let your Mac sleep on lid close again, and check that it did.", ""),
        StringEntry("uninstall.step.integrations",
         "Remove its entries from any coding-agent config it wrote.", ""),
        StringEntry("uninstall.step.restore", "Put back anything it displaced, exactly.", ""),
        StringEntry("uninstall.step.watchdog", "Stop and remove its background helper.", ""),
        StringEntry("uninstall.step.files", "Delete its own files.", ""),
        StringEntry("uninstall.step.verify", "Check that nothing of Lidwing is left.", ""),
        StringEntry("uninstall.step.reveal",
         "Show you Lidwing in Finder so you can drag it to the Trash.", ""),
        StringEntry("uninstall.done.title", "Lidwing removed", ""),
        StringEntry("uninstall.done.body", "Drag Lidwing to the Trash to finish.", ""),
        StringEntry("uninstall.failed.title", "Lidwing was not fully removed", ""),
        StringEntry("uninstall.failed.body",
         "If your Mac still will not sleep when you close the lid, restarting it clears the "
         + "setting: Lidwing never writes anything that survives a restart.", ""),

        // Integrations.
        StringEntry("integration.absent.title", "%1$@ is not installed here",
         "%1$@ is a tool name such as Codex."),
        StringEntry("integration.absent.body",
         "Lidwing looked for ~/%1$@ and did not find it. It never creates a configuration "
         + "file for a tool you do not have.", "%1$@ is a path such as .codex/config.toml."),
        StringEntry("integration.unreadable.title", "Lidwing will not change %1$@'s settings",
         "%1$@ is a tool name."),
        StringEntry("integration.unreadable.body",
         "It could not read ~/%1$@ well enough to be sure it would change only its own line, "
         + "so it changed nothing at all.", "%1$@ is a path."),
        StringEntry("integration.already.title", "Already set up", ""),
        StringEntry("integration.already.body",
         "%1$@ already runs Lidwing's notifier. Nothing to do.", "%1$@ is a tool name."),
        StringEntry("integration.offer.title", "Add Lidwing to %1$@?", "%1$@ is a tool name."),
        StringEntry("integration.offer.body",
         "Lidwing will change exactly these lines in ~/%1$@, and keep a dated backup of the "
         + "file beside it.", "%1$@ is a path."),
        StringEntry("integration.offer.chaining",
         "%1$@ already runs something here. Lidwing will chain to it rather than replace it, "
         + "so it keeps working:", "%1$@ is a tool name."),
        StringEntry("integration.offer.confirm", "Write These Lines", ""),
        StringEntry("integration.done.title", "Done", ""),
        StringEntry("integration.done.body",
         "%1$@ will tell Lidwing when it needs you, and Lidwing will make a sound so you hear "
         + "it with the lid closed.", "%1$@ is a tool name."),
        StringEntry("integration.writeFailed.title", "Lidwing could not write the file", ""),
        StringEntry("integration.removed.title", "Removed", ""),
        StringEntry("integration.removed.body",
         "Lidwing's entry is gone from ~/%1$@. Everything else in the file is exactly as it "
         + "was.", "%1$@ is a path."),
        StringEntry("integration.nothing.title", "Nothing to remove", ""),
        StringEntry("integration.nothing.body",
         "Lidwing had not written anything to ~/%1$@.", "%1$@ is a path."),

        // Refusal and repair dialogs.
        StringEntry("dialog.didNotTurnOn.title", "Lidwing did not turn on",
         "Title above one of the refusal sentences, which says specifically why."),
        StringEntry("dialog.repair.title",
         "This Mac is set not to sleep when you close the lid", ""),
        StringEntry("dialog.repair.body",
         "Lidwing did not set this in the session that is running now, so it will not change "
         + "anything without asking. This is usually left over from a previous run.", ""),
        StringEntry("dialog.repair.body2",
         "Repair puts the setting back the way macOS ships it.", ""),
        StringEntry("dialog.repair.confirm", "Repair", ""),
        StringEntry("dialog.repair.decline", "Leave It Alone",
         "Never a bare Cancel here: declining is a real choice with a real consequence."),
        StringEntry("dialog.alreadyRunning.title", "Lidwing is already running", ""),
        StringEntry("dialog.alreadyRunning.body", "Look for the wing in your menu bar.", "")
    ]
}
