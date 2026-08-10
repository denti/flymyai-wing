import AppKit
import LidwingCore
import LidwingSystem

@main
enum LidwingMain {
    static func main() {
        // Two Lidwings racing to set and clear the same bit is a correctness bug, not a
        // cosmetic one, so the second instance leaves rather than fighting.
        // NSApplication has to exist before any alert: `runModal` drives `NSApp`, and touching
        // it implicitly from a static context is a launch-time crash waiting for the one user
        // who double-clicks twice.
        let application = NSApplication.shared

        guard SingleInstance.acquire() else {
            let alert = NSAlert()
            alert.messageText = "Lidwing is already running"
            alert.informativeText = "Look for the wing in your menu bar."
            alert.runModal()
            return
        }

        let delegate = AppDelegate()
        application.delegate = delegate
        // Belt and braces with LSUIElement in Info.plist. Never `.regular` to show a window:
        // the Dock icon would flash in and out and the app would appear inconsistently in
        // Command-Tab.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var coordinator: AppCoordinator?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator

        let statusItem = StatusItemController(coordinator: coordinator)
        self.statusItem = statusItem

        coordinator.onStateChange = { [weak statusItem] in
            statusItem?.refresh()
        }
        // Pick the user's language before anything draws. English is the fallback, and a key
        // with no translation renders in English rather than vanishing.
        Strings.localiser = Translations.localiser(for: Locale.preferredLanguages)

        MainMenu.install(into: NSApplication.shared)
        coordinator.start()
        statusItem.refresh()

        installSignalHandlers()
    }

    /// Cocoa does **not** route SIGTERM through `applicationWillTerminate`. launchd, a logout
    /// and `killall` all use it, and without this the restore would simply not run.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.coordinator?.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// The Help menu's one row. Named for what it does, because a "Lidwing Help" row without a
    /// real Help Book opens nothing at all.
    @objc func showWhatItChanges() {
        let alert = NSAlert()
        alert.messageText = "What Lidwing changes on your Mac"
        alert.informativeText = [
            "One kernel flag, and it is not stored anywhere.",
            "",
            "While Lidwing is on it sets the clamshell sleep-disable bit on IOPMrootDomain and",
            "holds a named power assertion. It writes no pmset settings, it needs no password,",
            "and it installs nothing outside its own folder.",
            "",
            "macOS resets that flag to zero every time your Mac starts, so a restart always",
            "clears it - even if you have already deleted Lidwing.",
            "",
            "Check it yourself, with Lidwing on and then off:",
            "  ioreg -r -c IOPMrootDomain -d 1 | grep AppleClamshellCausesSleep",
            "  pmset -g assertions | grep -i lidwing"
        ].joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        SingleInstance.release()
    }

    /// Relaunching from Finder or Spotlight is the first thing a lost user tries. An
    /// LSUIElement app that does nothing there looks dead.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        statusItem?.flash()
        return true
    }

    /// Always available, unlike a menu bar extra. This is the escape hatch when the notch eats
    /// the icon or a menu-bar manager hides it — without it, a hidden icon would mean no way
    /// to turn the thing off.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        statusItem?.buildMenu()
    }
}

/// A single-instance lock that survives a crash, because it is held by the kernel rather than
/// written to a file we would have to clean up.
enum SingleInstance {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        SupportDirectory.ensure()
        let path = SupportDirectory.file("instance.lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return true }   // cannot lock: do not block the user
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    static func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
