import Foundation

/// Every word the user reads on first launch, in the portable module so it is testable and so
/// a change to it shows up in a diff rather than inside a view controller.
///
/// The shape of this screen is the product's honesty test: the limitations come **first**, on
/// the same screen as the promise, because a user who learns them later learns them from a hot
/// laptop.
public enum FirstRunCopy {

    /// The pointer that appears once, ever, under the status item. Not a splash screen, not a
    /// carousel, not a branding moment — a Dock-less app owes its user one arrow at its only UI.
    public enum LocationCallout {
        public static let headline = "Lidwing lives up here."
        public static let body = "Click the wing to keep your Mac awake with the lid closed."
        public static let dismiss = "Got it"
        /// Auto-dismisses; a modal that waits for a click on first launch is a nag.
        public static let autoDismissSeconds: TimeInterval = 8
    }

    /// One screen, shown before the first arm. One decision, and no second styled button
    /// competing with it.
    public enum Explainer {
        public static let title = "What Lidwing does"

        public static let promise =
            "Lidwing keeps your Mac running with the lid closed, so a long task can finish."

        /// Stated up front, not in a help page. Each of these is something the user will
        /// otherwise discover from a warm laptop and a flat battery.
        public static let limitations = [
            "The screen turns off, but your Mac keeps working - and it runs hotter than usual.",
            "Your battery drains far faster than it would while sleeping.",
            "Don't put your Mac in a bag while Lidwing is on. There is no airflow in there."
        ]

        /// Tier 1 asks for nothing at all, and that is worth saying plainly: it is the single
        /// biggest difference between this and everything else in the category.
        public static let permissions =
            "Lidwing needs no password and no permissions. It changes one setting that macOS "
            + "resets by itself when you restart, and it puts that setting back when you turn "
            + "Lidwing off, quit it, or if it ever crashes."

        public static func safetyDefaults(floorPercent: Int, hours: Int) -> [String] {
            [
                "Stop at \(floorPercent)% battery, and let your Mac sleep normally.",
                "Stop after \(hours) hours, even if you forget.",
                "Stop if your Mac gets too hot."
            ]
        }

        public static let safetyHeadline = "It stops on its own"
        public static let confirm = "Continue"
    }

    /// Shown after the first successful arm. A non-technical user needs to see the thing prove
    /// itself once, in the machine's own words rather than ours.
    public enum Proof {
        public static let title = "Verified"
        public static let body =
            "Your Mac now reports that closing the lid will not put it to sleep. Lidwing read "
            + "that back from the system; it is not just our word for it."
        public static let command = "ioreg -r -c IOPMrootDomain -d 1 | grep AppleClamshellCausesSleep"
    }
}
