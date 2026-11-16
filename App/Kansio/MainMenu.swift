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
        let hidden = view.addItem(withTitle: "Show Hidden Files", action: #selector(FileListViewController.toggleHiddenFiles(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        add(view, title: "View", to: main)

        let go = NSMenu(title: "Go")
        let up = go.addItem(withTitle: "Enclosing Folder", action: #selector(FileListViewController.goUp(_:)), keyEquivalent: "\u{F700}") // ↑
        up.keyEquivalentModifierMask = [.command]
        add(go, title: "Go", to: main)

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
