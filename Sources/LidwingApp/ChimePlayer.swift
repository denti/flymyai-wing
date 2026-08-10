import Foundation
import AudioToolbox
import AppKit
import LidwingCore

/// The three sounds, and nothing else.
///
/// Stock system sounds only. A bundled whoosh or marimba marks an app as cross-platform
/// instantly, and these three have meant the same thing on this platform for twenty years.
///
/// Routing matters more than the choice of sound. The confirmations go through the **alert**
/// path, so they follow the user's Alert volume slider and their chosen alert output device.
/// `NSSound.play()` would send them at *media* volume to the *default output*, ignoring both.
/// The failure sound goes through the system-sound path with `IsUISound = 0`, which the header
/// documents as audible "regardless of user's setting in the Sound Preferences" — a failure is
/// the one thing that must land even for someone who turned interface sounds off.
///
/// Notifications are never used as the channel: `UNUserNotificationCenter` sound is suppressed
/// by Focus and Do Not Disturb, and this product's user has a Focus mode on *while the agent
/// runs*, which is exactly when the lid-close sound has to arrive. Direct playback by our own
/// process is not gated by Focus and needs no permission.
final class ChimePlayer {

    private var identifiers: [Chime: SystemSoundID] = [:]
    /// Whether the user wants sound at all.
    var enabled = true
    /// Chimes for which no stock sound could be found on this Mac. Reported, never swallowed:
    /// with the lid shut, sound is the only channel this product has.
    private(set) var missing: [Chime] = []

    init(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        let chosen = ChimeCatalogue.resolve(exists: exists)
        for (chime, file) in chosen {
            prepare(chime, file: file)
        }
        // Two ways to end up without a sound: nothing on disk, and a file that AudioToolbox
        // refused. Both are reported, because both are silent to the user in exactly the same
        // way - and the second one is the sort that appears after an OS update.
        missing = ChimeCatalogue.candidates.keys
            .filter { identifiers[$0] == nil }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// The self-check, in the user's words. `nil` when everything works.
    var selfCheckWarning: String? {
        ChimeCatalogue.selfCheckWarning(missing: missing)
    }

    deinit {
        for identifier in identifiers.values {
            AudioServicesDisposeSystemSoundID(identifier)
        }
    }

    /// Created once, at launch. Creating one at lid-close time would add disk latency to the
    /// single event that has to be immediate.
    private func prepare(_ chime: Chime, file: String) {
        let url = URL(fileURLWithPath: ChimeCatalogue.path(for: file))
        var identifier: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &identifier) == kAudioServicesNoError
        else { return }

        // A crash mid-chime still finishes the sound.
        var one: UInt32 = 1
        AudioServicesSetProperty(kAudioServicesPropertyCompletePlaybackIfAppDies,
                                 UInt32(MemoryLayout<SystemSoundID>.size), &identifier,
                                 UInt32(MemoryLayout<UInt32>.size), &one)
        if chime == .failure {
            var zero: UInt32 = 0
            AudioServicesSetProperty(kAudioServicesPropertyIsUISound,
                                     UInt32(MemoryLayout<SystemSoundID>.size), &identifier,
                                     UInt32(MemoryLayout<UInt32>.size), &zero)
        }
        identifiers[chime] = identifier
    }

    func play(_ chime: Chime) {
        // A failure is always audible: the user opted into knowing when this app cannot do its
        // job, and silencing that is how a product rots without telling anyone.
        guard enabled || chime == .failure else { return }
        guard let identifier = identifiers[chime] else { return }
        if chime == .failure {
            AudioServicesPlaySystemSoundWithCompletion(identifier, nil)
        } else {
            AudioServicesPlayAlertSoundWithCompletion(identifier, nil)
        }
    }

    /// Plays a chime because the user pressed Play, ignoring their sound preference: the point
    /// of the button is to answer "does this actually work on my Mac", and honouring a disabled
    /// checkbox would answer it with silence that means something else entirely.
    func preview(_ chime: Chime) {
        guard let identifier = identifiers[chime] else { return }
        AudioServicesPlayAlertSoundWithCompletion(identifier, nil)
    }

    /// A bonus, never a confirmation. `defaultPerformer` is nil on Macs with no Force Touch
    /// trackpad, and the header warns that a Force Touch trackpad will not perform feedback
    /// unless the user is currently touching it.
    func haptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}
