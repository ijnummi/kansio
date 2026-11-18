import AppKit

/// Builds the menu bar in code (no nib). Items target the responder chain (`target = nil`).
@MainActor
enum MainMenu {
    /// File ▸ Open With acts on the frontmost window's list.
    static let openWithMenu = OpenWithMenu(list: {
        (NSApp.mainWindow?.windowController as? MainWindowController)?.fileList
    })

    /// File ▸ Copy To / Move To act on the frontmost window's list.
    static let copyToMenu = CopyToMenu(kind: .copy, list: { (NSApp.mainWindow?.windowController as? MainWindowController)?.fileList })
    static let moveToMenu = CopyToMenu(kind: .move, list: { (NSApp.mainWindow?.windowController as? MainWindowController)?.fileList })

    /// Go ▸ Most Used Folders (opens a new tab in the frontmost window).
    static let mostUsedDelegate = MostUsedMenuDelegate()

    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Kansio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Full Disk Access…", action: #selector(AppDelegate.showFullDiskAccess(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kansio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Kansio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: "Kansio", to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab", action: #selector(MainWindowController.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "New Window", action: #selector(MainWindowController.newWindow(_:)), keyEquivalent: "n")
        let newFolder = file.addItem(withTitle: "New Folder", action: #selector(MainWindowController.newFolder(_:)), keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "New Text Document", action: #selector(FileListViewController.newTextDocument(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Open", action: #selector(FileListViewController.openSelectionAction(_:)), keyEquivalent: "o")
        let openWith = file.addItem(withTitle: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu.makeMenu()
        file.addItem(withTitle: "Show Package Contents", action: #selector(FileListViewController.showPackageContents(_:)), keyEquivalent: "")
        file.addItem(withTitle: "Get Info", action: #selector(FileListViewController.getInfo(_:)), keyEquivalent: "i")
        let pin = file.addItem(withTitle: "Pin to Favorites", action: #selector(FileListViewController.togglePinned(_:)), keyEquivalent: "t")
        pin.keyEquivalentModifierMask = [.command, .control]
        file.addItem(.separator())
        let rename = file.addItem(withTitle: "Rename", action: #selector(FileListViewController.renameSelection(_:)), keyEquivalent: "\u{F705}") // F2
        rename.keyEquivalentModifierMask = []
        file.addItem(withTitle: "Quick Look", action: #selector(FileListViewController.toggleQuickLook(_:)), keyEquivalent: "y")
        file.addItem(.separator())
        file.addItem(withTitle: "Duplicate", action: #selector(FileListViewController.duplicate(_:)), keyEquivalent: "d")
        file.addItem(withTitle: "Copy To", action: nil, keyEquivalent: "").submenu = copyToMenu.makeMenu()
        file.addItem(withTitle: "Move To", action: nil, keyEquivalent: "").submenu = moveToMenu.makeMenu()
        file.addItem(withTitle: "Move to Trash", action: #selector(FileListViewController.moveToTrash(_:)), keyEquivalent: "\u{8}") // ⌘⌫
        let emptyTrash = file.addItem(withTitle: "Empty Trash…", action: #selector(FileListViewController.emptyTrash(_:)), keyEquivalent: "\u{8}")
        emptyTrash.keyEquivalentModifierMask = [.command, .shift] // ⇧⌘⌫ (Finder)
        file.addItem(withTitle: "Stop File Operation", action: #selector(FileListViewController.stopOperations(_:)), keyEquivalent: ".")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(MainWindowController.closeTab(_:)), keyEquivalent: "w")
        let closeAll = file.addItem(withTitle: "Close Window", action: #selector(MainWindowController.closeWindowAndTabs(_:)), keyEquivalent: "w")
        closeAll.keyEquivalentModifierMask = [.command, .shift]
        add(file, title: "File", to: main)

        let edit = NSMenu(title: "Edit")
        // NSWindow handles undo:/redo: with the undo manager its delegate returns and titles the
        // items itself ("Undo Move to Trash").
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Search…", action: #selector(MainWindowController.find(_:)), keyEquivalent: "f")
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        let hidden = view.addItem(withTitle: "Show Hidden Files", action: #selector(MainWindowController.toggleHiddenFiles(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: "Hide Status Bar", action: #selector(MainWindowController.toggleStatusBar(_:)), keyEquivalent: "/")
        let columns = NSMenu(title: "Columns")
        FileListViewController.columnMenuItems(target: nil).forEach(columns.addItem) // → MainWindowController
        view.addItem(withTitle: "Columns", action: nil, keyEquivalent: "").submenu = columns
        view.addItem(.separator())
        // The list's zoom. ⌘+ is typed as ⌘= on most layouts: a hidden twin takes that key.
        view.addItem(withTitle: "Make Text Bigger", action: #selector(MainWindowController.makeTextBigger(_:)), keyEquivalent: "+")
        let bigger = view.addItem(withTitle: "Make Text Bigger", action: #selector(MainWindowController.makeTextBigger(_:)), keyEquivalent: "=")
        bigger.isHidden = true
        bigger.allowsKeyEquivalentWhenHidden = true
        bigger.allowsAutomaticKeyEquivalentLocalization = false // stays ⌘= (AppKit would move it on other layouts)
        view.addItem(withTitle: "Make Text Smaller", action: #selector(MainWindowController.makeTextSmaller(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(MainWindowController.makeTextActualSize(_:)), keyEquivalent: "0")
        let density = NSMenu(title: "Row Density")
        for choice in ViewSettings.Density.allCases {
            let item = density.addItem(withTitle: choice.title, action: #selector(MainWindowController.setListDensity(_:)), keyEquivalent: "")
            item.representedObject = choice.rawValue
        }
        view.addItem(withTitle: "Row Density", action: nil, keyEquivalent: "").submenu = density
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
        let mostUsed = NSMenu(title: "Most Used Folders")
        mostUsed.delegate = mostUsedDelegate
        go.addItem(withTitle: "Most Used Folders", action: nil, keyEquivalent: "").submenu = mostUsed
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
        window.addItem(.separator())
        let previousTab = window.addItem(withTitle: "Show Previous Tab", action: #selector(MainWindowController.showPreviousTab(_:)), keyEquivalent: "\t")
        previousTab.keyEquivalentModifierMask = [.control, .shift]
        let nextTab = window.addItem(withTitle: "Show Next Tab", action: #selector(MainWindowController.showNextTab(_:)), keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        window.addItem(withTitle: "Move Tab to New Window", action: #selector(MainWindowController.moveSelectedTabToNewWindow(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Merge All Windows", action: #selector(MainWindowController.mergeAllWindows(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "File Operations", action: #selector(AppDelegate.showFileOperations(_:)), keyEquivalent: "")
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
