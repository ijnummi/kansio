import AppKit
import FileSystemKit

/// One browser window: sidebar (Favorites + Volumes) | details view, with a unified toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSMenuDelegate {
    let fileList: FileListViewController
    let sidebar = SidebarViewController()
    private let split = NSSplitViewController()
    private let backButton = MainWindowController.toolbarButton(symbol: "chevron.left", label: "Back")
    private let forwardButton = MainWindowController.toolbarButton(symbol: "chevron.right", label: "Forward")
    private let upButton = MainWindowController.toolbarButton(symbol: "arrow.up", label: "Up")

    private static let backID = NSToolbarItem.Identifier("back")
    private static let forwardID = NSToolbarItem.Identifier("forward")
    private static let upID = NSToolbarItem.Identifier("up")

    init(initialFolder: URL) {
        fileList = FileListViewController(folder: initialFolder)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 150
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let contentItem = NSSplitViewItem(viewController: fileList)
        contentItem.minimumThickness = 320
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        LaunchTrace.mark("  split items")
        split.splitView.autosaveName = "MainSplit"

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        LaunchTrace.mark("  NSWindow")
        window.contentViewController = split
        LaunchTrace.mark("  contentViewController (loads sidebar + list views)")
        window.setContentSize(NSSize(width: 1100, height: 660))
        window.minSize = NSSize(width: 560, height: 320)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.tabbingMode = .disallowed // tabs are P1
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.onMouseBack = { [weak self] in self?.fileList.goBack() }
        window.onMouseForward = { [weak self] in self?.fileList.goForward() }

        backButton.target = self
        backButton.action = #selector(goBack(_:))
        forwardButton.target = self
        forwardButton.action = #selector(goForward(_:))
        upButton.target = self
        upButton.action = #selector(goUp(_:))
        // Right-click Back/Forward: jump several steps (Explorer's recent-locations dropdown).
        for button in [backButton, forwardButton] {
            let menu = NSMenu()
            menu.delegate = self
            button.menu = menu
        }

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        LaunchTrace.mark("  toolbar")

        fileList.onStateChange = { [weak self] state in self?.update(for: state) }
        sidebar.onSelect = { [weak self] url in self?.fileList.navigate(to: url) }
        sidebar.onVolumeRemoved = { [weak self] volume in self?.volumeRemoved(volume) }
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil {
            sidebar.onVolumesChanged = { volumes in
                print("sidebar volumes: \(volumes.map(\.name))")
                fflush(stdout)
            }
        }
        update(for: fileList.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func update(for state: FileListViewController.State) {
        guard let window else { return }
        let url = state.folder
        window.title = url.path(percentEncoded: false) == "/" ? "/" : url.lastPathComponent
        window.subtitle = state.summary
        sidebar.showCurrentFolder(url)
        backButton.isEnabled = state.canGoBack
        forwardButton.isEnabled = state.canGoForward
        upButton.isEnabled = state.canGoUp
    }

    /// The volume we're browsing was ejected: go Home and say why (inline, no alert).
    private func volumeRemoved(_ volume: Volume) {
        defer { fileList.forgetHistory { volume.contains(path: $0.path(percentEncoded: false)) } }
        guard volume.contains(path: fileList.folder.path(percentEncoded: false)) else { return }
        if ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil { print("ejected while browsing: \(volume.name) → Home"); fflush(stdout) }
        fileList.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        fileList.showMessage("“\(volume.name)” was ejected.")
    }

    // MARK: Go menu

    enum Favorite: Int { case home, desktop, documents, downloads, applications }

    @objc func goToFavorite(_ sender: NSMenuItem) {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL { fm.urls(for: d, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser }
        let url: URL = switch Favorite(rawValue: sender.tag) {
        case .desktop: dir(.desktopDirectory)
        case .documents: dir(.documentDirectory)
        case .downloads: dir(.downloadsDirectory)
        case .applications: URL(filePath: "/Applications", directoryHint: .isDirectory)
        default: fm.homeDirectoryForCurrentUser
        }
        fileList.navigate(to: url)
        fileList.focusList()
    }

    // MARK: Navigation actions (window controller = in the responder chain whichever pane has focus)

    @objc func goBack(_ sender: Any?) { fileList.goBack() }
    @objc func goForward(_ sender: Any?) { fileList.goForward() }
    @objc func goUp(_ sender: Any?) { fileList.goUp() }
    @objc func toggleHiddenFiles(_ sender: Any?) { fileList.toggleHiddenFiles() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = fileList.state
        switch menuItem.action {
        case #selector(goBack(_:)): return state.canGoBack
        case #selector(goForward(_:)): return state.canGoForward
        case #selector(goUp(_:)): return state.canGoUp
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = fileList.showsHiddenFiles ? .on : .off
            return true
        default: return true
        }
    }

    /// Builds the Back/Forward history menu when it's about to open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let isBack = menu === backButton.menu
        let entries = isBack ? Array(fileList.history.back.reversed()) : fileList.history.forward
        for (i, entry) in entries.prefix(20).enumerated() {
            let item = menu.addItem(withTitle: Self.displayTitle(entry.url), action: #selector(jumpInHistory(_:)), keyEquivalent: "")
            item.target = self
            item.tag = isBack ? -(i + 1) : i + 1
            item.toolTip = entry.url.path(percentEncoded: false)
        }
    }

    @objc private func jumpInHistory(_ sender: NSMenuItem) {
        if sender.tag < 0 { fileList.goBack(-sender.tag) } else { fileList.goForward(sender.tag) }
    }

    private static func displayTitle(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        if path == "/" { return "/" }
        if url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL { return "Home" }
        return url.lastPathComponent
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.backID, Self.forwardID, Self.upID, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let button: NSButton
        switch itemIdentifier {
        case Self.backID: button = backButton
        case Self.forwardID: button = forwardButton
        case Self.upID: button = upButton
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = button
        item.label = button.toolTip ?? ""
        item.isNavigational = true
        return item
    }

    private static func toolbarButton(symbol: String, label: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isEnabled = false
        return button
    }
}

/// Window that routes the mouse's side buttons (button 4 = Back, 5 = Forward) to history,
/// wherever the pointer is: list, sidebar, toolbar or empty space. Handled here, before
/// hit-testing, because no individual view would otherwise see them consistently.
@MainActor
final class BrowserWindow: NSWindow {
    var onMouseBack: (() -> Void)?
    var onMouseForward: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseDown {
            switch event.buttonNumber {
            case 3: onMouseBack?(); return     // "button 4" (0-based 3)
            case 4: onMouseForward?(); return  // "button 5"
            default: break
            }
        }
        if event.type == .otherMouseUp, event.buttonNumber == 3 || event.buttonNumber == 4 { return }
        super.sendEvent(event)
    }
}
