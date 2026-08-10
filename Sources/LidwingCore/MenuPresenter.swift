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

        public init(state: LidwingState, armedSince: Date?, now: Date, batteryPercent: Int?,
                    onAC: Bool, thermal: ThermalState, floorPercent: Int,
                    remainingSeconds: Int?, lastFailureAt: Date?, foreignHolder: ForeignHolder?,
                    agentRunning: String?) {
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
        }
    }

    public static func content(for snapshot: Snapshot) -> Content {
        let toggleTitle = "Keep Awake with the Lid Closed"

        switch snapshot.state {
        case .unsupported:
            return Content(headline: "This Mac has no lid",
                           detail: "There is no lid-close sleep to prevent here.",
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: false,
                           accessibilityValue: "Unsupported on this Mac")

        case .repair:
            return Content(headline: "Something is keeping this Mac awake",
                           detail: "It may be left over from Lidwing. Click Repair to put it back.",
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: false,
                           accessibilityValue: "Needs repair")

        case .failed:
            let when = snapshot.lastFailureAt.map { clock($0) }
            return Content(headline: when.map { "Your Mac slept at \($0) despite protection" }
                                ?? "Lidwing could not protect this Mac",
                           detail: "See Diagnostics. Protection is not active.",
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: true,
                           accessibilityValue: "Failed, this Mac is not protected")

        case .idle:
            if let holder = snapshot.foreignHolder {
                return Content(headline: "Another app is keeping this Mac awake",
                               detail: "\(holder.name) (pid \(holder.pid)) - Lidwing stood down.",
                               toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: true,
                               accessibilityValue: "Off, another app is keeping this Mac awake")
            }
            return Content(headline: "Off - your Mac sleeps normally",
                           detail: power(snapshot),
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: true,
                           accessibilityValue: "Off")

        case .arming:
            return Content(headline: "Checking that it worked\u{2026}",
                           detail: "Lidwing never says it is on until your Mac agrees.",
                           toggleTitle: toggleTitle, toggleChecked: true, toggleEnabled: true,
                           accessibilityValue: "Turning on")

        case .disarming:
            return Content(headline: "Putting your sleep setting back\u{2026}",
                           detail: nil,
                           toggleTitle: toggleTitle, toggleChecked: false, toggleEnabled: false,
                           accessibilityValue: "Turning off")

        case .armed, .degraded:
            var headline = "Awake - you can close the lid"
            if let agent = snapshot.agentRunning {
                headline = "Awake - \(agent) is running"
            }
            var detail = power(snapshot)
            var accessibility = "On, keeping this Mac awake"

            if snapshot.state == .degraded {
                if snapshot.thermal >= .serious {
                    headline = "Awake - your Mac is running hot"
                    detail = "Lidwing turns off if it gets hotter."
                    accessibility = "On, this Mac is running hot"
                } else if let percent = snapshot.batteryPercent,
                          percent <= snapshot.floorPercent + SafetyPolicy.earlyWarningMargin {
                    headline = "Awake - battery \(percent)%"
                    detail = "Lidwing turns off at \(snapshot.floorPercent)%."
                    accessibility = "On, battery \(percent) percent"
                } else if let holder = snapshot.foreignHolder {
                    detail = "\(holder.name) (pid \(holder.pid)) is also holding this Mac awake."
                }
            }
            if let elapsed = snapshot.armedSince.map({ snapshot.now.timeIntervalSince($0) }) {
                accessibility += ", \(spokenDuration(Int(elapsed))) so far"
            }
            return Content(headline: headline, detail: detail,
                           toggleTitle: toggleTitle, toggleChecked: true, toggleEnabled: true,
                           accessibilityValue: accessibility)
        }
    }

    private static func power(_ snapshot: Snapshot) -> String? {
        var parts: [String] = []
        if let remaining = snapshot.remainingSeconds, remaining > 0 {
            parts.append("\(compactDuration(remaining)) left")
        }
        if let percent = snapshot.batteryPercent {
            parts.append("battery \(percent)%")
        }
        parts.append(snapshot.onAC ? "plugged in" : "on battery")
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
