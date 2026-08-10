import Foundation

/// The text of the menu, computed from state. Pure, so the strings can be tested without a
/// window server — which matters, because CI has no Aqua session and a screenshot proves
/// nothing there.
///
/// String rules, from the craft spec: sentence case with a period for explanatory text, title
/// case for actions, a real ellipsis (U+2026), and `-` only — never an em or en dash.
public struct MenuPresenter {
    public struct Content: Equatable {
        public let headline: String
        public let detail: String?
        public let toggleTitle: String
        public let toggleChecked: Bool
        public let toggleEnabled: Bool
        public let accessibilityValue: String
    }

    public struct Snapshot {
        public let state: LidwingState
        public let armedSince: Date?
        public let now: Date
        public let batteryPercent: Int?
        public let onAC: Bool
        public let thermal: ThermalState
        public let floorPercent: Int
        public let remainingSeconds: Int?
        public let lastFailureAt: Date?
        public let foreignHolder: ForeignHolder?
        public let agentRunning: String?
        /// How many times this Mac has slept during the current armed session. Any number
        /// above zero is a hard failure that stays visible even after a successful re-arm.
        public let sleepsObserved: Int

        public init(state: LidwingState, armedSince: Date?, now: Date, batteryPercent: Int?,
                    onAC: Bool, thermal: ThermalState, floorPercent: Int,
                    remainingSeconds: Int?, lastFailureAt: Date?, foreignHolder: ForeignHolder?,
                    agentRunning: String?, sleepsObserved: Int = 0) {
            self.state = state
            self.armedSince = armedSince
            self.now = now
            self.batteryPercent = batteryPercent
            self.onAC = onAC
            self.thermal = thermal
            self.floorPercent = floorPercent
            self.remainingSeconds = remainingSeconds
            self.lastFailureAt = lastFailureAt
            self.foreignHolder = foreignHolder
            self.agentRunning = agentRunning
            self.sleepsObserved = sleepsObserved
        }
    }

    public static func content(for snapshot: Snapshot) -> Content {
        let toggleTitle = Strings.text("menu.toggle", "Keep Awake with the Lid Closed")

        switch snapshot.state {
        case .unsupported:
            return Content(headline: Strings.text("menu.nolid", "This Mac has no lid"),
                           detail: Strings.text("menu.nolid.detail",
                                                "There is no lid-close sleep to prevent here."),
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: false,
                           accessibilityValue: "Unsupported on this Mac")

        case .repair:
            return Content(headline: Strings.text("menu.repair",
                                                  "Something is keeping this Mac awake"),
                           detail: Strings.text("menu.repair.detail",
                                                "It may be left over from Lidwing. "
                                                + "Click Repair to put it back."),
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: false,
                           accessibilityValue: "Needs repair")

        case .failed:
            let headline = snapshot.lastFailureAt.map {
                Strings.text("menu.failed", "Your Mac slept at %1$@ despite protection", clock($0))
            } ?? Strings.text("menu.failed.noTime", "Lidwing could not protect this Mac")
            return Content(headline: headline,
                           detail: Strings.text("menu.failed.detail",
                                                "See Diagnostics. Protection is not active."),
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: true,
                           accessibilityValue: "Failed, this Mac is not protected")

        case .idle:
            if let holder = snapshot.foreignHolder {
                return Content(headline: Strings.text("menu.foreign",
                                                      "Another app is keeping this Mac awake"),
                               detail: foreignDetail(holder),
                               toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: true,
                               accessibilityValue: "Off, another app is keeping this Mac awake")
            }
            return Content(headline: Strings.text("menu.off", "Off - your Mac sleeps normally"),
                           detail: power(snapshot),
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: true,
                           accessibilityValue: "Off")

        case .arming:
            return Content(headline: Strings.text("menu.arming", "Checking that it worked\u{2026}"),
                           detail: Strings.text("menu.arming.detail",
                                                "Lidwing never says it is on until your Mac agrees."),
                           toggleTitle: toggleTitle, toggleChecked: true, toggleEnabled: true,
                           accessibilityValue: "Turning on")

        case .disarming:
            return Content(headline: Strings.text("menu.disarming",
                                                  "Putting your sleep setting back\u{2026}"),
                           detail: nil,
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: false,
                           accessibilityValue: "Turning off")

        case .armed, .degraded:
            return protecting(snapshot, toggleTitle: toggleTitle)
        }
    }

    /// A sleep that already happened does not stop being true because we recovered from it.
    ///
    /// Both known holes in the mechanism have the same precondition — the machine must have
    /// slept at least once — so the first sleep is the one that opens the door for the rest.
    /// Showing a plain "Awake" after re-arming would tell the user the run is fine when the
    /// most important thing about it is that it is not.
    private static func recoveredHeadline(_ snapshot: Snapshot) -> Content? {
        guard snapshot.sleepsObserved > 0, let at = snapshot.lastFailureAt else { return nil }
        return Content(headline: Strings.text("menu.slept", "Your Mac slept at %1$@", clock(at)),
                       detail: Strings.text("menu.slept.detail",
                                            "Protection is back on. See Diagnostics."),
                       toggleTitle: Strings.text("menu.toggle",
                                                 "Keep Awake with the Lid Closed"),
                       toggleChecked: true, toggleEnabled: true,
                       accessibilityValue: "On, but this Mac slept once despite protection")
    }

    /// The armed and degraded states, which differ only in what they have to warn about.
    private static func protecting(_ snapshot: Snapshot, toggleTitle: String) -> Content {
        if let recovered = recoveredHeadline(snapshot) { return recovered }
        var headline = Strings.text("menu.awake", "Awake - you can close the lid")
        if let agent = snapshot.agentRunning {
            headline = Strings.text("menu.awake.agent", "Awake - %1$@ is running", agent)
        }
        var detail = power(snapshot)
        var accessibility = "On, keeping this Mac awake"

        if snapshot.state == .degraded {
            if snapshot.thermal >= .serious {
                headline = Strings.text("menu.hot", "Awake - your Mac is running hot")
                detail = Strings.text("menu.hot.detail", "Lidwing turns off if it gets hotter.")
                accessibility = "On, this Mac is running hot"
            } else if let percent = snapshot.batteryPercent,
                      percent <= snapshot.floorPercent + SafetyPolicy.earlyWarningMargin {
                headline = Strings.text("menu.battery", "Awake - battery %1$lld%%", Int64(percent))
                detail = Strings.text("menu.battery.detail", "Lidwing turns off at %1$lld%%.",
                                      Int64(snapshot.floorPercent))
                accessibility = "On, battery \(percent) percent"
            } else if let holder = snapshot.foreignHolder {
                detail = foreignDetail(holder)
            }
        }
        if let elapsed = snapshot.armedSince.map({ snapshot.now.timeIntervalSince($0) }) {
            accessibility += ", \(spokenDuration(Int(elapsed))) so far"
        }
        return Content(headline: headline, detail: detail,
                       toggleTitle: toggleTitle, toggleChecked: true, toggleEnabled: true,
                       accessibilityValue: accessibility)
    }

    private static func foreignDetail(_ holder: ForeignHolder) -> String {
        Strings.text("menu.foreign.detail", "%1$@ (pid %2$lld) - Lidwing stood down.",
                     holder.name, Int64(holder.pid))
    }

    private static func power(_ snapshot: Snapshot) -> String? {
        var parts: [String] = []
        if let remaining = snapshot.remainingSeconds, remaining > 0 {
            parts.append(Strings.text("detail.left", "%1$@ left", compactDuration(remaining)))
        }
        if let percent = snapshot.batteryPercent {
            parts.append(Strings.text("detail.battery", "battery %1$lld%%", Int64(percent)))
        }
        parts.append(snapshot.onAC ? Strings.text("detail.pluggedIn", "plugged in")
                                   : Strings.text("detail.onBattery", "on battery"))
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "7h 12m". Monospaced digits in the menu keep this from twitching every second.
    public static func compactDuration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    /// VoiceOver reads "7h" as "seven aitch". Spell it.
    public static func spokenDuration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if parts.isEmpty { parts.append("less than a minute") }
        return parts.joined(separator: " ")
    }
}
