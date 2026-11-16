import AppKit

/// Builds the menu bar in code (no nib). Items target the responder chain (`target = nil`).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Kansio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kansio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Kansio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Kansio", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        let hidden = view.addItem(withTitle: "Show Hidden Files", action: #selector(MainWindowController.toggleHiddenFiles(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        add(view, title: "View", to: main)

        let go = NSMenu(title: "Go")
        go.addItem(withTitle: "Back", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: "Forward", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "]")
        let up = go.addItem(withTitle: "Enclosing Folder", action: #selector(MainWindowController.goUp(_:)), keyEquivalent: "\u{F700}") // ↑
        up.keyEquivalentModifierMask = [.command]
        go.addItem(.separator())
        go.addItem(withTitle: "Location…", action: #selector(MainWindowController.editLocation(_:)), keyEquivalent: "l")
        let goTo = go.addItem(withTitle: "Go to Folder…", action: #selector(MainWindowController.editLocation(_:)), keyEquivalent: "g")
        goTo.keyEquivalentModifierMask = [.command, .shift]
        go.addItem(.separator())
        // Finder's shortcuts for the favorites.
        let favorites: [(String, String, NSEvent.ModifierFlags, MainWindowController.Favorite)] = [
            ("Home", "h", [.command, .shift], .home),
            ("Desktop", "d", [.command, .shift], .desktop),
            ("Documents", "o", [.command, .shift], .documents),
            ("Downloads", "l", [.command, .option], .downloads),
            ("Applications", "a", [.command, .shift], .applications),
        ]
        for (title, key, mods, favorite) in favorites {
            let item = go.addItem(withTitle: title, action: #selector(MainWindowController.goToFavorite(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = favorite.rawValue
        }
        add(go, title: "Go", to: main)

        let viewMenu = main.items.first { $0.title == "View" }?.submenu
        viewMenu?.insertItem(.separator(), at: 0)
        let sidebarToggle = NSMenuItem(title: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebarToggle.keyEquivalentModifierMask = [.command, .control]
        viewMenu?.insertItem(sidebarToggle, at: 0)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, title: "Window", to: main)
        NSApplication.shared.windowsMenu = window

        return main
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
