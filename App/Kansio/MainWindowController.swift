import AppKit
import FileSystemKit

/// One browser window: sidebar (Favorites + Volumes) | details view, with a unified toolbar.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation, NSMenuDelegate {
    let fileList: FileListViewController
    let sidebar = SidebarViewController()
    let addressBar = AddressBarController()
    private let split = NSSplitViewController()
    private let backButton = MainWindowController.toolbarButton(symbol: "chevron.left", label: "Back")
    private let forwardButton = MainWindowController.toolbarButton(symbol: "chevron.right", label: "Forward")
    private let upButton = MainWindowController.toolbarButton(symbol: "arrow.up", label: "Up")

    private static let backID = NSToolbarItem.Identifier("back")
    private static let forwardID = NSToolbarItem.Identifier("forward")
    private static let upID = NSToolbarItem.Identifier("up")

    /// Called when the window (tab) closes, after its work was stopped.
    var onClose: (() -> Void)?

    init(initialFolder: URL, startsActive: Bool = true) {
        fileList = FileListViewController(folder: initialFolder, startsActive: startsActive)

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
        window.setFrameAutosaveName("MainWindow") // the first window; later ones cascade from it
        window.tabbingMode = .automatic
        window.tabbingIdentifier = WindowManager.tabbingIdentifier
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        sidebar.setActive(startsActive)
        window.onMouseBack = { [weak self] in self?.fileList.goBack() }
        window.onMouseForward = { [weak self] in self?.fileList.goForward() }
        window.onMiddleClick = { [weak self] event in self?.middleClick(event) ?? false }
        // A tab that isn't shown pauses (see WindowManager). These all can change that.
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            }
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateActivity() }
            }
        }

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

        window.addTitlebarAccessoryViewController(addressBar)
        addressBar.volumes = StartupPrefetch.takeVolumes() ?? []
        addressBar.onNavigate = { [weak self] url, select in self?.fileList.navigate(to: url, select: select) }
        addressBar.onFinishEditing = { [weak self] in self?.fileList.focusList() }
        addressBar.includeHidden = { [weak self] in self?.fileList.showsHiddenFiles ?? false }

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        LaunchTrace.mark("  toolbar")

        fileList.onStateChange = { [weak self] state in self?.update(for: state) }
        sidebar.onSelect = { [weak self] url in self?.fileList.navigate(to: url) }
        sidebar.onReturn = { [weak self] in self?.fileList.focusList() }
        sidebar.fileList = fileList
        sidebar.listHasRows = { [weak self] in self?.fileList.lastDisplayEvent != nil }
        sidebar.onVolumeRemoved = { [weak self] volume in self?.volumeRemoved(volume) }
        let traceVolumes = ProcessInfo.processInfo.environment["KANSIO_TRACE"] != nil
        sidebar.onVolumesChanged = { [weak self] volumes in
            self?.addressBar.volumes = volumes
            if traceVolumes {
                print("sidebar volumes: \(volumes.map(\.name))")
                fflush(stdout)
            }
        }
        update(for: fileList.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Text editing (rename field, address bar) keeps its own undo; everything else uses the
    /// app-wide file-operation history.
    private let textUndoManager = UndoManager()

    // MARK: Tabs and windows (P1-3)

    /// Not shown: another tab of this window is selected, it's minimized, or the app is hidden.
    /// (Merely covered by other windows still counts as shown — live updates keep running.)
    var isInBackground: Bool {
        guard let window else { return true }
        if window.isMiniaturized || NSApp.isHidden { return true }
        guard let group = window.tabGroup, group.windows.count > 1 else { return false }
        return group.selectedWindow !== window
    }

    /// Re-evaluates this tab and its siblings (a switch shows one and hides another; AppKit tells
    /// only one of them, and not always in the same order).
    static var activityUpdates = 0
    /// Main-thread time spent pausing/resuming tabs (measurement).
    static var activityTime: Duration = .zero

    func updateActivity() {
        Self.activityUpdates += 1
        let start = ContinuousClock.now
        defer { Self.activityTime += ContinuousClock.now - start }
        let group = window?.tabGroup
        let siblings = WindowManager.shared.controllers.filter { $0 === self || (group != nil && $0.window?.tabGroup === group) }
        for controller in siblings {
            let active = !controller.isInBackground
            controller.fileList.setActive(active)
            controller.sidebar.setActive(active)
        }
    }

    /// ⌃Tab / ⌃⇧Tab.
    @objc func showNextTab(_ sender: Any?) { selectTab(offset: 1) }
    @objc func showPreviousTab(_ sender: Any?) { selectTab(offset: -1) }

    private func selectTab(offset: Int) {
        guard let window, let group = window.tabGroup, group.windows.count > 1,
              let index = group.windows.firstIndex(of: group.selectedWindow ?? window) else { return }
        let target = group.windows[(index + offset + group.windows.count) % group.windows.count]
        target.makeKeyAndOrderFront(nil)
        (target.windowController as? MainWindowController)?.updateActivity()
    }

    func windowWillClose(_ notification: Notification) {
        fileList.shutdown()
        sidebar.shutdown()
        onClose?()
        // The tab that's selected now (if this was one) resumes.
        DispatchQueue.main.async { WindowManager.shared.controllers.forEach { $0.updateActivity() } }
    }

    /// ⌘T: a new tab at Home (Explorer), selected.
    @objc func newTab(_ sender: Any?) {
        guard let window else { return }
        WindowManager.shared.openTab(at: FileManager.default.homeDirectoryForCurrentUser, next: window, background: false)
    }

    /// The tab bar's "+" button.
    override func newWindowForTab(_ sender: Any?) { newTab(sender) }

    /// ⌘N: a new window showing this folder (Explorer).
    @objc func newWindow(_ sender: Any?) {
        WindowManager.shared.openWindow(at: fileList.folder, cascadingFrom: window)
    }

    /// ⌘W: closes the tab (or the window when it has no other tabs).
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }

    /// ⇧⌘W: closes the window with all its tabs.
    @objc func closeWindowAndTabs(_ sender: Any?) {
        let windows = window?.tabGroup?.windows ?? [window].compactMap { $0 }
        windows.forEach { $0.close() }
    }

    func openInNewTab(_ url: URL, background: Bool = false) {
        guard let window else { return }
        WindowManager.shared.openTab(at: url, next: window, background: background)
    }

    func openInNewWindow(_ url: URL) {
        WindowManager.shared.openWindow(at: url, cascadingFrom: window)
    }

    /// Middle-click on a folder (list or navigation pane): open it in a background tab (Explorer).
    private func middleClick(_ event: NSEvent) -> Bool {
        guard let url = folderURL(at: event.locationInWindow) else { return false }
        openInNewTab(url, background: true)
        return true
    }

    private func folderURL(at point: NSPoint) -> URL? {
        guard let hit = window?.contentView?.hitTest(point) else { return nil }
        let table = fileList.tableForTesting
        if hit.isDescendant(of: table) {
            let row = table.row(at: table.convert(point, from: nil))
            return fileList.folderURL(atRow: row)
        }
        let outline = sidebar.outlineView
        if hit.isDescendant(of: outline) {
            return sidebar.folderURL(atRow: outline.row(at: outline.convert(point, from: nil)))
        }
        return nil
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        window.firstResponder is NSTextView ? textUndoManager : FileUndo.shared.manager
    }

    private func update(for state: FileListViewController.State) {
        guard let window else { return }
        let url = state.folder
        window.title = url.path(percentEncoded: false) == "/" ? "/" : url.lastPathComponent
        window.subtitle = "" // counts live in the status bar (M14)
        sidebar.showCurrentFolder(url)
        addressBar.show(folder: url)
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
    @objc func toggleStatusBar(_ sender: Any?) { fileList.setStatusBarVisible(!ViewSettings.shared.showStatusBar) }
    /// View ▸ Columns works whichever pane has focus.
    @objc func toggleColumn(_ sender: Any?) { fileList.toggleColumn(sender) }
    @objc func resetColumns(_ sender: Any?) { fileList.resetColumns(sender) }
    /// ⇧⌘N works whichever pane has focus (it creates in the current folder).
    @objc func newFolder(_ sender: Any?) {
        fileList.focusList()
        fileList.newFolder(sender)
    }

    /// ⌘L / ⇧⌘G: edit the path in the address bar.
    @objc func editLocation(_ sender: Any?) { addressBar.beginEditing() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = fileList.state
        switch menuItem.action {
        case #selector(goBack(_:)): return state.canGoBack
        case #selector(goForward(_:)): return state.canGoForward
        case #selector(goUp(_:)): return state.canGoUp
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = fileList.showsHiddenFiles ? .on : .off
            return true
        case #selector(toggleStatusBar(_:)):
            menuItem.title = ViewSettings.shared.showStatusBar ? "Hide Status Bar" : "Show Status Bar"
            return true
        case #selector(toggleColumn(_:)): return fileList.validateColumnItem(menuItem)
        case #selector(closeTab(_:)):
            menuItem.title = (window?.tabGroup?.windows.count ?? 1) > 1 ? "Close Tab" : "Close Window"
            return true
        case #selector(closeWindowAndTabs(_:)), #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return (window?.tabGroup?.windows.count ?? 1) > 1
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
    /// Middle button: true when handled (opened a folder in a new tab).
    var onMiddleClick: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseDown {
            switch event.buttonNumber {
            case 2: if onMiddleClick?(event) == true { return } // middle button
            case 3: onMouseBack?(); return     // "button 4" (0-based 3)
            case 4: onMouseForward?(); return  // "button 5"
            default: break
            }
        }
        if event.type == .otherMouseUp, event.buttonNumber == 3 || event.buttonNumber == 4 { return }
        super.sendEvent(event)
    }
}
