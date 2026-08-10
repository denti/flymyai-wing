import AppKit

/// The application menu bar.
///
/// An `LSUIElement` app has no menu bar while it is not frontmost, so this looks pointless
/// right up until one of its windows is key — and then its absence is very visible:
///
/// * **Without an Edit menu**, `⌘C`, `⌘V` and `⌘A` do not work in this app's own text, and
///   users blame the app rather than the missing menu.
/// * **Without a Window menu**, a Full Keyboard Access user cannot minimise the Settings
///   window, because the only route to Minimise is that menu.
///
/// File, Format and View are deliberately absent: this app has no documents, no formatting and
/// no view options, and a menu full of permanently disabled items is worse than no menu.
enum MainMenu {

    static func install(into application: NSApplication) {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem(for: application))
        mainMenu.addItem(helpMenuItem())
        application.mainMenu = mainMenu
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Lidwing")

        menu.addItem(withTitle: "About Lidwing",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        // Xcode's own template still ships "Preferences…" and relies on an AppKit runtime
        // rename. It is spelled out here, with a real U+2026 rather than three periods.
        menu.addItem(withTitle: "Settings\u{2026}", action: nil, keyEquivalent: ",")
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Lidwing", action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lidwing", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    private static func windowMenuItem(for application: NSApplication) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item.submenu = menu
        application.windowsMenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        // Not "Lidwing Help": that needs `CFBundleHelpBookFolder` and a real Help Book, and
        // without them the row opens nothing, which is worse than not shipping it. The row is
        // named for what it actually does.
        menu.addItem(withTitle: "What Lidwing Changes on Your Mac",
                     action: #selector(AppDelegate.showWhatItChanges), keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
